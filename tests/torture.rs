//! Hostile and nonsensical input, by the thousand.
//!
//! The emulator reads bytes from a program it does not control, so "it does not
//! panic, whatever arrives" is a property rather than a hope, and the unit tests in
//! `src/emu/term/tests.rs` cannot state it: each of them is one sequence somebody
//! thought of. This generates the ones nobody did.
//!
//! Two properties, over streams built from the grammar of a terminal rather than
//! from uniform noise (uniform bytes almost never spell a complete CSI, so they
//! exercise the ground state and little else):
//!
//! 1. **Nothing panics**, at any screen size down to 1x1, with drains and resizes
//!    landing between any two reads.
//! 2. **Where a read ends does not matter.** A pty hands the reader whatever has
//!    arrived, so a sequence can be cut anywhere, mid-UTF-8 and mid-escape included.
//!    The same bytes fed whole and fed in fragments have to leave the same screen.
//!
//! Deterministic: every case is a seed, and a failure prints the seed and writes the
//! bytes to `$TMPDIR/cooked-torture-<seed>.bin` so it can become a unit test. Set
//! `COOKED_TORTURE_CASES` to run more than the default, and `COOKED_TORTURE_SEED` to
//! replay one.

use cooked::emu::Term;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// xorshift64*: small enough to read, and good enough to pick grammar productions.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        // A zero state never leaves zero; the constant also spreads small seeds apart.
        Self(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1)
    }

    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    fn chance(&mut self, percent: usize) -> bool {
        self.below(100) < percent
    }

    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

/// A parameter a program might send, weighted towards the ones that break things:
/// zero, one, the edges of the screen, and numbers no screen is as big as.
fn param(rng: &mut Rng) -> String {
    match rng.below(12) {
        0 => String::new(),
        1 => "0".into(),
        2 | 3 => "1".into(),
        4..=7 => rng.below(130).to_string(),
        8 => "65535".into(),
        9 => "65536".into(),
        10 => "4294967296".into(),
        _ => "99999999999999999999".into(),
    }
}

fn params(rng: &mut Rng) -> String {
    let count = *rng.pick(&[0, 1, 1, 1, 2, 2, 3, 5, 40]);
    let mut out = String::new();
    for i in 0..count {
        if i > 0 {
            out.push(if rng.chance(15) { ':' } else { ';' });
        }
        out.push_str(&param(rng));
    }
    out
}

fn text(rng: &mut Rng, out: &mut Vec<u8>) {
    const SAMPLES: &[&str] = &[
        "a",
        "hello world",
        " ",
        "The quick brown fox jumps over the lazy dog. ",
        "日本語",
        "한",
        "e\u{301}",
        "\u{301}",
        "👩‍👩‍👧‍👦",
        "🇨🇦",
        "👍🏽",
        "\u{200b}",
        "\u{200d}",
        "\u{fe0f}",
        "☺\u{fe0f}",
        "\u{ad}",
        "─│┌┐└┘├┤",
        "\u{e0b0}",
        "\u{10ffff}",
        "\u{feff}",
        "ﷺ",
        "\u{202e}abc",
    ];
    for _ in 0..=rng.below(4) {
        out.extend_from_slice(rng.pick(SAMPLES).as_bytes());
    }
}

fn control(rng: &mut Rng, out: &mut Vec<u8>) {
    const C0: &[u8] = b"\r\n\n\n\t\x08\x07\x0b\x0c\x0e\x0f\x00\x7f\x18\x1a\x05";
    out.push(*rng.pick(C0));
}

fn csi(rng: &mut Rng, out: &mut Vec<u8>) {
    const FINALS: &[u8] = b"ABCDEFGHIJKLMPSTXZ@`abcdefghilmnpqrstux";
    const PRIVATE: &[&str] = &["", "", "", "?", "?", ">", "<", "="];
    const INTERMEDIATE: &[&str] = &["", "", "", "", " ", "!", "\"", "$", "'", "#"];
    out.extend_from_slice(b"\x1b[");
    out.extend_from_slice(rng.pick(PRIVATE).as_bytes());
    out.extend_from_slice(params(rng).as_bytes());
    out.extend_from_slice(rng.pick(INTERMEDIATE).as_bytes());
    if rng.chance(95) {
        out.push(*rng.pick(FINALS));
    } else {
        // Any final at all, the ones nobody assigned included.
        out.push(0x40 + rng.below(0x3f) as u8);
    }
}

/// Modes by number, since a uniform parameter almost never names one that exists.
fn mode(rng: &mut Rng, out: &mut Vec<u8>) {
    const DEC: &[u16] = &[
        1, 3, 5, 6, 7, 12, 25, 45, 47, 66, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015,
        1016, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 2048,
    ];
    const ANSI: &[u16] = &[4, 12, 20];
    let set = if rng.chance(50) { 'h' } else { 'l' };
    if rng.chance(85) {
        out.extend_from_slice(format!("\x1b[?{}{set}", rng.pick(DEC)).as_bytes());
    } else {
        out.extend_from_slice(format!("\x1b[{}{set}", rng.pick(ANSI)).as_bytes());
    }
}

/// The sequences that move text between rows, which is where a grid goes out of bounds.
fn region(rng: &mut Rng, out: &mut Vec<u8>) {
    let seq = match rng.below(10) {
        0 => format!("\x1b[{};{}r", param(rng), param(rng)),
        1 => "\x1b[r".into(),
        2 => format!("\x1b[{};{}H", param(rng), param(rng)),
        3 => format!("\x1b[{}L", param(rng)),
        4 => format!("\x1b[{}M", param(rng)),
        5 => format!("\x1b[{}S", param(rng)),
        6 => format!("\x1b[{}T", param(rng)),
        7 => format!("\x1b[{};{}s", param(rng), param(rng)),
        8 => format!("\x1b[{}J", rng.below(4)),
        _ => format!("\x1b[{}K", rng.below(3)),
    };
    out.extend_from_slice(seq.as_bytes());
}

fn sgr(rng: &mut Rng, out: &mut Vec<u8>) {
    const SAMPLES: &[&str] = &[
        "0",
        "1",
        "3",
        "4",
        "4:3",
        "7",
        "9",
        "21",
        "31",
        "42",
        "38;5;200",
        "48;5;999",
        "38;2;1;2;3",
        "38:2::1:2:3",
        "38;2",
        "38",
        "58:2::9:9:9",
        "58;5",
        "59",
        "90;107",
        "38;2;300;300;300",
    ];
    out.extend_from_slice(b"\x1b[");
    for i in 0..=rng.below(3) {
        if i > 0 {
            out.push(b';');
        }
        out.extend_from_slice(rng.pick(SAMPLES).as_bytes());
    }
    out.push(b'm');
}

fn esc(rng: &mut Rng, out: &mut Vec<u8>) {
    const SAMPLES: &[&str] = &[
        "\x1b7", "\x1b8", "\x1bM", "\x1bD", "\x1bE", "\x1bH", "\x1bc", "\x1b=", "\x1b>", "\x1b(0",
        "\x1b(B", "\x1b)0", "\x1b#8", "\x1b#3", "\x1bn", "\x1bo", "\x1bN", "\x1bO", "\x1b\\",
        "\x1b", "\x1b\x1b", "\x1bZ", "\x1b%G", "\x1b F",
    ];
    out.extend_from_slice(rng.pick(SAMPLES).as_bytes());
}

fn terminator(rng: &mut Rng, out: &mut Vec<u8>) {
    match rng.below(10) {
        0..=4 => out.push(0x07),
        5..=8 => out.extend_from_slice(b"\x1b\\"),
        // Never terminated: whatever follows is read as more of the string.
        _ => {}
    }
}

fn payload(rng: &mut Rng, out: &mut Vec<u8>) {
    const SAMPLES: &[&str] = &[
        "",
        "x",
        "file:///tmp/a b",
        "https://example.invalid/?q=1;2",
        "id=abc:def",
        ";",
        ";;",
        "=",
        "aGVsbG8=",
        "!!!not base64!!!",
        "?",
        "\u{1f600}",
        "rgb:ff/00/00",
        "#12",
        "k=v;k=v;k=v",
    ];
    for _ in 0..rng.below(4) {
        out.extend_from_slice(rng.pick(SAMPLES).as_bytes());
    }
    if rng.chance(3) {
        out.extend(std::iter::repeat_n(b'A', 1 + rng.below(70_000)));
    }
}

fn osc(rng: &mut Rng, out: &mut Vec<u8>) {
    const CODES: &[&str] = &[
        "0", "1", "2", "4", "7", "8", "9", "10", "11", "12", "22", "51", "52", "66", "104", "110",
        "112", "133", "777", "1337", "99999", "", "x",
    ];
    out.extend_from_slice(b"\x1b]");
    let code = *rng.pick(CODES);
    out.extend_from_slice(code.as_bytes());
    out.push(b';');
    match code {
        "133" => {
            out.push(*rng.pick(b"ABCDPINLZ?"));
            if rng.chance(50) {
                out.extend_from_slice(format!(";{}", param(rng)).as_bytes());
            }
            if rng.chance(30) {
                out.extend_from_slice(b";aid=1;k=s;cl=m;cmdline_url=ls%20-l");
            }
        }
        "8" => {
            if rng.chance(50) {
                out.extend_from_slice(b"id=x");
            }
            out.push(b';');
            if rng.chance(70) {
                out.extend_from_slice(format!("https://e.invalid/{}", rng.below(5)).as_bytes());
            }
        }
        "1337" => {
            out.extend_from_slice(b"File=inline=1;width=");
            out.extend_from_slice(param(rng).as_bytes());
            out.extend_from_slice(b";height=auto;size=3:");
            payload(rng, out);
        }
        "51" => {
            out.push(*rng.pick(b"ACEHR?"));
            payload(rng, out);
        }
        "66" => {
            out.extend_from_slice(
                format!("s={}:w={}:n=1:d=2;", rng.below(9), rng.below(9)).as_bytes(),
            );
            text(rng, out);
        }
        _ => payload(rng, out),
    }
    terminator(rng, out);
}

/// Kitty graphics: every key the protocol has, with values it does and does not allow.
fn kitty(rng: &mut Rng, out: &mut Vec<u8>) {
    const KEYS: &[u8] = b"aftoimsvSOxywhXYcrCUzpqIdN";
    const ACTIONS: &[u8] = b"tTpdqfac?";
    out.extend_from_slice(b"\x1b_G");
    for i in 0..rng.below(8) {
        if i > 0 {
            out.push(b',');
        }
        let key = *rng.pick(KEYS);
        out.push(key);
        out.push(b'=');
        match key {
            b'a' => out.push(*rng.pick(ACTIONS)),
            b'f' => out.extend_from_slice(rng.pick(&["24", "32", "100", "7"]).as_bytes()),
            b't' => out.push(*rng.pick(b"dfts?")),
            b'o' => out.push(*rng.pick(b"zq")),
            b'm' | b'q' => out.push(*rng.pick(b"0123")),
            _ => out.extend_from_slice(param(rng).as_bytes()),
        }
    }
    out.push(b';');
    match rng.below(5) {
        // One opaque pixel of each format a transmission can name.
        0 => out.extend_from_slice(b"/////w=="),
        1 => out.extend_from_slice(b"////"),
        // The PNG signature and nothing after it.
        2 => out.extend_from_slice(b"iVBORw0KGgo="),
        // A zlib header that promises a stream and does not deliver one.
        3 => out.extend_from_slice(b"eJw="),
        _ => payload(rng, out),
    }
    terminator(rng, out);
}

fn sixel(rng: &mut Rng, out: &mut Vec<u8>) {
    out.extend_from_slice(b"\x1bP");
    out.extend_from_slice(params(rng).as_bytes());
    out.push(b'q');
    for _ in 0..rng.below(12) {
        match rng.below(8) {
            0 => out.extend_from_slice(format!("\"{}", params(rng)).as_bytes()),
            1 => out.extend_from_slice(format!("#{}", params(rng)).as_bytes()),
            2 => out.extend_from_slice(format!("!{}~", param(rng)).as_bytes()),
            3 => out.push(b'$'),
            4 => out.push(b'-'),
            _ => out.push(0x3f + rng.below(64) as u8),
        }
    }
    terminator(rng, out);
}

/// Other device control strings: the queries a program sends and reads the answer to.
fn dcs(rng: &mut Rng, out: &mut Vec<u8>) {
    const SAMPLES: &[&str] = &[
        "\x1bP$qm",
        "\x1bP$q q",
        "\x1bP$qr",
        "\x1bP$q\"p",
        "\x1bP+q544e",
        "\x1bP+q",
        "\x1bP=1s",
        "\x1bP=2s",
        "\x1bP1000p",
        "\x1bPtmux;\x1b\x1b]0;x\x07",
        "\x1b^private",
        "\x1bXstart of string",
    ];
    out.extend_from_slice(rng.pick(SAMPLES).as_bytes());
    if rng.chance(30) {
        payload(rng, out);
    }
    terminator(rng, out);
}

fn noise(rng: &mut Rng, out: &mut Vec<u8>) {
    for _ in 0..=rng.below(6) {
        out.push(rng.below(256) as u8);
    }
}

/// Bytes that are almost UTF-8.
fn bad_utf8(rng: &mut Rng, out: &mut Vec<u8>) {
    const SAMPLES: &[&[u8]] = &[
        b"\xc3",
        b"\xe3\x81",
        b"\xf0\x9f\x98",
        b"\x80",
        b"\xc0\x80",
        b"\xed\xa0\x80",
        b"\xf4\x90\x80\x80",
        b"\xff\xfe",
        b"\xe3\x81\x1b[1m",
        b"\x9b1m",
        b"\x9d0;x\x9c",
        b"\x90q\x9c",
    ];
    out.extend_from_slice(rng.pick(SAMPLES));
}

fn stream(rng: &mut Rng, tokens: usize) -> Vec<u8> {
    let mut out = Vec::new();
    for _ in 0..tokens {
        match rng.below(100) {
            0..=24 => text(rng, &mut out),
            25..=36 => control(rng, &mut out),
            37..=50 => csi(rng, &mut out),
            51..=58 => region(rng, &mut out),
            59..=64 => mode(rng, &mut out),
            65..=70 => sgr(rng, &mut out),
            71..=76 => esc(rng, &mut out),
            77..=84 => osc(rng, &mut out),
            85..=88 => kitty(rng, &mut out),
            89..=91 => sixel(rng, &mut out),
            92..=94 => dcs(rng, &mut out),
            95..=97 => bad_utf8(rng, &mut out),
            _ => noise(rng, &mut out),
        }
    }
    out
}

fn size(rng: &mut Rng) -> (usize, usize) {
    match rng.below(10) {
        0 => (1, 1),
        1 => (1, 1 + rng.below(200)),
        2 => (1 + rng.below(60), 1),
        3 => (2, 2),
        _ => (1 + rng.below(50), 1 + rng.below(160)),
    }
}

/// What a case left behind, as something two runs can be compared on.
fn snapshot(term: &mut Term) -> String {
    let delta = term.drain();
    let mut out = format!(
        "cursor={:?} visible={} shape={:?} alt={} keys={:?} height={} used={} head={}\n",
        delta.cursor,
        delta.cursor_visible,
        delta.cursor_shape,
        delta.alt,
        delta.keys,
        delta.height,
        delta.used,
        delta.head,
    );
    for row in term.screen().rows() {
        out.push_str(&row.to_text());
        out.push('\n');
    }
    out.push_str("--- scrolled\n");
    for line in &delta.scrolled {
        for run in &line.runs {
            out.push_str(&run.text);
        }
        out.push_str(if line.wrapped { "\\\n" } else { "\n" });
    }
    out
}

fn cases(default: u64) -> std::ops::Range<u64> {
    if let Some(seed) = std::env::var("COOKED_TORTURE_SEED")
        .ok()
        .and_then(|s| s.parse().ok())
    {
        return seed..seed + 1;
    }
    let count = std::env::var("COOKED_TORTURE_CASES")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default);
    0..count
}

/// Run CASE for every seed, and on a failure say which one and keep its bytes.
fn for_each_seed(name: &str, default: u64, case: impl Fn(u64) -> Result<(), String>) {
    let mut failures = Vec::new();
    for seed in cases(default) {
        let outcome = catch_unwind(AssertUnwindSafe(|| case(seed)));
        let problem = match outcome {
            Ok(Ok(())) => continue,
            Ok(Err(problem)) => problem,
            Err(panic) => panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| (*s).to_owned()))
                .unwrap_or_else(|| "panic".into()),
        };
        failures.push(format!("seed {seed}: {problem}"));
        if failures.len() >= 5 {
            break;
        }
    }
    assert!(
        failures.is_empty(),
        "{name}: {} failing seed(s); replay one with COOKED_TORTURE_SEED=<seed>\n{}",
        failures.len(),
        failures.join("\n")
    );
}

fn keep(seed: u64, bytes: &[u8]) -> String {
    let path = std::env::temp_dir().join(format!("cooked-torture-{seed}.bin"));
    let _ = std::fs::write(&path, bytes);
    path.display().to_string()
}

#[test]
fn nothing_a_program_prints_panics() {
    for_each_seed("no panic", 500, |seed| {
        let mut rng = Rng::new(seed);
        let (rows, cols) = size(&mut rng);
        let tokens = 60 + rng.below(200);
        let bytes = stream(&mut rng, tokens);
        let path = keep(seed, &bytes);
        let mut term = Term::new(rows, cols);
        let mut rest = &bytes[..];
        while !rest.is_empty() {
            let take = (1 + rng.below(64)).min(rest.len());
            term.feed(&rest[..take]);
            rest = &rest[take..];
            match rng.below(20) {
                0 => {
                    let (rows, cols) = size(&mut rng);
                    term.resize(rows, cols);
                }
                1 | 2 => drop(term.drain()),
                3 => term.touch_all(),
                _ => {}
            }
        }
        let delta = term.drain();
        let (height, width) = (term.screen().height(), term.screen().width());
        let cursor = format!("{:?}", delta.cursor);
        if term.screen().rows().count() != height {
            return Err(format!("row count disagrees with height; bytes in {path}"));
        }
        if height == 0 || width == 0 {
            return Err(format!(
                "a {height}x{width} screen, cursor {cursor}; bytes in {path}"
            ));
        }
        let _ = std::fs::remove_file(path);
        Ok(())
    });
}

#[test]
fn where_a_read_ends_does_not_change_the_screen() {
    for_each_seed("split reads", 200, |seed| {
        let mut rng = Rng::new(seed ^ 0x5eed);
        let (rows, cols) = size(&mut rng);
        let tokens = 40 + rng.below(120);
        let bytes = stream(&mut rng, tokens);

        let mut whole = Term::new(rows, cols);
        whole.feed(&bytes);
        let expected = snapshot(&mut whole);

        for attempt in 0..3 {
            let mut split = Term::new(rows, cols);
            let mut rest = &bytes[..];
            let limit = [1, 3, 17][attempt];
            while !rest.is_empty() {
                let take = (1 + rng.below(limit)).min(rest.len());
                split.feed(&rest[..take]);
                rest = &rest[take..];
            }
            let got = snapshot(&mut split);
            if got != expected {
                let path = keep(seed, &bytes);
                return Err(format!(
                    "{rows}x{cols}, reads of at most {limit} byte(s) differ from one read; \
                     bytes in {path}\n--- one read\n{expected}\n--- split\n{got}"
                ));
            }
        }
        Ok(())
    });
}

/// Where BYTES can be cut in two so that the halves, read separately, leave a different
/// screen than one read of the whole.
fn differing_cut(rows: usize, cols: usize, bytes: &[u8]) -> Option<usize> {
    let mut whole = Term::new(rows, cols);
    whole.feed(bytes);
    let expected = snapshot(&mut whole);
    (1..bytes.len()).find(|&cut| {
        let mut split = Term::new(rows, cols);
        split.feed(&bytes[..cut]);
        split.feed(&bytes[cut..]);
        snapshot(&mut split) != expected
    })
}

/// Shrink a failing split-read case to the bytes that matter.
///
/// `COOKED_TORTURE_SEED=85 cargo test --test torture minimize -- --ignored --nocapture`
#[test]
#[ignore = "a tool: shrinks the case COOKED_TORTURE_SEED names"]
fn minimize() {
    for seed in cases(0) {
        let mut rng = Rng::new(seed ^ 0x5eed);
        let (rows, cols) = size(&mut rng);
        let tokens = 40 + rng.below(120);
        let mut bytes = stream(&mut rng, tokens);
        if differing_cut(rows, cols, &bytes).is_none() {
            println!("seed {seed}: no single cut changes the screen");
            continue;
        }
        let mut chunk = bytes.len() / 2;
        while chunk > 0 {
            let mut at = 0;
            while at < bytes.len() {
                let end = (at + chunk).min(bytes.len());
                let mut candidate = bytes[..at].to_vec();
                candidate.extend_from_slice(&bytes[end..]);
                if differing_cut(rows, cols, &candidate).is_some() {
                    bytes = candidate;
                } else {
                    at = end;
                }
            }
            chunk /= 2;
        }
        println!(
            "seed {seed}: {rows}x{cols}, {} byte(s): {:?}",
            bytes.len(),
            String::from_utf8_lossy(&bytes)
        );
        println!("  raw: {}", bytes.escape_ascii());
        println!("  cut after byte {:?}", differing_cut(rows, cols, &bytes));
    }
}
