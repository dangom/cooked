# Changelog

All notable changes to this fork of [cooked](https://github.com/vodik/cooked) are
documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Nothing has been released yet, so everything is under Unreleased.

## [Unreleased]

Everything since the fork from upstream at `dd8e9fc` (2026-09-06).

### Added

- `cooked-exec` runs a program other than a shell, such as tmux, as the
  terminal's child. `cooked-keymap-exceptions` keeps keys such as `C-x`, `M-x`
  and `M-:` with Emacs. Graphical control chords, Shift-Tab and yank are
  forwarded, and the tty character is sent for job control.
- `cooked-host`: sessions that outlive Emacs. Each session can run under a small
  host program of its own, which keeps the recent output and replays it on
  attach, so scrollback, prompt marks, links and images come back. Commands
  `cooked-host-shell`, `cooked-host-exec`, `cooked-host-attach`,
  `cooked-host-detach`, `cooked-host-kill` and `cooked-host-restore`; hosted
  buffers are restored by `desktop-save-mode` and `persp-mode`. The binary also
  works from scripts (`new`, `list`, `capture`, `send`, `kill`) and is built by
  `make host`.
- Navigation of a running program's output as Emacs text (`cooked-navigate`).
  A program that reads every key but prints onto the main screen, such as an
  agent's chat or a REPL, can be read with motion, isearch, the region and
  `M-w` while it keeps running. It applies from terminal state alone and turns
  off when the program takes the alternate screen or the mouse. See
  `cooked-navigation-keys` and `cooked-navigable-programs`.
- Shell-prompt keys at a navigable program's input: `C-p`/`C-n` move, `M-p`/`M-n`
  recall the program's history, `C-s`/`C-r` start isearch over the output, and
  `C-y` pastes the kill ring. The program's own bindings stay reachable with
  `C-c C-q`.
- A dock for a program's input (`cooked-dock`). Scrolling a navigable
  program's window away from the bottom splits its live rows into a window
  underneath, so a reply can be typed while the history is read. Scrolling back
  down, moving onto the live rows or submitting with `RET` joins them again.
  See `cooked-dock`, `cooked-dock-context-rows` and `cooked-dock-max-fraction`.
- `cooked-program-line-editor`: set to `emacs` to edit a navigable program's
  input line with Emacs commands (motion, the mark and region, kill and yank,
  `M-p` history, `S-RET` for a newline). The first character typed into an
  empty line goes to the program; if the program echoes it, Emacs takes the
  line, and `RET` hands it back as one bracketed paste followed by Enter. A
  menu does not echo, so its keys stay the program's. Characters in
  `cooked-program-line-delegate-characters` (`/`, `@`, `!`) leave the line with
  the program, and `cooked-program-line-pass-keys` (Escape, Shift-Tab) reach it
  while Emacs keeps the line. What the program draws after its cursor (its own
  cursor, a suggestion) is hidden while Emacs owns the line, every line command
  stops at the line's edges, and the program's rows below it are read-only.
  Shells and remote logins such as `ssh` are never taken, marked or not
  (`cooked-program-line-shells`); a shell's line is `cooked-shell-line-editor`'s. Off by default.
- `cooked-drain-functions`, run once each drain is applied, for packages that
  wait on the child's answer to something they sent.
- A hosted program is told its session's name in `COOKED_HOST_SESSION` and
  where the host program is in `COOKED_HOST`, and `cooked-host-attach-hook`
  runs in a buffer attached to a session.
- Runs: `cooked-host run -- COMMAND` runs a command of a program in a hosted
  session unchanged and also keeps what it prints, as it comes, under the
  session's name. `cooked-run` follows one from Emacs in a buffer that grows
  with it (`cooked-run-latest`, `cooked-run-select`, `cooked-runs`,
  `cooked-run-buffer`).
- `cooked-popup`: a look at a buffer or a file in a child frame over the current
  one, without touching the windows underneath. `cooked-popup-file` shows a file
  read-only in its own major mode, without running mode hooks or reading local
  variables; `cooked-popup-open-file` does so for file names in a terminal's
  output, as a `cooked-file-open-function`. `cooked-popup-buffer` shows a
  package's own buffer, with `cooked-popup-mode` for its keys (`q` close, `l`
  back, `v` open in a window). The frame is one size whatever it shows, so
  stepping between buffers neither moves nor resizes it (`cooked-popup-top`,
  `cooked-popup-bottom`).
- `cooked-close` (`C-c C-k`) hangs up on the program, ends the session and
  closes the buffer; `cooked-close-grace` sets how long it waits.
- `cooked-annotate`: packages can attach clickable notes to stretches of
  output, marked in the fringe. `cooked-annotation-next` and
  `cooked-annotation-previous` step between them.
- Seams for other packages: `cooked-prompt-positions-functions` adds stops for
  `C-c C-p`/`C-c C-n`, `cooked-paste-string` pastes text at the program's
  input, and the buffer-local `cooked-file-open-function` decides how files
  named in the output are opened.
- Dropping files onto a cooked buffer types their shell-quoted paths at the
  input, as a terminal does (`cooked-dnd-insert-file-names`).
- `cooked-shell-line-editor`: set to `shell` to leave every command line with
  the shell's own line editor, so zsh plugins such as autosuggestions, syntax
  highlighting and fzf widgets work.
- `cooked-copy-unwrap`: copied text has a program's own hard wrapping and
  continuation indents removed, leaving tables, box drawing and code alone.
- Program variables in the mode line: a program can name things about itself,
  such as the model an agent is running, with iTerm2's `SetUserVar` escape
  (`OSC 1337`). The names in `cooked-mode-line-user-vars` are shown while the
  program that set them is in the foreground.
- `cooked-defer-resize-on-main-screen` (on by default): while a program owns
  the keyboard on the main screen, a shrink in height is held back so an inline
  renderer does not leave copies of its frame in the scrollback.
- `cooked-resize-settle-delay` (0.5 s): a new width is passed to the program
  only once it has held, so a split made and undone never reaches it.
- `cooked-mode-line-strip-title-symbols` and `cooked-mode-line-states` keep
  the mode line quiet.
- A failed redisplay names the functions the error came out of, and
  `cooked-show-last-failure` shows its backtrace (Emacs 30 and later).

### Changed

- A soft-wrapped line no longer has a continuation arrow in the fringe. A
  truncated row keeps its truncation arrow.
- Output floods are several times faster. Scrollback that `cooked-scrollback-lines`
  would trim the moment it arrived is dropped in the native core instead of being sent
  to Emacs, and the child is no longer held back for scrollback while a cap is set.
  The styling of a long batch of scrollback is applied when it is displayed rather
  than when it arrives. 100,000 coloured lines took 1.8 s of Emacs time; they now
  take under 0.2 s.
- Rust 1.100 or later is required.
- A first build of the native core in a fresh install deletes cargo's build tree
  once the library is installed; a checkout that already has one keeps it.
- `cooked-kill-buffer-on-exit` defaults to `on-success`: a clean exit closes the
  buffer, while a failure keeps its output on screen.
- The mode line shows the keyboard-state word only for `alt` and `secret`;
  set `cooked-mode-line-states` to `t` for all of them. Symbols a program puts
  in front of its title, such as a spinner, are no longer shown.
- Program names come from `argv[0]` rather than the kernel's process name.
- Writes to the child never block Emacs.
- Box-drawing runs are drawn as one image per run rather than one per cell,
  and fallback-font glyphs are fitted to their cell so rows keep their height.
- Opening the minibuffer no longer resizes the terminal.
- The shipped terminfo database advertises extended keys, bracketed paste,
  focus events and hyperlinks, is readable by macOS's system ncurses, and is
  rebuilt locally when it is not usable.
- A no-break space is drawn as a plain space rather than with Emacs'
  `nobreak-space` underline.
- `C-e` and `C-k` at a prompt stop at the end of the line being typed when the
  row goes on past it (a right-hand prompt, or what a program drew after its
  cursor). A second `C-e` goes on to the end of the row, as a second `C-a`
  goes to column 0. `C-k` at the end of the line no longer joins the screen
  row below it.

### Fixed

- Output arriving while a line was edited mid-way moved point to the end of the
  line; it stays where it was.
- Truecolor sequences swallowing the parameter after them.
- DECSC/DECRC not saving and restoring the pen.
- RIS leaving the alternate screen up.
- Mouse tracking modes not being mutually exclusive, and the mouse column on
  the blank tail of a row.
- Cursor placement after wide characters.
- Reverse video on default colours being invisible.
- OSC 7 clobbering match data.
- SIGPIPE killing batch Emacs on macOS.
- Shell integration on bash older than 4.4.
- zsh coming up without its history under macOS's system zshrc, and global
  aliases breaking the integration scripts.
- `M->` and `C-l` at a multi-row prompt.
- A history widget such as fzf's `C-r` leaving the recalled command on screen
  as read-only prompt text.
- The window jumping to recentre the prompt when another package changed
  `scroll-margin` or `scroll-conservatively` in cooked buffers.
- Rows at the bottom of the window being cut off under `line-spacing`, and
  jitter when scrolling past the bottom while following output.
- Docks and following windows losing their bottom row after a window popped
  up beside them and went away again.
- Clicks and drags doing nothing while a program owns the keyboard, and a
  selection vanishing whenever a program redrew an unrelated row.
- The user's own header line being blanked when sticky scroll is off.
- Emacs aborting on macOS when a file was dragged over a cooked buffer.
- Scrolling other buffers hitching beside a terminal window scrolled up into a
  long history.
- The checkout not being found, and so the native module, terminfo and shell
  integration not being found, when cooked is installed by straight or elpaca and
  loaded compiled.
- A hosted session started from a buffer with an environment of its own, as
  envrc gives one in a direnv project, getting Emacs's global environment
  instead: without the project's variables or the terminal's own settings.
- The keymap not being refreshed, and an error logged, when a cooked buffer was
  selected in another frame: the selection hook took the window it is handed
  for a frame.
- A drain failing with "Invalid search bound" while fitting wide glyphs to their
  cells, when point was left on a row above the one just written.
- A screenful of output kept twice in the scrollback when a row of block
  glyphs, such as a program's logo, arrived while another buffer's window was
  selected.

### Security

- Control characters are stripped from pasted text.
- OSC 8 links are restricted to `http`, `https`, `mailto` and local files.
- OSC 52 clipboard writes are off by default.
- Completion announcements require a numeric nonce, and completed file names
  are quoted.
- Image placements, sixel painting and combining marks are bounded, so a few
  kilobytes of output cannot exhaust memory.
- Text a program sends for display, in notifications and in the mode line, has
  control and bidirectional-override characters removed.
- Only an `OSC 1337` inline image may exceed the OSC payload limit.

[Unreleased]: https://github.com/dangom/cooked/compare/dd8e9fc...HEAD
