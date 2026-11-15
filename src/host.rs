//! A host: the process that keeps a child when no terminal is looking at it.
//!
//! A session started the ordinary way is a child of Emacs and ends with it. A hosted
//! one is a child of a small process of its own, which does three things and nothing
//! else: it holds the master end of the pty, so that the child has a terminal whoever
//! is or is not looking; it reads everything the child writes, and keeps the recent
//! part; and it listens on a socket for a terminal that wants to look.
//!
//! One host per session, the way `dtach` and `abduco` do it rather than the way tmux
//! does. There is no server to be the single point every session fails at, no registry
//! beyond a directory, and listing the directory is listing the sessions.
//!
//! # What a terminal gets when it attaches
//!
//! Not a picture of the screen. The host hands over its own master end, duplicated
//! through the socket, and from then on the terminal writes input to the pty, sets its
//! size and reads its modes exactly as it would for a child of its own -- nothing about
//! typing, resizing or telling a shell prompt from a full-screen program goes through
//! this process at all. Reading is the one thing that cannot be shared, because a byte
//! read from a pty is gone; so the host stays the reader and passes on what it reads.
//!
//! And before anything live, a replay: the recent output, byte for byte as the child
//! wrote it, for the terminal's own emulator to make of what it would have made the
//! first time. That is why there is no protocol for describing a screen here, and no
//! version of one for a host started last week to disagree about with a terminal built
//! today -- the only format on the wire is the one the child speaks.
//!
//! The replay is bounded, and a session that has written more than the bound starts
//! part-way through. The host runs an emulator of its own for that case alone, to know
//! which modes the child negotiated before the part it can still show; see
//! [`Term::mode_preamble`]. The same emulator answers the questions a child asks of its
//! terminal while nobody is attached, which is what lets a program be *started* with
//! nobody looking and not sit waiting for a reply.
//!
//! # What it is not
//!
//! A way in for anything but the user. The socket lives in a directory only the user
//! can enter, is itself readable by nobody else, and a peer running as anyone else is
//! hung up on -- because what the socket gives away is the keyboard of a shell.

use crate::emu::{CellMetrics, Event, Term};
use crate::error::{Error, Result};
use crate::platform;
use crate::pty::{Pid, Pty, Winsize};
use nix::errno::Errno;
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use nix::sys::socket::{ControlMessage, ControlMessageOwned, MsgFlags, recvmsg, sendmsg};
use std::collections::VecDeque;
use std::io::{IoSlice, IoSliceMut, Read, Write};
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How much of what the child wrote is kept for the next terminal to be shown.
///
/// Bytes rather than lines, because what is kept is what the child wrote and not what
/// an emulator made of it. Eight megabytes is hours of an agent's conversation and a
/// fraction of a second to replay.
pub const DEFAULT_RING: usize = 8 * 1024 * 1024;

/// How long a peer may take over a request line, a hello or a reply.
const HANDSHAKE: Duration = Duration::from_secs(3);

/// How long an attached terminal may go without reading before it is hung up on.
///
/// While its queue is full the child is not read either, so for this long a terminal
/// that has stopped -- an Emacs in the debugger, or blocked on something else -- holds
/// the child's output back, exactly as it would hold back a child of its own. After it
/// the terminal is dropped and the child runs on: what a host is for is that the work
/// does not depend on the thing watching it.
const STALL: Duration = Duration::from_secs(5);

/// How often the child is asked whether it is still there, with nothing else to do.
const TICK_MS: u16 = 500;

/// How long the child is given to go once it is told to, at each step.
const GRACE: Duration = Duration::from_millis(300);

/// The most a `send` request may carry.
const SEND_LIMIT: usize = 1024 * 1024;

fn protocol() -> Error {
    Error::Os(Errno::EPROTO)
}

// ---------------------------------------------------------------------------------------
// Where sessions live

/// The directory hosts keep their sockets and their descriptions in.
///
/// Under the user's state directory rather than a runtime one, for two reasons. A
/// description has to outlast a reboot -- it is what says there *was* a session, in
/// which directory, running what -- and a socket address has a hundred-odd bytes to
/// fit in, which the per-user temporary directory macOS provides leaves little of.
pub fn directory() -> PathBuf {
    if let Some(dir) = std::env::var_os("COOKED_HOST_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    let state = std::env::var_os("XDG_STATE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
        });
    state.join("cooked/hosts")
}

/// Whether NAME can name a session: it becomes a file name, so it is held to the
/// characters that are one everywhere and mean nothing to a shell.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn socket_path(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}.sock"))
}

fn meta_path(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}.json"))
}

/// A directory that is the session's own, for whoever started it to keep files in
/// that have to last exactly as long as it does -- the startup files a shell is
/// pointed at, for one. Nothing here creates it; it is removed with the session.
fn scratch_path(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}.d"))
}

fn forget(dir: &Path, name: &str) {
    let _ = std::fs::remove_file(socket_path(dir, name));
    let _ = std::fs::remove_file(meta_path(dir, name));
    let _ = std::fs::remove_dir_all(scratch_path(dir, name));
}

fn ensure_directory(dir: &Path) -> Result<()> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    // `create` leaves an existing directory as it found it, and this one is the lock
    // on every session's keyboard.
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

// ---------------------------------------------------------------------------------------
// The terminal's side

/// What a terminal holds once a host has let it in.
pub(crate) struct Attached {
    /// The socket, non-blocking, with the replay next to be read from it.
    pub stream: OwnedFd,
    /// The host's master end of the pty.
    pub master: OwnedFd,
    pub child: Pid,
    /// The size the tty had when the host answered.
    pub size: Winsize,
}

/// Ask the host listening at SOCKET to be let in.
pub(crate) fn attach(socket: &Path) -> Result<Attached> {
    let mut stream = request(socket, b"attach\n")?;
    let mut hello = [0u8; 13];
    let mut have = 0;
    let mut master = None;
    while have < hello.len() {
        let mut space = nix::cmsg_space!([RawFd; 1]);
        let (n, fds) = {
            let mut iov = [IoSliceMut::new(&mut hello[have..])];
            let message = match recvmsg::<()>(
                stream.as_raw_fd(),
                &mut iov,
                Some(&mut space),
                MsgFlags::empty(),
            ) {
                Err(Errno::EINTR) => continue,
                other => other?,
            };
            let mut fds = Vec::new();
            for control in message.cmsgs()? {
                if let ControlMessageOwned::ScmRights(received) = control {
                    fds.extend(received);
                }
            }
            (message.bytes, fds)
        };
        for fd in fds {
            // SAFETY: the kernel has just installed this descriptor in our table and
            // nothing else knows its number.
            let fd = unsafe { OwnedFd::from_raw_fd(fd) };
            // Emacs forks, and no child of it is to inherit a shell's keyboard.
            nix::fcntl::fcntl(
                fd.as_fd(),
                nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
            )?;
            master.get_or_insert(fd);
        }
        if n == 0 {
            return Err(protocol());
        }
        have += n;
    }
    if hello[0] != b'H' || hello[1..5] != 8u32.to_be_bytes() {
        return Err(protocol());
    }
    let master = master.ok_or_else(protocol)?;
    let child = i32::from_be_bytes([hello[5], hello[6], hello[7], hello[8]]);
    let size = Winsize {
        rows: u16::from_be_bytes([hello[9], hello[10]]).max(1),
        cols: u16::from_be_bytes([hello[11], hello[12]]).max(1),
        cell: CellMetrics::default(),
    };
    stream.set_read_timeout(None)?;
    stream.set_nonblocking(true)?;
    stream.flush()?;
    Ok(Attached {
        stream: stream.into(),
        master,
        child: Pid::from_raw(child),
        size,
    })
}

/// Connect to the host at SOCKET and send it LINE.
fn request(socket: &Path, line: &[u8]) -> Result<UnixStream> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(HANDSHAKE))?;
    stream.set_write_timeout(Some(HANDSHAKE))?;
    stream.write_all(line)?;
    Ok(stream)
}

/// Send LINE and read the one line the host answers with.
fn ask(socket: &Path, line: &[u8]) -> Result<String> {
    let mut stream = request(socket, line)?;
    let mut answer = String::new();
    stream.read_to_string(&mut answer)?;
    Ok(answer.trim_end().to_owned())
}

// ---------------------------------------------------------------------------------------
// The host's side

/// The recent part of what the child wrote.
struct Ring {
    bytes: VecDeque<u8>,
    limit: usize,
    /// Whether anything has been dropped from the front.
    truncated: bool,
}

impl Ring {
    fn new(limit: usize) -> Self {
        Self {
            bytes: VecDeque::new(),
            limit: limit.max(4096),
            truncated: false,
        }
    }

    fn push(&mut self, data: &[u8]) {
        self.bytes.extend(data);
        if self.bytes.len() <= self.limit {
            return;
        }
        // An eighth more than is needed, so that a session at its limit drops a slab
        // now and then rather than a few bytes on every write.
        let excess = self.bytes.len() - self.limit + self.limit / 8;
        self.bytes.drain(..excess.min(self.bytes.len()));
        self.truncated = true;
        // On to the start of a line, which is the nearest thing to a place where an
        // escape sequence is unlikely to be half over. A bounded search: output with
        // no newlines in it gets no such courtesy.
        if let Some(at) = self.bytes.iter().take(4096).position(|b| *b == b'\n') {
            self.bytes.drain(..=at);
        }
    }
}

/// A terminal that is attached, and what it has yet to be sent.
struct Client {
    stream: UnixStream,
    out: VecDeque<u8>,
    /// Since when the queue has been too long to add to; see [`STALL`].
    stalled: Option<Instant>,
}

impl Client {
    fn frame(&mut self, tag: u8, payload: &[u8]) {
        self.out.push_back(tag);
        self.out.extend((payload.len() as u32).to_be_bytes());
        self.out.extend(payload);
    }

    /// Write as much of the queue as the socket takes. An error means the terminal
    /// is gone.
    fn flush(&mut self) -> std::io::Result<()> {
        loop {
            let (front, _) = self.out.as_slices();
            if front.is_empty() {
                return Ok(());
            }
            match self.stream.write(front) {
                Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
                Ok(n) => {
                    self.out.drain(..n);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
    }
}

/// What to run, and where.
pub struct Spec<'a> {
    pub name: &'a str,
    pub argv: &'a [String],
    pub env: &'a [(String, String)],
    pub cwd: Option<&'a Path>,
    pub rows: u16,
    pub cols: u16,
    pub ring: usize,
    /// Whatever the starter wants kept with the description, verbatim. The host
    /// does not read it: it is for the starter to recognise its own sessions by,
    /// and to know how to start one again.
    pub note: Option<&'a str>,
}

/// A child, its pty, and the socket a terminal reaches them through.
pub struct Host {
    dir: PathBuf,
    name: String,
    pty: Pty,
    term: Term,
    size: Winsize,
    ring: Ring,
    listener: UnixListener,
    client: Option<Client>,
    /// How the child ended, once it has.
    exit: Option<i32>,
    /// Whether some terminal has been told how it ended.
    exit_seen: bool,
}

enum Verdict {
    Continue,
    Stop,
}

impl Host {
    /// Start the child and begin listening, in DIR.
    pub fn create(dir: &Path, spec: &Spec<'_>) -> Result<Self> {
        if !valid_name(spec.name) {
            return Err(Error::Os(Errno::EINVAL));
        }
        ensure_directory(dir)?;
        let socket = socket_path(dir, spec.name);
        let meta = meta_path(dir, spec.name);
        // A socket file is left behind by a host that was killed. Whether this one is
        // such a leftover is decided by asking it: something answering is a session
        // that is alive, and its name is taken.
        if socket.exists() {
            if UnixStream::connect(&socket).is_ok() {
                return Err(Error::Os(Errno::EADDRINUSE));
            }
            std::fs::remove_file(&socket)?;
        }
        let size = Winsize {
            rows: spec.rows.max(1),
            cols: spec.cols.max(1),
            cell: CellMetrics::default(),
        };
        let pty = Pty::spawn(spec.argv, spec.env, size, spec.cwd)?;
        let listener = UnixListener::bind(&socket)?;
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        let host = Self {
            dir: dir.to_owned(),
            name: spec.name.to_owned(),
            term: Term::new(size.rows.into(), size.cols.into()),
            pty,
            size,
            ring: Ring::new(spec.ring),
            listener,
            client: None,
            exit: None,
            exit_seen: false,
        };
        std::fs::write(&meta, describe(spec, host.pty.pid().get()))?;
        std::fs::set_permissions(&meta, std::fs::Permissions::from_mode(0o600))?;
        Ok(host)
    }

    /// Keep the child until it is over and somebody has been told, or until told to
    /// stop. Returns once there is nothing left to keep.
    pub fn serve(mut self) {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            // A finished session waits for one terminal to see how it ended, and for
            // that terminal to have been sent all of it.
            if self.exit_seen && self.client.as_ref().is_none_or(|c| c.out.is_empty()) {
                break;
            }
            self.drop_stalled_client();
            let reading = self.exit.is_none() && !self.client_full();
            let (master, accept, client) = {
                let mut fds = Vec::with_capacity(3);
                fds.push(PollFd::new(
                    self.pty.as_fd(),
                    if reading {
                        PollFlags::POLLIN
                    } else {
                        PollFlags::empty()
                    },
                ));
                fds.push(PollFd::new(self.listener.as_fd(), PollFlags::POLLIN));
                if let Some(client) = &self.client {
                    let mut wanted = PollFlags::POLLIN;
                    if !client.out.is_empty() {
                        wanted |= PollFlags::POLLOUT;
                    }
                    fds.push(PollFd::new(client.stream.as_fd(), wanted));
                }
                match poll(&mut fds, PollTimeout::from(TICK_MS)) {
                    Err(Errno::EINTR) => continue,
                    Err(_) => break,
                    Ok(_) => {}
                }
                let ready = |fd: &PollFd| fd.revents().is_some_and(|r| !r.is_empty());
                (
                    reading && ready(&fds[0]),
                    ready(&fds[1]),
                    fds.get(2).is_some_and(ready),
                )
            };

            if master {
                self.read_child(&mut buf);
            } else if self.exit.is_none()
                && let Ok(Some(status)) = self.pty.try_wait()
            {
                // Gone without the pty saying so, which is what a child that left
                // something running in the background looks like.
                self.ended(status);
            }
            if client {
                self.serve_client();
            }
            if accept
                && let Ok((stream, _)) = self.listener.accept()
                && matches!(self.answer(stream), Verdict::Stop)
            {
                self.stop();
                break;
            }
        }
        forget(&self.dir, &self.name);
    }

    fn client_full(&self) -> bool {
        // Room for a whole replay and then some: the replay is queued in one piece.
        let limit = self.ring.limit * 2 + DEFAULT_RING;
        self.client.as_ref().is_some_and(|c| c.out.len() > limit)
    }

    fn drop_stalled_client(&mut self) {
        let full = self.client_full();
        let Some(client) = &mut self.client else {
            return;
        };
        if !full {
            client.stalled = None;
        } else if client.stalled.get_or_insert_with(Instant::now).elapsed() > STALL {
            self.client = None;
        }
    }

    fn read_child(&mut self, buf: &mut [u8]) {
        match self.pty.read(buf) {
            Ok(None) => {}
            Ok(Some([])) => self.child_gone(),
            Ok(Some(data)) => {
                let data = data.to_vec();
                self.output(&data);
            }
            Err(e) if e.is(Errno::EIO) => self.child_gone(),
            Err(e) if e.is(Errno::EINTR) => {}
            Err(_) => self.child_gone(),
        }
    }

    /// The child wrote DATA: keep it, pass it on, and answer what it asked.
    fn output(&mut self, data: &[u8]) {
        // The tty is resized by whoever is attached, directly, so its size is read
        // rather than told.
        if let Ok(now) = self.pty.winsize()
            && (now.rows, now.cols) != (self.size.rows, self.size.cols)
            && now.rows > 0
            && now.cols > 0
        {
            self.size = now;
            self.term.resize(now.rows.into(), now.cols.into());
        }
        self.term.feed(data);
        for event in self.term.drain().events {
            // With a terminal attached the answer is that terminal's to give, and it
            // gives it; two answers would be one too many typed at the child.
            if let Event::Reply(bytes) = event
                && self.client.is_none()
            {
                let _ = self.pty.write_some(&bytes);
            }
        }
        self.ring.push(data);
        if let Some(client) = &mut self.client {
            client.frame(b'D', data);
            if client.flush().is_err() {
                self.client = None;
            }
        }
    }

    fn child_gone(&mut self) {
        let status = self.pty.reap(GRACE).unwrap_or_else(|| {
            self.pty.kill();
            self.pty.reap(GRACE).unwrap_or(0)
        });
        self.ended(status);
    }

    fn ended(&mut self, status: i32) {
        self.exit = Some(status);
        if let Some(client) = &mut self.client {
            client.frame(b'X', &status.to_be_bytes());
            self.exit_seen = true;
            if client.flush().is_err() {
                self.client = None;
            }
        }
    }

    /// The attached terminal is readable or writable: send it more, or notice that
    /// it has gone. It never says anything once attached, so readable means closed.
    fn serve_client(&mut self) {
        let Some(client) = &mut self.client else {
            return;
        };
        let mut scratch = [0u8; 64];
        let gone = match client.stream.read(&mut scratch) {
            Ok(0) => true,
            Ok(_) => false,
            Err(e) => !matches!(
                e.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
            ),
        };
        if gone || client.flush().is_err() {
            self.client = None;
        }
    }

    /// Hear out a new connection.
    fn answer(&mut self, mut stream: UnixStream) -> Verdict {
        if platform::peer_uid(stream.as_fd()) != Some(nix::unistd::geteuid().as_raw()) {
            return Verdict::Continue;
        }
        if stream.set_nonblocking(false).is_err()
            || stream.set_read_timeout(Some(HANDSHAKE)).is_err()
            || stream.set_write_timeout(Some(HANDSHAKE)).is_err()
        {
            return Verdict::Continue;
        }
        let Some(line) = read_line(&mut stream) else {
            return Verdict::Continue;
        };
        let mut words = line.split(' ');
        match (words.next(), words.next()) {
            (Some("attach"), None) => {
                self.admit(stream);
            }
            (Some("info"), None) => {
                let state = match self.exit {
                    Some(status) => format!("exited {status}"),
                    None => "live".to_owned(),
                };
                let _ = writeln!(
                    stream,
                    "{state} {} {} {} {}",
                    self.pty.pid().get(),
                    self.size.rows,
                    self.size.cols,
                    u8::from(self.client.is_some()),
                );
            }
            (Some("send"), Some(length)) => {
                let sent = length
                    .parse::<usize>()
                    .ok()
                    .filter(|n| *n <= SEND_LIMIT)
                    .and_then(|n| {
                        let mut bytes = vec![0u8; n];
                        stream.read_exact(&mut bytes).ok().map(|()| bytes)
                    })
                    .is_some_and(|bytes| self.type_at_child(&bytes));
                let _ = stream.write_all(if sent { b"ok\n" } else { b"failed\n" });
            }
            (Some("paste"), Some(length)) => {
                let sent = length
                    .parse::<usize>()
                    .ok()
                    .filter(|n| *n <= SEND_LIMIT)
                    .and_then(|n| {
                        let mut bytes = vec![0u8; n];
                        stream.read_exact(&mut bytes).ok().map(|()| bytes)
                    })
                    .is_some_and(|bytes| {
                        let pasted = pasted(&bytes, self.term.bracketed_paste());
                        self.type_at_child(&pasted)
                    });
                let _ = stream.write_all(if sent { b"ok\n" } else { b"failed\n" });
            }
            (Some("capture"), None) => {
                let _ = stream.write_all(self.screen_text().as_bytes());
            }
            (Some("kill"), None) => {
                let _ = stream.write_all(b"ok\n");
                return Verdict::Stop;
            }
            _ => {
                let _ = stream.write_all(b"unknown\n");
            }
        }
        Verdict::Continue
    }

    /// Let a terminal in: the master, then the replay, then whatever comes.
    ///
    /// The newest terminal wins. One that was already attached is hung up on, which
    /// is what attaching from a second place has to mean when the size of the tty is
    /// whatever the last one to set it said.
    fn admit(&mut self, stream: UnixStream) {
        let mut hello = Vec::with_capacity(13);
        hello.push(b'H');
        hello.extend(8u32.to_be_bytes());
        hello.extend(self.pty.pid().get().to_be_bytes());
        hello.extend(self.size.rows.to_be_bytes());
        hello.extend(self.size.cols.to_be_bytes());
        let fds = [self.pty.as_fd().as_raw_fd()];
        let sent = sendmsg::<()>(
            stream.as_raw_fd(),
            &[IoSlice::new(&hello)],
            &[ControlMessage::ScmRights(&fds)],
            MsgFlags::empty(),
            None,
        );
        if sent != Ok(hello.len()) || stream.set_nonblocking(true).is_err() {
            return;
        }
        let mut client = Client {
            stream,
            out: VecDeque::new(),
            stalled: None,
        };
        let mut replay = if self.ring.truncated {
            self.term.mode_preamble()
        } else {
            Vec::new()
        };
        replay.extend(self.ring.bytes.iter());
        if !replay.is_empty() {
            client.frame(b'D', &replay);
        }
        client.frame(b'E', &[u8::from(self.ring.truncated)]);
        if let Some(status) = self.exit {
            client.frame(b'X', &status.to_be_bytes());
            self.exit_seen = true;
        }
        if client.flush().is_ok() {
            self.client = Some(client);
        }
    }

    /// Write BYTES to the child as if typed, waiting a little for a tty that is slow
    /// to take them. For `send`, which is how something that is not a terminal --
    /// a script, another program -- puts text at a prompt.
    fn type_at_child(&mut self, mut bytes: &[u8]) -> bool {
        let deadline = Instant::now() + HANDSHAKE;
        while !bytes.is_empty() {
            match self.pty.write_some(bytes) {
                Ok(0) => {
                    if Instant::now() > deadline {
                        return false;
                    }
                    let mut fds = [PollFd::new(self.pty.as_fd(), PollFlags::POLLOUT)];
                    let _ = poll(&mut fds, PollTimeout::from(50u8));
                }
                Ok(n) => bytes = &bytes[n..],
                Err(_) => return false,
            }
        }
        true
    }

    /// What is on the child's screen now, as lines of text, without the blank ones
    /// below the last line that has anything on it. For `capture`: how a script, or
    /// another program, reads a terminal it is not attached to.
    fn screen_text(&self) -> String {
        let mut lines: Vec<String> = self
            .term
            .screen()
            .rows()
            .map(|row| row.to_text().trim_end().to_owned())
            .collect();
        while lines.last().is_some_and(String::is_empty) {
            lines.pop();
        }
        let mut text = lines.join("\n");
        if !text.is_empty() {
            text.push('\n');
        }
        text
    }

    /// End the child, and tell an attached terminal how it went.
    fn stop(&mut self) {
        if self.exit.is_none() {
            self.pty.hangup();
            let status = self.pty.reap(GRACE).unwrap_or_else(|| {
                self.pty.kill();
                self.pty.reap(GRACE).unwrap_or(128 + libc::SIGKILL)
            });
            self.ended(status);
        }
        if let Some(client) = &mut self.client {
            let _ = client.stream.set_nonblocking(false);
            let _ = client.stream.set_write_timeout(Some(HANDSHAKE));
            let _ = client.flush();
        }
    }
}

/// BYTES as a terminal would deliver them pasted: between the brackets, if the child
/// asked for those, so that a program reading a prompt takes a newline in them as
/// part of the text and not as the end of it.
///
/// The closing bracket is taken out of the text first. Whatever follows one is read
/// as typed, and what is pasted is exactly the kind of text nobody has read.
fn pasted(bytes: &[u8], bracketed: bool) -> Vec<u8> {
    const OPEN: &[u8] = b"\x1b[200~";
    const CLOSE: &[u8] = b"\x1b[201~";
    if !bracketed {
        return bytes.to_vec();
    }
    let mut out = Vec::with_capacity(bytes.len() + OPEN.len() + CLOSE.len());
    out.extend_from_slice(OPEN);
    let mut rest = bytes;
    while let Some(at) = rest.windows(CLOSE.len()).position(|w| w == CLOSE) {
        out.extend_from_slice(&rest[..at]);
        rest = &rest[at + CLOSE.len()..];
    }
    out.extend_from_slice(rest);
    out.extend_from_slice(CLOSE);
    out
}

fn read_line(stream: &mut UnixStream) -> Option<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    while line.len() < 64 {
        match stream.read(&mut byte) {
            Ok(1) if byte[0] == b'\n' => return String::from_utf8(line).ok(),
            Ok(1) => line.push(byte[0]),
            _ => return None,
        }
    }
    None
}

// ---------------------------------------------------------------------------------------
// Descriptions

fn json_string(out: &mut String, text: &str) {
    use std::fmt::Write as _;
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// The session as one JSON object: what was run, where, and as which process.
///
/// Written when the session starts and removed when it is over, so one that is found
/// with no host answering for it is a session that was cut off -- by a reboot, by the
/// host being killed -- and this is everything needed to start it again.
fn describe(spec: &Spec<'_>, pid: i32) -> String {
    use std::fmt::Write as _;
    let mut out = String::from("{\"name\":");
    json_string(&mut out, spec.name);
    let _ = write!(out, ",\"pid\":{pid},\"cwd\":");
    match spec.cwd {
        Some(cwd) => json_string(&mut out, &cwd.to_string_lossy()),
        None => out.push_str("null"),
    }
    out.push_str(",\"argv\":[");
    for (i, arg) in spec.argv.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        json_string(&mut out, arg);
    }
    let created = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let _ = write!(out, "],\"created\":{created},\"note\":");
    match spec.note {
        Some(note) => json_string(&mut out, note),
        None => out.push_str("null"),
    }
    out.push('}');
    out
}

/// One session found in the directory, and what its host said when asked.
struct Found {
    name: String,
    /// `live`, `exited`, or `dead` for one that no host answers for.
    state: &'static str,
    status: Option<i32>,
    attached: bool,
    /// The description written when it started, as it stands in its file.
    session: String,
}

fn found(dir: &Path) -> Vec<Found> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            name.strip_suffix(".json").map(str::to_owned)
        })
        .filter(|name| valid_name(name))
        .collect();
    names.sort();
    names
        .into_iter()
        .filter_map(|name| {
            let session = std::fs::read_to_string(meta_path(dir, &name)).ok()?;
            let info = ask(&socket_path(dir, &name), b"info\n").unwrap_or_default();
            let mut words = info.split(' ');
            let (state, status) = match words.next() {
                Some("live") => ("live", None),
                Some("exited") => ("exited", words.next().and_then(|s| s.parse::<i32>().ok())),
                _ => ("dead", None),
            };
            Some(Found {
                attached: state != "dead" && info.ends_with(" 1"),
                name,
                state,
                status,
                session: session.trim().to_owned(),
            })
        })
        .collect()
}

/// Every session described in DIR, one JSON object to a line: its description under
/// `session`, and under `state` whether a host still answers for it -- `live`,
/// `exited`, or `dead` for one that was cut off.
pub fn list(dir: &Path) -> String {
    let mut out = String::new();
    for found in found(dir) {
        out.push_str("{\"state\":");
        json_string(&mut out, found.state);
        if let Some(status) = found.status {
            out.push_str(&format!(",\"status\":{status}"));
        }
        out.push_str(&format!(",\"attached\":{},\"socket\":", found.attached));
        json_string(&mut out, &socket_path(dir, &found.name).to_string_lossy());
        out.push_str(",\"session\":");
        out.push_str(&found.session);
        out.push_str("}\n");
    }
    out
}

/// The same sessions for a shell script to read, `NAME STATE` to a line. A name has
/// no space in it, so neither does a line need quoting to be taken apart.
pub fn list_brief(dir: &Path) -> String {
    found(dir)
        .iter()
        .map(|found| format!("{} {}\n", found.name, found.state))
        .collect()
}

/// End the session NAME in DIR, or forget it if it is already over.
pub fn kill(dir: &Path, name: &str) -> Result<()> {
    if !valid_name(name) {
        return Err(Error::Os(Errno::EINVAL));
    }
    let socket = socket_path(dir, name);
    if ask(&socket, b"kill\n").is_err() {
        forget(dir, name);
    }
    Ok(())
}

/// Type BYTES at the session NAME in DIR.
pub fn send(dir: &Path, name: &str, bytes: &[u8]) -> Result<()> {
    deliver("send", dir, name, bytes)
}

/// Paste BYTES at the session NAME in DIR: typed, and between the brackets of a
/// paste if the program there has asked for them.
pub fn paste(dir: &Path, name: &str, bytes: &[u8]) -> Result<()> {
    deliver("paste", dir, name, bytes)
}

/// The text on the screen of the session NAME in DIR.
pub fn capture(dir: &Path, name: &str) -> Result<String> {
    if !valid_name(name) {
        return Err(Error::Os(Errno::EINVAL));
    }
    let mut stream = request(&socket_path(dir, name), b"capture\n")?;
    let mut text = String::new();
    stream.read_to_string(&mut text)?;
    Ok(text)
}

fn deliver(verb: &str, dir: &Path, name: &str, bytes: &[u8]) -> Result<()> {
    if !valid_name(name) || bytes.len() > SEND_LIMIT {
        return Err(Error::Os(Errno::EINVAL));
    }
    let mut stream = request(
        &socket_path(dir, name),
        format!("{verb} {}\n", bytes.len()).as_bytes(),
    )?;
    stream.write_all(bytes)?;
    let mut answer = String::new();
    stream.read_to_string(&mut answer)?;
    if answer.trim_end() == "ok" {
        Ok(())
    } else {
        Err(Error::Os(Errno::EIO))
    }
}

// ---------------------------------------------------------------------------------------
// The program

const USAGE: &str = "\
usage: cooked-host new NAME [--dir DIR] [--rows N] [--cols N] [--ring BYTES] [--note TEXT]
                       -- PROGRAM [ARG...]
       cooked-host list [--brief]     (JSON, or `NAME STATE' to a line)
       cooked-host send [--paste] NAME   (what to type is read from standard input)
       cooked-host capture NAME       (the text on its screen)
       cooked-host kill NAME
       cooked-host run [--label TEXT] [--key TEXT] -- PROGRAM [ARG...]
                                      (in a session: a command whose output is kept
                                       under $COOKED_RUN_DIR for the terminal to follow)

Keeps a program running on a terminal of its own, for cooked to attach to from Emacs.
Sessions live in $COOKED_HOST_DIR, by default ~/.local/state/cooked/hosts.
The program is told its session's name in $COOKED_HOST_SESSION, and where this
program is in $COOKED_HOST.";

/// The environment a child started from a plain shell is given: this process's own,
/// and on top of it what Emacs would have said about the terminal. One started from
/// Emacs already has all of that, and is left exactly as it was sent.
fn environment() -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = std::env::vars_os()
        .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
        .collect();
    if env
        .iter()
        .any(|(k, v)| k == "TERM_PROGRAM" && v == "cooked")
    {
        return env;
    }
    // The terminfo database ships beside the program, two directories up from where
    // the build puts it. Without it the name would describe a terminal nothing on
    // this machine has heard of, so the name is only claimed when it can be found.
    let terminfo = std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.parent()?.parent()?.join("terminfo/db")))
        .filter(|db| db.is_dir());
    let mut set = |key: &str, value: String| {
        env.retain(|(k, _)| k != key);
        env.push((key.to_owned(), value));
    };
    match terminfo {
        Some(db) => {
            set("TERM", "cooked-256color".to_owned());
            set("TERMINFO", db.to_string_lossy().into_owned());
        }
        None => set("TERM", "xterm-256color".to_owned()),
    }
    set("COLORTERM", "truecolor".to_owned());
    set("TERM_PROGRAM", "cooked".to_owned());
    env
}

/// Become a process nobody is waiting for: no terminal, no parent to be a zombie
/// of, nothing on its standard descriptors.
///
/// Returns in the child. The parent stays only to hear whether the session started,
/// through READY, and exits saying so -- which is what lets whoever ran `new` know
/// that the name it asked for is now there to attach to.
fn daemonize() -> Result<std::fs::File> {
    let (read, write) = nix::unistd::pipe()?;
    // SAFETY: this program has one thread, so there is no lock for the child to find
    // held by a thread that did not come with it.
    match unsafe { libc::fork() } {
        -1 => Err(Errno::last().into()),
        0 => {
            drop(read);
            nix::unistd::setsid()?;
            let null = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open("/dev/null")?;
            for fd in 0..=2 {
                // SAFETY: both descriptors are open and ours.
                unsafe { libc::dup2(null.as_raw_fd(), fd) };
            }
            // SAFETY: setting a disposition, with no handler of ours involved. A
            // terminal that hangs up mid-write must not take the session with it.
            unsafe {
                libc::signal(libc::SIGPIPE, libc::SIG_IGN);
                libc::signal(libc::SIGHUP, libc::SIG_IGN);
            }
            nix::fcntl::fcntl(
                write.as_fd(),
                nix::fcntl::FcntlArg::F_SETFD(nix::fcntl::FdFlag::FD_CLOEXEC),
            )?;
            Ok(std::fs::File::from(write))
        }
        _ => {
            drop(write);
            let mut said = String::new();
            let _ = std::fs::File::from(read).read_to_string(&mut said);
            if said == "ok" {
                std::process::exit(0);
            }
            eprintln!("cooked-host: {}", said.trim());
            std::process::exit(1);
        }
    }
}

fn new(mut args: impl Iterator<Item = String>) -> std::result::Result<(), String> {
    let name = args.next().ok_or(USAGE)?;
    if !valid_name(&name) {
        return Err(format!(
            "`{name}' cannot name a session: letters, digits, `.', `_' and `-' only"
        ));
    }
    let (mut dir, mut rows, mut cols, mut ring) = (None, 24u16, 80u16, DEFAULT_RING);
    let mut note = None;
    let mut argv = Vec::new();
    while let Some(arg) = args.next() {
        let mut value = |what: &str| args.next().ok_or(format!("{what} needs a value"));
        match arg.as_str() {
            "--" => {
                argv.extend(&mut args);
                break;
            }
            "--dir" => dir = Some(PathBuf::from(value("--dir")?)),
            "--note" => note = Some(value("--note")?),
            "--rows" => {
                rows = value("--rows")?
                    .parse()
                    .map_err(|_| "--rows: not a number")?
            }
            "--cols" => {
                cols = value("--cols")?
                    .parse()
                    .map_err(|_| "--cols: not a number")?
            }
            "--ring" => {
                ring = value("--ring")?
                    .parse()
                    .map_err(|_| "--ring: not a number")?
            }
            other => return Err(format!("unknown option `{other}'\n{USAGE}")),
        }
    }
    if argv.is_empty() {
        return Err(USAGE.to_owned());
    }
    let cwd = match dir {
        Some(dir) => Some(dir),
        None => std::env::current_dir().ok(),
    };
    let mut env = environment();
    // Which session this is, for a program in it that has something to say about
    // itself to something outside -- a record to file under the name a terminal
    // attached here would look it up by. Over any value inherited: a host started
    // from inside a session is not that session.
    env.retain(|(k, _)| k != "COOKED_HOST_SESSION");
    env.push(("COOKED_HOST_SESSION".to_owned(), name.clone()));
    // And where this program is, for one that would run its commands through `run`:
    // it is not on anybody's PATH. Left alone where something has already said.
    if !env.iter().any(|(k, v)| k == "COOKED_HOST" && !v.is_empty())
        && let Some(exe) = std::env::current_exe()
            .ok()
            .and_then(|p| p.into_os_string().into_string().ok())
    {
        env.retain(|(k, _)| k != "COOKED_HOST");
        env.push(("COOKED_HOST".to_owned(), exe));
    }
    let hosts = directory();
    let mut ready = daemonize().map_err(|e| e.to_string())?;
    let spec = Spec {
        name: &name,
        argv: &argv,
        env: &env,
        cwd: cwd.as_deref(),
        rows,
        cols,
        ring,
        note: note.as_deref(),
    };
    match Host::create(&hosts, &spec) {
        Ok(host) => {
            let _ = ready.write_all(b"ok");
            drop(ready);
            let _ = std::env::set_current_dir("/");
            host.serve();
        }
        Err(e) => {
            let why = match e {
                Error::Os(Errno::EADDRINUSE) => format!("there is already a session `{name}'"),
                other => other.to_string(),
            };
            let _ = ready.write_all(why.as_bytes());
        }
    }
    Ok(())
}

/// What the `cooked-host` program does.
pub fn main() -> std::process::ExitCode {
    let mut args = std::env::args().skip(1);
    let dir = directory();
    let done = match args.next().as_deref() {
        // A command of a program in a session, not a session: see `crate::run`. Its
        // exit status is the command's, so it does not come back here.
        Some("run") => return crate::run::main(args),
        Some("new") => new(args),
        Some("list") => match args.next().as_deref() {
            None => {
                print!("{}", list(&dir));
                Ok(())
            }
            Some("--brief") => {
                print!("{}", list_brief(&dir));
                Ok(())
            }
            Some(_) => Err(USAGE.to_owned()),
        },
        Some("capture") => match args.next() {
            Some(name) => capture(&dir, &name)
                .map(|text| print!("{text}"))
                .map_err(|e| e.to_string()),
            None => Err(USAGE.to_owned()),
        },
        Some("kill") => match args.next() {
            Some(name) => kill(&dir, &name).map_err(|e| e.to_string()),
            None => Err(USAGE.to_owned()),
        },
        Some("send") => {
            let first = args.next();
            let pasting = first.as_deref() == Some("--paste");
            match if pasting { args.next() } else { first } {
                Some(name) => {
                    let mut bytes = Vec::new();
                    std::io::stdin()
                        .read_to_end(&mut bytes)
                        .map_err(|e| e.to_string())
                        .and_then(|_| {
                            if pasting {
                                paste(&dir, &name, &bytes)
                            } else {
                                send(&dir, &name, &bytes)
                            }
                            .map_err(|e| e.to_string())
                        })
                }
                None => Err(USAGE.to_owned()),
            }
        }
        _ => Err(USAGE.to_owned()),
    };
    match done {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(why) => {
            eprintln!("cooked-host: {why}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::pasted;

    #[test]
    fn a_paste_is_bracketed_only_when_asked_and_cannot_close_itself() {
        assert_eq!(pasted(b"a\nb", false), b"a\nb");
        assert_eq!(pasted(b"a\nb", true), b"\x1b[200~a\nb\x1b[201~");
        // Text that carries the closing bracket would end the paste early and have
        // the rest of itself read as typed.
        assert_eq!(
            pasted(b"safe\x1b[201~rm -rf\n", true),
            b"\x1b[200~saferm -rf\n\x1b[201~"
        );
    }
}
