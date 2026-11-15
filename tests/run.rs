//! `cooked-host run`: a command observed is the command, and what it printed is kept.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const HOST: &str = env!("CARGO_BIN_EXE_cooked-host");

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cooked-run-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn run(dir: &Path, session: Option<&str>, script: &str) -> Output {
    let mut command = Command::new(HOST);
    command
        .args([
            "run",
            "--label",
            "a \"label\"",
            "--key",
            "k",
            "--",
            "/bin/sh",
            "-c",
            script,
        ])
        .env("COOKED_RUN_DIR", dir)
        .env_remove("COOKED_HOST_SESSION")
        .stdin(Stdio::null());
    if let Some(session) = session {
        command.env("COOKED_HOST_SESSION", session);
    }
    command.output().unwrap()
}

fn kept(dir: &Path, session: &str, extension: &str) -> String {
    let file = std::fs::read_dir(dir.join(session))
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .find(|p| p.extension().is_some_and(|x| x == extension))
        .unwrap();
    std::fs::read_to_string(file).unwrap()
}

#[test]
fn a_command_is_itself_and_what_it_printed_is_kept() {
    let dir = scratch("kept");
    let output = run(&dir, Some("s"), "echo out; echo err >&2; exit 3");
    assert_eq!(output.status.code(), Some(3));
    assert_eq!(output.stdout, b"out\n");
    assert_eq!(output.stderr, b"err\n");
    assert_eq!(kept(&dir, "s", "out"), "out\nerr\n");
    let meta = kept(&dir, "s", "json");
    assert!(meta.contains("\"label\":\"a \\\"label\\\"\""), "{meta}");
    assert!(meta.contains("\"key\":\"k\""), "{meta}");
    assert!(meta.contains("\"session\":\"s\""), "{meta}");
    assert!(meta.contains("\"exit\":3"), "{meta}");
    assert!(meta.contains("\"ended\":"), "{meta}");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn outside_a_session_nothing_is_kept_and_nothing_changes() {
    let dir = scratch("outside");
    let output = run(&dir, None, "echo out; exit 5");
    assert_eq!(output.status.code(), Some(5));
    assert_eq!(output.stdout, b"out\n");
    assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_run_that_cannot_be_kept_is_still_run_and_says_nothing() {
    let output = run(
        Path::new("/dev/null/nowhere"),
        Some("s"),
        "echo out; exit 6",
    );
    assert_eq!(output.status.code(), Some(6));
    assert_eq!(output.stdout, b"out\n");
    assert_eq!(output.stderr, b"");
}

#[test]
fn a_name_that_is_a_path_names_no_session() {
    let dir = scratch("path");
    let output = run(&dir, Some("../escape"), "echo out");
    assert_eq!(output.stdout, b"out\n");
    assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
    assert!(!dir.parent().unwrap().join("escape").exists());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn it_ends_with_the_command_whatever_the_command_left_behind() {
    let dir = scratch("behind");
    let started = std::time::Instant::now();
    // Not through `output`, which waits for the streams to end: the point is that
    // this process is gone while something still holds them.
    let status = Command::new(HOST)
        .args([
            "run",
            "--",
            "/bin/sh",
            "-c",
            "echo first; (sleep 2; echo late) & echo done",
        ])
        .env("COOKED_RUN_DIR", &dir)
        .env("COOKED_HOST_SESSION", "s")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    assert!(started.elapsed() < std::time::Duration::from_millis(1500));
    assert!(kept(&dir, "s", "json").contains("\"exit\":0"));
    std::thread::sleep(std::time::Duration::from_millis(2600));
    assert_eq!(kept(&dir, "s", "out"), "first\ndone\nlate\n");
    let _ = std::fs::remove_dir_all(dir);
}
