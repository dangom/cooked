//! A run: one command of a program in a hosted session, with what it prints kept where
//! a terminal attached to the session can follow it.
//!
//! A program on a session's terminal may run commands whose output never reaches that
//! terminal: it reads them through a pipe and shows a summary, or nothing. `cooked-host
//! run -- COMMAND` is for such a program to put in front of them. The command runs
//! exactly as it would have -- same parent, same input, same environment and directory,
//! same exit status -- and what it prints goes where it was going, and also into a file
//! of the run's own:
//!
//! ```text
//! $COOKED_RUN_DIR/<session>/<id>.out    what it printed, both streams, as it came
//! $COOKED_RUN_DIR/<session>/<id>.json   what it was: when written first, the command,
//!                                       where, and its pid; then, rewritten, how it ended
//! ```
//!
//! That is all of it. There is no socket and nothing listens: a reader watches the
//! directory, which is why this is not part of the host proper -- the host holds one
//! terminal and replays it, and has no business carrying a second kind of stream.
//!
//! # It must never be the reason a command fails
//!
//! A program that runs every command through this has made it a part of every command.
//! So whatever cannot be done here -- no session to file the run under, a directory
//! that cannot be written (a sandbox is the usual reason), no pipe to be had -- is not
//! an error: the command is run directly, as if this had not been asked, and nothing
//! is said about it on either stream.

use crate::host::valid_name;
use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

/// How many runs a session keeps; the oldest go when there are half as many again.
const KEPT: usize = 200;

/// How long a session's runs are kept after the last of them, in seconds.
const KEPT_FOR: u64 = 14 * 24 * 60 * 60;

const USAGE: &str = "usage: cooked-host run [--label TEXT] [--key TEXT] -- PROGRAM [ARG...]";

/// The directory runs are kept in, a directory to a session.
pub fn directory() -> PathBuf {
    if let Some(dir) = std::env::var_os("COOKED_RUN_DIR").filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    let state = std::env::var_os("XDG_STATE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
        });
    state.join("cooked/runs")
}

/// `cooked-host run`, given what followed the verb.
pub fn main(mut args: impl Iterator<Item = String>) -> ExitCode {
    let (mut label, mut key) = (None, None);
    let mut argv: Vec<String> = Vec::new();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--label" => label = args.next(),
            "--key" => key = args.next(),
            "--" => {
                argv = args.collect();
                break;
            }
            _ => break,
        }
    }
    if argv.is_empty() {
        eprintln!("cooked-host: {USAGE}");
        return ExitCode::FAILURE;
    }
    match observe(&argv, label.as_deref(), key.as_deref()) {
        Some(code) => ExitCode::from(code),
        None => {
            // Not to be observed: be the command, and nothing else.
            let failed = Command::new(&argv[0]).args(&argv[1..]).exec();
            eprintln!("cooked-host: {}: {failed}", argv[0]);
            ExitCode::from(127)
        }
    }
}

/// A string as JSON.
fn json(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn now() -> (u64, u32) {
    let since = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    (since.as_secs(), since.subsec_micros())
}

/// Write TEXT to PATH so that a reader sees all of it or the file as it was.
fn replace(path: &Path, text: &str) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    file.write_all(text.as_bytes())?;
    std::fs::rename(&tmp, path)
}

/// Whether descriptors A and B are the same open file: one pipe given as both streams.
fn same_file(a: RawFd, b: RawFd) -> bool {
    // SAFETY: `fstat` writes into the buffer it is given and nothing else.
    unsafe {
        let (mut sa, mut sb): (libc::stat, libc::stat) = (std::mem::zeroed(), std::mem::zeroed());
        libc::fstat(a, &mut sa) == 0
            && libc::fstat(b, &mut sb) == 0
            && sa.st_dev == sb.st_dev
            && sa.st_ino == sb.st_ino
    }
}

fn pipe() -> Option<(OwnedFd, OwnedFd)> {
    let mut fds = [0 as RawFd; 2];
    // SAFETY: `pipe` fills the two descriptors, which are then owned here and nowhere else.
    unsafe {
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            return None;
        }
        for fd in fds {
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        }
        Some((OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])))
    }
}

/// Write all of BYTES to FD, or say that it could not be done.
fn write_all(fd: RawFd, mut bytes: &[u8]) -> bool {
    while !bytes.is_empty() {
        // SAFETY: the pointer and length are those of a live slice.
        let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if n > 0 {
            bytes = &bytes[n as usize..];
        } else if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
        {
            continue;
        } else {
            return false;
        }
    }
    true
}

/// One of the command's streams: where it is read from here and where it was going.
struct Stream {
    from: Option<OwnedFd>,
    to: RawFd,
}

/// Pass on what the streams have, to where it was going and to KEEP, until WAIT
/// milliseconds pass with nothing to read. Whether every stream has ended.
fn drain(streams: &mut [Stream], keep: &mut std::fs::File, wait: i32) -> bool {
    let mut buffer = [0u8; 65536];
    loop {
        let mut fds: Vec<libc::pollfd> = streams
            .iter()
            .filter_map(|s| s.from.as_ref())
            .map(|fd| libc::pollfd {
                fd: fd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            })
            .collect();
        if fds.is_empty() {
            return true;
        }
        // SAFETY: the array is live and its length is the one given.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, wait) };
        if ready == 0 {
            return false;
        }
        if ready < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return true;
        }
        for polled in fds.iter().filter(|p| p.revents != 0) {
            let Some(stream) = streams
                .iter_mut()
                .find(|s| s.from.as_ref().map(AsRawFd::as_raw_fd) == Some(polled.fd))
            else {
                continue;
            };
            // SAFETY: the buffer is live and its length is the one given.
            let n = unsafe { libc::read(polled.fd, buffer.as_mut_ptr().cast(), buffer.len()) };
            if n > 0 {
                let bytes = &buffer[..n as usize];
                // Whoever was reading has gone: the command is told the way it would
                // have been, by its own next write failing.
                if !write_all(stream.to, bytes) {
                    stream.from = None;
                }
                // Keeping it is the extra, and may fail without anyone being told.
                let _ = keep.write_all(bytes);
            } else if n == 0
                || std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
            {
                stream.from = None;
            }
        }
    }
}

/// Run ARGV with what it prints kept as well as passed on. Its exit status; or `None`
/// if it was not started, because the run could not be kept.
fn observe(argv: &[String], label: Option<&str>, key: Option<&str>) -> Option<u8> {
    let session = std::env::var("COOKED_HOST_SESSION").ok()?;
    if !valid_name(&session) {
        return None;
    }
    let dir = directory().join(&session);
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)
        .ok()?;
    let (secs, micros) = now();
    let id = format!("{secs}.{micros:06}-{}", std::process::id());
    let out_path = dir.join(format!("{id}.out"));
    let meta_path = dir.join(format!("{id}.json"));
    let mut keep = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&out_path)
        .ok()?;
    let abandon = || {
        let _ = std::fs::remove_file(&out_path);
        let _ = std::fs::remove_file(&meta_path);
    };

    let one = same_file(1, 2);
    let Some((out_read, out_write)) = pipe() else {
        abandon();
        return None;
    };
    let err = if one { None } else { pipe() };
    if !one && err.is_none() {
        abandon();
        return None;
    }
    let (err_read, err_write) = match err {
        Some((r, w)) => (Some(r), Some(w)),
        None => (None, None),
    };
    let child = {
        let mut command = Command::new(&argv[0]);
        command.args(&argv[1..]);
        let err_end = match err_write {
            Some(w) => w,
            None => match out_write.try_clone() {
                Ok(w) => w,
                Err(_) => {
                    abandon();
                    return None;
                }
            },
        };
        command.stdout(Stdio::from(out_write));
        command.stderr(Stdio::from(err_end));
        command.spawn()
        // The command is dropped here, and with it this process's ends of the pipes:
        // held, they would keep the streams from ever ending.
    };
    let mut child = match child {
        Ok(child) => child,
        Err(_) => {
            // Starting it directly will say why, in the words it always has.
            abandon();
            return None;
        }
    };

    let cwd = std::env::current_dir()
        .map(|d| d.to_string_lossy().into_owned())
        .unwrap_or_default();
    let head = format!(
        "{{\"id\":{},\"session\":{},\"pid\":{},\"cwd\":{},\"argv\":[{}],\"label\":{},\"key\":{},\"started\":{secs}.{micros:06}",
        json(&id),
        json(&session),
        child.id(),
        json(&cwd),
        argv.iter().map(|a| json(a)).collect::<Vec<_>>().join(","),
        label.map_or("null".to_owned(), json),
        key.map_or("null".to_owned(), json),
    );
    let _ = replace(&meta_path, &format!("{head}}}\n"));

    let mut streams = vec![Stream {
        from: Some(out_read),
        to: 1,
    }];
    if let Some(read) = err_read {
        streams.push(Stream {
            from: Some(read),
            to: 2,
        });
    }
    // Until the command is gone. Its streams usually end with it; where they do not,
    // something it started and left behind still holds them.
    let status = loop {
        let ended = drain(&mut streams, &mut keep, 100);
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if ended => break child.wait().ok(),
            Ok(None) => {}
            Err(_) => break None,
        }
    };
    let ended = drain(&mut streams, &mut keep, 20);
    let (secs, micros) = now();
    let how = match status {
        Some(status) => match (status.code(), status.signal()) {
            (Some(code), _) => format!(",\"exit\":{code}"),
            (None, Some(signal)) => format!(",\"signal\":{signal}"),
            _ => String::new(),
        },
        None => String::new(),
    };
    let _ = replace(
        &meta_path,
        &format!("{head},\"ended\":{secs}.{micros:06}{how}}}\n"),
    );
    if !ended {
        // What the command left behind goes on being passed on and kept, by a process
        // of its own, exactly as it would have gone on reaching whoever reads this
        // one's streams; and this one ends when the command did.
        // SAFETY: this program has one thread, so the child finds no lock held by a
        // thread that did not come with it.
        if unsafe { libc::fork() } == 0 {
            drain(&mut streams, &mut keep, -1);
            // SAFETY: nothing of this process's is to be run on the way out.
            unsafe { libc::_exit(0) };
        }
    }
    prune(&dir);
    Some(match status {
        Some(status) => match (status.code(), status.signal()) {
            (Some(code), _) => code as u8,
            (None, Some(signal)) => 128u8.wrapping_add(signal as u8),
            _ => 1,
        },
        None => 1,
    })
}

/// Remove the oldest runs of the session in DIR beyond those kept, and the sessions
/// beside it that have had no run for a long time.
fn prune(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut metas: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    if metas.len() <= KEPT + KEPT / 2 {
        return;
    }
    // A run's name begins with when it started, so the names' order is their age.
    metas.sort();
    for meta in &metas[..metas.len() - KEPT] {
        let _ = std::fs::remove_file(meta.with_extension("out"));
        let _ = std::fs::remove_file(meta);
    }
    let Some(parent) = dir.parent() else { return };
    let Ok(sessions) = std::fs::read_dir(parent) else {
        return;
    };
    let now = SystemTime::now();
    for session in sessions.filter_map(Result::ok) {
        let old = session
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|at| now.duration_since(at).ok())
            .is_some_and(|age| age.as_secs() > KEPT_FOR);
        if old && session.path() != dir {
            let _ = std::fs::remove_dir_all(session.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::json;

    #[test]
    fn a_string_is_json_whatever_is_in_it() {
        assert_eq!(json("a\"b\\c\nd\te\u{1}"), "\"a\\\"b\\\\c\\nd\\te\\u0001\"");
        assert_eq!(json("ünï 'q'"), "\"ünï 'q'\"");
    }
}
