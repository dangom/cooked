;;; cooked-program-line.el --- Emacs edits the line a program is reading -*- lexical-binding: t; -*-

;;; Commentary:

;; A shell's prompt is Emacs' to edit: OSC 133 says where it is, and the line is
;; ordinary buffer text until RET hands it over.  A program that reads every key
;; raw -- a REPL, an agent's chat -- has a line too, but nothing says where it is
;; or whether the program is reading one at all: the same program asks a
;; question with a menu, and there `1' and `y' are answers, not text.  So its
;; line is the program's, key by key, and Emacs' motion, region and kill
;; commands cannot reach it.
;;
;; With `cooked-program-line-editor' set to `emacs', the program is asked, and
;; the asking is the program's own echo.  The first character typed into an
;; empty line goes to the program as always.  A program reading a line puts that
;; character on screen at its cursor and moves the cursor past it; a program
;; showing a menu does neither.  When the echo arrives, Emacs takes the line: the
;; program is sent a Backspace for every character it was given, and the
;; characters stay where they are on screen as the start of an Emacs input
;; region -- which from then on is a prompt like any other, edited with every
;; Emacs command, recalled with `M-p', completed with TAB.  When no echo
;; arrives, the key did whatever it does in the program, and the next key is
;; asked about in turn.  Nothing reads what the program draws beyond the
;; characters it was just sent, at the place it was sent them; mosh confirms
;; its predicted echo the same way.
;;
;; RET hands the line back whole, as a bracketed paste, and sends Enter only
;; once the program has visibly taken the paste -- its cursor moved.  A program
;; that has meanwhile put a question up is not answered by a Return meant for a
;; message: the paste lands nowhere, no Enter follows, and the text goes to the
;; kill ring.  Keys typed while that is decided are held, and sent once the
;; program has drawn the empty line the Enter leaves -- so they start the next
;; line, which Emacs can take in turn, rather than being sent ahead of the Enter
;; and submitted as the end of this one.
;;
;; A few things stay the program's:
;;
;; - The characters in `cooked-program-line-delegate-characters' typed into an
;;   empty line -- by default `/', `@' and `!', which open an agent's command
;;   menu, its file picker and its shell mode.  The line is then the program's
;;   until a key that ends a line goes to it.
;; - The keys in `cooked-program-line-pass-keys', sent to the program while
;;   Emacs keeps the line: Escape to interrupt, Shift-Tab to change mode.  Any
;;   other key the program wants goes by `C-c C-q' (`cooked-send-literal-key').
;; - Everything at an empty line, where there is no line for Emacs to own.
;;
;; Emacs gives the line up when it is emptied, when it is submitted, and when
;; the program stops being one that navigation applies to -- it takes the
;; alternate screen, asks for the mouse or exits.  In the last case what was
;; typed goes to the kill ring rather than nowhere.
;;
;; A program can also stop reading its line without any of that: an agent puts
;; a question up where its prompt was, while a line for it is half typed.  The
;; place a line was taken at -- the cursor's column, and what the program had
;; drawn before it on that row -- is remembered as where the program's empty
;; line is.  When the cursor is found somewhere else and stays there, the line
;; is set aside: taken off the screen and kept, and every key is the program's
;; again, so the question can be answered.  When the cursor is back at that
;; place, the line is too.
;;
;; The state is one of these at a time, and each function below says which it
;; moves between:
;;
;;   idle     The program has every key.  Its line is believed empty.
;;   probing  Characters were typed into that empty line, and the echo is
;;            awaited (`cooked-program-line--probe').
;;   held     The program has every key, and a line of its own that Emacs did
;;            not see typed: a delegated character, a history recall, a paste
;;            (`cooked-program-line--held').  No character is asked about, since
;;            one echoed into the middle of that line is not a line to take.
;;   owned    Emacs has the line (`cooked--program-line'); the program's is
;;            empty.
;;   aside    Emacs has a line and the program is not at its prompt
;;            (`cooked-program-line--aside').  Keys as in idle.
;;   handing  The line was handed back and its Enter is pending
;;            (`cooked-program-line--submit').

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'cooked)
(require 'cooked-keys)
(require 'cooked-navigate)

(declare-function cooked--refresh-keymap "cooked-mode" (&optional quiet))
(declare-function cooked--history-record "cooked-mode" (text))
(declare-function cooked-dock-select-input "cooked-dock" ())
(declare-function cooked--bracketed-paste-p "ext:cooked-core")
(declare-function cooked--send "ext:cooked-core")
(defvar cooked-drain-functions)

(defcustom cooked-program-line-editor 'program
  "Who edits the line a program that reads raw keys is typing into.

`program', the default: the program, as in any terminal.  Every key goes to
it; `cooked-navigation-keys' are the only ones Emacs keeps.

`emacs': Emacs takes the line once the program shows it is reading one -- by
echoing the first character typed into it -- and from then on the line is
edited as a shell prompt's is, and handed over whole on RET.  A program showing
a menu does not echo, so its keys stay its own.  See the commentary of
cooked-program-line.el.

Applies to the programs `cooked-navigable-programs' names, while navigation
applies to them."
  :type '(choice (const :tag "The program edits its line" program)
                 (const :tag "Emacs edits the line" emacs))
  :group 'cooked)

(defcustom cooked-program-line-delegate-characters '(?/ ?@ ?!)
  "Characters that, typed into an empty line, leave the line with the program.

For a program whose own completion starts from a character: an agent's command
menu on `/', its file picker on `@', its shell mode on `!'.  The line is then
the program's until a key that ends a line -- RET, Escape, `C-c', `C-u' -- goes
to it."
  :type '(repeat character)
  :group 'cooked)

(defcustom cooked-program-line-pass-keys '("<escape>" "<backtab>" "S-<tab>")
  "Keys that still reach the program while Emacs owns its line.

Each is a `kbd' string, sent to the program as it was pressed, with the line
left as it is.  The default keeps an agent's own Escape (interrupt) and
Shift-Tab (change mode).  Binding \\`<escape>' gives up Escape as a Meta prefix
in that line; \\`C-c C-q' sends any other key the same way."
  :type '(repeat string)
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'cooked-program-line--rebuild-pass-map)
           (cooked-program-line--rebuild-pass-map)))
  :group 'cooked)

(defcustom cooked-program-line-shells
  '("\\`\\(?:ba\\|z\\|fi\\|da\\|k\\|mk\\|tc\\|c\\|y\\|o\\)?sh\\'" "\\`nu\\'" "\\`xonsh\\'"
    "\\`ssh\\'" "\\`mosh\\(?:-client\\)?\\'" "\\`et\\'" "\\`telnet\\'")
  "Regexps naming shells, whose line Emacs never takes as a program's.

A shell edits its own prompt, and whether Emacs does instead is
`cooked-shell-line-editor's to say.  Without shell integration a shell at its
prompt looks like any program reading raw keys, so it is named here instead --
and so are the remote logins, `ssh' and the rest, whose foreground program is a
shell on another machine.  Matched against the foreground program's name, as
`cooked-navigable-programs' is."
  :type '(repeat regexp)
  :group 'cooked)

(defcustom cooked-program-line-echo-timeout 0.5
  "Seconds to wait for a program to echo a typed character.

No echo by then means the program was not reading a line: the character did
whatever it does in the program, and Emacs leaves it at that."
  :type 'number
  :group 'cooked)

(defcustom cooked-program-line-away-delay 0.2
  "Seconds a program's cursor may be off its line before the line is set aside.

A program redrawing its screen moves its cursor all over it, and a redraw
caught half-way must not be taken for a question: the line is only hidden for
that long, and still Emacs' to type into.  Past it the program is taken to be
showing something else where its line was -- a question, a menu -- and gets
the keyboard until its cursor is back."
  :type 'number
  :group 'cooked)

(defcustom cooked-program-line-accept-timeout 2
  "Seconds to wait for a program to take a line handed to it, before Enter.

No sign of it by then -- the program's cursor never moved -- and no Enter is
sent; the line goes to the kill ring instead."
  :type 'number
  :group 'cooked)

;;;; State

(cl-defstruct (cooked-program-line-probe
               (:constructor cooked-program-line--probe-make)
               (:copier nil))
  "Characters sent to a program while waiting to see whether it echoes them."
  (sent "" :documentation "Every character sent since the first, in order.")
  (col 0 :documentation "The program's cursor column before the first was sent.")
  (deadline 0 :documentation "When to stop waiting, as a `float-time'."))

(defvar-local cooked-program-line--probe nil
  "The `cooked-program-line-probe' awaiting the program's echo, or nil.")

(defvar-local cooked-program-line--held nil
  "Non-nil while the program has a line of its own that Emacs did not see typed.
Set by a character from `cooked-program-line-delegate-characters', by handing
the line back with `cooked-delegate-key', and by any key sent to the program
that can put text in its line -- a history recall, a completion, a paste.
Cleared by a key that ends a line, and when the program is seen back at its
empty line; see `cooked-program-line--settle'.")

(defvar-local cooked-program-line--submit nil
  "A line handed to the program and not yet done with, or nil.

A plist.  `:phase' is `paste' until the program's cursor moves, which is the
paste taken, and then `enter' until it moves again, which is the Enter taken.
`:text' is the line, `:cell' the cursor's cell when the phase began,
`:deadline' when to stop waiting, and `:queue' the keys typed meanwhile, newest
first -- held by `cooked-program-line-hold-key' and sent by
`cooked-program-line--flush'.")

(defvar-local cooked-program-line--timer nil
  "The timer that looks again when no drain may come to do it, or nil.
Drains check the deadlines as well, but a program that draws nothing would
otherwise keep a line, or the keys held for one, waiting forever.")

(defvar-local cooked-program-line--text nil
  "The line Emacs owns, as of the last command.
Kept so that a line the program walked away from can still be given back.")

(defvar-local cooked-program-line--anchor nil
  "Where the program's empty line is, as (COL . BEFORE), or nil if never seen.

COL is the cursor's column there and BEFORE what the program draws ahead of it
on that row -- its prompt.  Learned each time a line is taken, which is the one
moment the program has shown where it reads: nothing looks for a prompt, and
nothing knows what one looks like.  See `cooked-program-line--at-line-p'.")

(defvar-local cooked-program-line--aside nil
  "A line Emacs owns that is off the screen while the program is elsewhere.
The text, or nil.  See `cooked-program-line--set-aside'.")

(defvar-local cooked-program-line--away-since nil
  "When the program's cursor was first found off the line Emacs owns, or nil.
A `float-time'; see `cooked-program-line-away-delay'.")

(defvar-local cooked-program-line--sent-at 0
  "When a key last went to the program, as a `float-time'.")

(defvar-local cooked-program-line--sent-seen 0
  "`cooked--sent-count' as of the last command.")

(defconst cooked-program-line--settle-time 0.25
  "Seconds after a key before the screen is taken to show what the key did.
The cursor sitting at the program's empty line says the line is empty only once
the program has had the chance to act on what it was last sent.")

;;;; Where the program's line is

(defun cooked-program-line--place ()
  "Where the program's cursor is: its column, and what is before it on its row.
As (COL . BEFORE), to compare with `cooked-program-line--anchor'."
  (let ((inhibit-field-text-motion t)
        (col (cooked-cursor-col cooked--cursor)))
    (save-excursion
      (cooked--goto-screen-row (cooked-cursor-row cooked--cursor))
      (cons col (buffer-substring-no-properties
                 (point) (car (cooked--forward-cells col)))))))

(defun cooked-program-line--at-line-p ()
  "Whether the program's cursor is where its empty line was last seen to be.
Nil when no line was ever taken, and there is nowhere to compare with."
  (and cooked-program-line--anchor
       (equal (cooked-program-line--place) cooked-program-line--anchor)))

(defun cooked-program-line--asking-p ()
  "Whether the program is known to be somewhere other than at its empty line.

Showing a menu or a question, or holding a line of its own.  Known, not
guessed: nil until a line has been taken and its place learned, and nil while
Emacs owns the line.  On `cooked-navigate-yield-function', so the keys in
`cooked-navigation-yield-keys' go to a menu that wants them."
  (and (eq cooked-program-line-editor 'emacs)
       cooked-program-line--anchor
       (not cooked--program-line)
       (not (cooked-program-line--at-line-p))))

(defun cooked-program-line--settle ()
  "Stop holding the program's line once the program is seen back at an empty one.
Only once it has had time to act on the last key: until then the cursor is
where it was before the key, which says nothing."
  (when (and cooked-program-line--held
             (>= (- (float-time) cooked-program-line--sent-at)
                 cooked-program-line--settle-time)
             (cooked-program-line--at-line-p))
    (setq cooked-program-line--held nil)))

;;;; Asking the program

(defun cooked-program-line--eligible-p ()
  "Whether a character typed now should ask the program whether it echoes."
  (and (eq cooked-program-line-editor 'emacs)
       cooked--session
       cooked-navigate--applies
       (null cooked--input-mode)
       ;; A program the shell is running, or one with no shell around it.  Not a
       ;; shell at its own marked prompt, which is `prompt' -- that line is
       ;; `cooked-shell-line-editor's to give away, and a shell that keeps it
       ;; must not have it taken, let alone rubbed out with Backspaces.
       (memq (cooked--child-policy) '(raw command))
       (not (cooked-program-line--shell-p))
       (not cooked--program-line)
       (not cooked-program-line--held)
       (not cooked-program-line--submit)))

(defun cooked-program-line--shell-p ()
  "Whether the foreground program is one `cooked-program-line-shells' names."
  (when-let* ((name (cooked--foreground-program)))
    (seq-some (lambda (re) (string-match-p re name)) cooked-program-line-shells)))

(defun cooked-program-line--printable-p (event)
  "Whether EVENT is a character that types itself."
  (and (characterp event) (>= event ?\s) (/= event ?\d)))

(defun cooked-program-line--ends-line-p (event)
  "Whether EVENT, sent to the program, ends the line it is reading."
  (or (memq event '(return escape ?\r ?\n ?\e ?\C-c ?\C-u ?\C-d))
      (memq this-command '(cooked-interrupt cooked-send-eof))))

(defun cooked-program-line--inert-p (event)
  "Whether EVENT, sent to a program at an empty line, leaves the line empty.
Rubbing out and moving along a line that has nothing in it."
  (memq (event-basic-type event) '(backspace ?\d left right home end deletechar)))

(defconst cooked-program-line--typing-commands
  '(cooked-send-key cooked--peek-resume-and-send)
  "Commands that send the program the one key that invoked them, as typed.")

(defun cooked-program-line--observe (event)
  "Account for EVENT, which the command just run sent to the program.

Every command that sends the program anything comes through here, whichever it
was: what matters is what the program's line can hold afterwards."
  (cooked-program-line--settle)
  (setq cooked-program-line--sent-at (float-time))
  (cond
   ;; A line handed over is being waited on; what is sent meanwhile is that
   ;; wait's own, or a key the user sent past it on purpose.
   (cooked-program-line--submit nil)
   ((cooked-program-line--ends-line-p event)
    (setq cooked-program-line--probe nil
          cooked-program-line--held nil))
   ((not (and (cooked-program-line--printable-p event)
              (memq this-command cooked-program-line--typing-commands)))
    ;; Not a character typed: a key of the program's own, a paste, a recall.
    ;; Unless it plainly does nothing to an empty line, the line is the
    ;; program's from here -- and so is one with characters in it that were
    ;; never seen echoed.
    (unless (and (cooked-program-line--inert-p event)
                 (null cooked-program-line--probe))
      (setq cooked-program-line--held t))
    (setq cooked-program-line--probe nil))
   (cooked-program-line--held nil)
   (cooked-program-line--probe
    (let ((probe cooked-program-line--probe))
      (setf (cooked-program-line-probe-sent probe)
            (concat (cooked-program-line-probe-sent probe) (string event))
            (cooked-program-line-probe-deadline probe)
            (+ (float-time) cooked-program-line-echo-timeout))))
   ((not (cooked-program-line--eligible-p)) nil)
   ((memq event cooked-program-line-delegate-characters)
    (setq cooked-program-line--held t))
   (t
    ;; The cursor is still where the key found it: no drain runs inside a
    ;; command, so the echo cannot have arrived yet.
    (setq cooked-program-line--probe
          (cooked-program-line--probe-make
           :sent (string event)
           :col (cooked-cursor-col cooked--cursor)
           :deadline (+ (float-time) cooked-program-line-echo-timeout))))))

(defun cooked-program-line--echoed-p (probe)
  "Where PROBE's characters sit, as (START . END), if the program echoed them.

Echoed means the cursor moved right by exactly their width, and they are the
text just behind it on its row.  A menu that ignores the key does neither; one
that acts on it and redraws can land its cursor anywhere, but not with these
characters right behind it."
  (let* ((sent (cooked-program-line-probe-sent probe))
         (pos (cooked--cursor-position))
         (start (- pos (length sent))))
    (and (= (cooked-cursor-col cooked--cursor)
            (+ (cooked-program-line-probe-col probe) (string-width sent)))
         (>= start (save-excursion (goto-char pos) (pos-bol)))
         (string= (buffer-substring-no-properties start pos) sent)
         (cons start pos))))

(defun cooked-program-line--adopt (start end)
  "Make the text between START and END the line Emacs owns.
The one way into the owned state: the region, its protection, its edges and
the keymap are all put right here, whoever found the text."
  (setq cooked-program-line--probe nil
        cooked-program-line--held nil
        cooked-program-line--away-since nil
        cooked--program-line t
        cooked-program-line--text (buffer-substring-no-properties start end))
  (cooked--set-input-mark start)
  (set-marker comint-last-input-start start)
  (setq cooked--input-end (copy-marker end t))
  (cooked--protect-input)
  (cooked-program-line--bound)
  (cooked--refresh-keymap))

(defun cooked-program-line--take (start end text)
  "Take the program's line: TEXT, which it echoed between START and END.

The program is sent a Backspace for each character, so that it holds an empty
line again, and the echo already on screen becomes the input region -- nothing
moves.  The next drain lifts the region out and puts it back at the cursor the
Backspaces left, which is the same place.

Where the line began is where the program's empty line is, and is remembered
as that."
  (let ((follow (= (point) end)))
    (setq cooked-program-line--anchor
          (cons (cooked-program-line-probe-col cooked-program-line--probe)
                (let ((inhibit-field-text-motion t))
                  (buffer-substring-no-properties
                   (save-excursion
                     (cooked--goto-screen-row (cooked-cursor-row cooked--cursor))
                     (point))
                   start))))
    ;; A line set aside for a question, and the program reading another line
    ;; meanwhile: the one typed now is the one being typed.
    (cooked-program-line--rescue cooked-program-line--aside)
    (setq cooked-program-line--aside nil)
    ;; `cooked--send', not `cooked--send-to-child': these are not the user's
    ;; keys, and must not be counted as one.
    (cooked--send (cooked--require-session) (make-string (length text) ?\d))
    (cooked-program-line--adopt start end)
    (when follow (goto-char end))))

(defun cooked-program-line--rescue (text)
  "Put TEXT, a line that has nowhere left to go, on the kill ring.
Nothing when TEXT is nil or empty."
  (when (and text (not (string-empty-p text)))
    (kill-new text)
    (message "cooked: the program left its line; what you typed is on the kill ring")))

;;;; A line set aside

(defun cooked-program-line--watch ()
  "See whether the program is still at the line Emacs owns, after a drain.

At it: the line is shown, bounded as `cooked-program-line--bound' bounds it.
Off it: the line is hidden at once -- the drain has just put it back at the
cursor, wherever that now is, and it is not text for that place -- and set
aside if the cursor stays away for `cooked-program-line-away-delay'.  With no
place known, as after `cooked-delegate-key' was undone by hand, there is
nothing to compare and the line stays."
  (cond
   ((or (null cooked-program-line--anchor) (cooked-program-line--at-line-p))
    (setq cooked-program-line--away-since nil)
    (cooked-program-line--bound))
   ((null cooked-program-line--away-since)
    (setq cooked-program-line--away-since (float-time))
    (cooked-program-line--veil)
    (cooked-program-line--look-again cooked-program-line-away-delay))
   ((>= (- (float-time) cooked-program-line--away-since)
        cooked-program-line-away-delay)
    (cooked-program-line--set-aside))
   (t (cooked-program-line--veil))))

(defun cooked-program-line--set-aside ()
  "Take the line Emacs owns off the screen and keep it; the program has the keys.
See `cooked-program-line--restore' for the way back."
  (let ((text (cooked--pending-input))
        (inhibit-field-text-motion t))
    (cooked-program-line--unbound)
    (cooked--with-child-edit (cooked--take-pending-input))
    (setq cooked--program-line nil
          cooked-program-line--text nil
          cooked-program-line--away-since nil
          cooked-program-line--aside (and text (not (string-empty-p text)) text))
    (cooked--clear-input-region)
    (cooked--check-undo-anchor)
    (cooked--refresh-keymap)
    (when cooked-program-line--aside
      (message "cooked: your line is set aside while the program asks; it comes back with the prompt"))))

(defun cooked-program-line--restore ()
  "Put the line set aside back, the program being at its empty line again."
  (let ((text cooked-program-line--aside)
        (follow (= (point) (cooked--cursor-position)))
        (inhibit-field-text-motion t))
    (setq cooked-program-line--aside nil
          ;; Before the text goes in: `cooked--restore-pending-input' asks who
          ;; owns the line.
          cooked--program-line t)
    (cooked--with-child-edit (cooked--restore-pending-input text))
    (pcase-let ((`(,start . ,end) (cooked--input-region)))
      (cooked-program-line--adopt start end)
      (when follow (goto-char end)))
    (cooked--check-undo-anchor)))

;;;; The line's edges

(defvar-local cooked-program-line--tail nil
  "Overlay hiding what the program draws after its cursor, or nil.")

(defvar-local cooked-program-line--veiled nil
  "Overlay hiding the line Emacs owns while the program's cursor is off it.")

(defun cooked-program-line--bound ()
  "Hide what the program draws after the line Emacs owns.

The rest of the line's last row is what the program draws after its cursor for
an empty line: a cursor of its own, a placeholder, a suggestion.  None of it is
what is being typed, and its cursor after the user's text is a second cursor,
so it is hidden.  Re-applied after every drain, which rewrites the row."
  (when (overlayp cooked-program-line--veiled)
    (delete-overlay cooked-program-line--veiled)
    (setq cooked-program-line--veiled nil))
  (when-let* ((end (cdr (cooked--input-region))))
    (let ((eol (save-excursion (goto-char end) (pos-eol))))
      (if (overlayp cooked-program-line--tail)
          (move-overlay cooked-program-line--tail end eol)
        ;; Front-advance, so what is typed at the end of the line stays out.
        (setq cooked-program-line--tail (make-overlay end eol nil t nil))
        (overlay-put cooked-program-line--tail 'invisible t)))))

(defun cooked-program-line--veil ()
  "Hide the line Emacs owns, and show the row it is on as the program drew it.
For a drain that found the program's cursor off its line: the line has been put
back at the cursor, as every drain puts it, and there it would sit in the
middle of whatever the program is drawing."
  (when (overlayp cooked-program-line--tail)
    (delete-overlay cooked-program-line--tail)
    (setq cooked-program-line--tail nil))
  (when-let* ((region (cooked--input-region)))
    (if (overlayp cooked-program-line--veiled)
        (move-overlay cooked-program-line--veiled (car region) (cdr region))
      (setq cooked-program-line--veiled
            (make-overlay (car region) (cdr region) nil nil t))
      (overlay-put cooked-program-line--veiled 'invisible t))))

(defun cooked-program-line--unbound ()
  "Take away what this file put on the screen around the line."
  (cooked--unfence)
  (dolist (overlay (list cooked-program-line--tail cooked-program-line--veiled))
    (when (overlayp overlay) (delete-overlay overlay)))
  (setq cooked-program-line--tail nil
        cooked-program-line--veiled nil))

(defun cooked-program-line--keep-point ()
  "Put point in the line Emacs owns, if a command left it beside it.

The invariant, after every command: point is in the line, or off its rows
altogether and reading the output.  Never on one of its rows and outside it.
Before the line is the program's prompt and after it what the program draws
past its cursor; nothing can be typed or killed at either, so a point left
there is one every edit is refused at, with the line it was meant for a column
away.

After the line it cannot even be seen.  What `cooked-program-line--bound'
hides is still in the buffer, so the end of the line and the end of its row
are two positions drawn in one place, and a motion by screen column picks
either: \\`C-n' off the line and \\`C-p' back came to rest at the end of
the row, and \\`C-k' with the whole line before it said the text was
read-only.

The nearer end of the line is where point goes.  Not while the line is veiled,
when the program is drawing something else on that row and it is not the
line's.

Ahead of `cooked--track-wandering', which would take such a point for one
parked in the program's text, and pin it there."
  (cooked--protect-hook
    (when-let* (((and cooked--program-line
                      (not (overlayp cooked-program-line--veiled))))
                (region (cooked--input-region)))
      (pcase-let ((`(,start . ,end) region)
                  (inhibit-field-text-motion t))
        (cond ((<= start (point) end))
              ((and (< (point) start)
                    (>= (point) (save-excursion (goto-char start) (pos-bol))))
               (goto-char start))
              ((and (> (point) end)
                    (<= (point) (save-excursion (goto-char end) (pos-eol))))
               (goto-char end)))))))

;;;; Handing the line back

(defun cooked-program-line-submit ()
  "Hand the line Emacs owns to the program, and Enter once it has taken it.

A bracketed paste, so that a newline in it is text rather than an Enter.  The
Enter waits for the program's cursor to move, which is the program taking the
paste; see `cooked-program-line-accept-timeout'."
  (let ((text (or (cooked--pending-input) "")))
    (when (and (string-search "\n" text)
               (not (cooked--bracketed-paste-p cooked--session)))
      (user-error "This program does not take pastes; a newline would send the line early"))
    ;; Left in the buffer, as `cooked-send-input' leaves a shell's line: the
    ;; program's echo redraws it in place.
    (cooked-program-line--unbound)
    (cooked--clear-input-region)
    (cooked--history-record text)
    (setq cooked--program-line nil
          cooked-program-line--text nil
          cooked-program-line--away-since nil)
    (cooked-program-line--wait 'paste cooked-program-line-accept-timeout text)
    (cooked--refresh-keymap)
    (cooked--send-to-child (if (cooked--bracketed-paste-p cooked--session)
                               (cooked--bracketed-paste text)
                             text))))

(defun cooked-program-line--wait (phase seconds &optional text)
  "Wait up to SECONDS for the program's cursor to move, in PHASE.
TEXT is the line, when starting the wait; later phases keep the line and the
keys held so far."
  (let ((submit cooked-program-line--submit))
    (setq cooked-program-line--submit
          (list :phase phase
                :text (or text (plist-get submit :text))
                :cell (cooked--cursor-cell)
                :deadline (+ (float-time) seconds)
                :queue (plist-get submit :queue))))
  (cooked-program-line--look-again seconds))

(defun cooked-program-line--look-again (seconds)
  "Look at where things stand in SECONDS, whether or not the program draws.
One timer at a time: only one thing is ever being waited for."
  (cooked-program-line--cancel-timer)
  (let ((buffer (current-buffer)))
    (setq cooked-program-line--timer
          ;; A little after the deadline, so the check it runs finds it passed.
          (run-with-timer
           (+ seconds 0.01) nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq cooked-program-line--timer nil)
                 (cooked--protect-hook
                   (cooked-program-line--after-drain)))))))))

(defun cooked-program-line--cancel-timer ()
  "Cancel `cooked-program-line--timer', if it is running."
  (when (timerp cooked-program-line--timer)
    (cancel-timer cooked-program-line--timer))
  (setq cooked-program-line--timer nil))

(defun cooked-program-line--check-submit ()
  "Move a handed-over line on, once the program's cursor shows it moved on.

Taken the paste: send the Enter, and wait for the program to take that too.
Taken the Enter: send what was typed meanwhile.  Out of time waiting for the
paste: no Enter, the line to the kill ring, and what was typed sent, as it
would have been with no line handed over at all."
  (let ((submit cooked-program-line--submit))
    (cond
     ((not (equal (cooked--cursor-cell) (plist-get submit :cell)))
      (if (eq (plist-get submit :phase) 'paste)
          (progn
            (cooked--send-if-live "\r")
            ;; Short: a program that took the line answers an Enter at once,
            ;; and the keys held meanwhile are waiting on it.
            (cooked-program-line--wait 'enter cooked-program-line-echo-timeout))
        (cooked-program-line--flush)))
     ((>= (float-time) (plist-get submit :deadline))
      (when (eq (plist-get submit :phase) 'paste)
        (kill-new (plist-get submit :text))
        (message "cooked: the program did not take the line; it is on the kill ring"))
      (cooked-program-line--flush)))))

(defun cooked-program-line--flush ()
  "Stop waiting on a handed-over line, and send the keys held while waiting.
Each goes as it would have when typed, and is watched as it would have been:
the first character of a new line asks the program whether it echoes."
  (let ((queue (reverse (plist-get cooked-program-line--submit :queue))))
    (setq cooked-program-line--submit nil)
    (cooked-program-line--cancel-timer)
    (dolist (event queue)
      (when (cooked--live-session)
        (let ((last-command-event event)
              (this-command 'cooked-send-key))
          (cooked-send-key)
          (cooked-program-line--observe event))))
    ;; Accounted for here, each as it went: not the next command's to find.
    (setq cooked-program-line--sent-seen cooked--sent-count)))

(defun cooked-program-line-hold-key ()
  "Hold the key that invoked this command until the program has taken the line.
Bound in place of the commands that send a key to the program while a line
handed to it waits for its Enter; see `cooked-program-line--submit'."
  (interactive)
  (let ((event (if (eq this-original-command 'cooked-send-meta-key)
                   (event-apply-modifier last-command-event 'meta 27 "M-")
                 last-command-event)))
    (setq cooked-program-line--submit
          (plist-put cooked-program-line--submit :queue
                     (cons event (plist-get cooked-program-line--submit :queue))))))

(defun cooked-program-line--hand-over ()
  "Give the line Emacs owns back to the program, for it to keep.
Called by `cooked-delegate-key', which sends the text."
  (cooked-program-line--unbound)
  (setq cooked--program-line nil
        cooked-program-line--text nil
        cooked-program-line--away-since nil
        cooked-program-line--held t))

(defun cooked-program-line--release (&optional rescue)
  "Stop owning the program's line.
With RESCUE, what was typed in it goes to the kill ring, and the user is told."
  (when rescue
    (cooked-program-line--rescue cooked-program-line--text))
  (cooked-program-line--unbound)
  (setq cooked--program-line nil
        cooked-program-line--text nil
        cooked-program-line--away-since nil)
  (cooked--clear-input-region)
  (cooked--refresh-keymap))

;;;; Keys that stay the program's

(defun cooked-program-line-pass-key ()
  "Send the key that invoked this command to the program, keeping the line."
  (interactive)
  (let* ((assumed (cooked--assumed-key-protocol))
         (cooked--keys (or assumed cooked--keys))
         (cooked--keys-assumed (and assumed t)))
    (when-let* ((bytes (cooked--encode-event last-command-event)))
      (cooked--send-to-child bytes))))

(defvar cooked-program-line-pass-map (make-sparse-keymap)
  "Keys that reach the program while Emacs owns its line.
Built from `cooked-program-line-pass-keys'.")

(defun cooked-program-line--rebuild-pass-map ()
  "Rebuild `cooked-program-line-pass-map' from `cooked-program-line-pass-keys'."
  (setcdr cooked-program-line-pass-map nil)
  (dolist (key cooked-program-line-pass-keys)
    (define-key cooked-program-line-pass-map (kbd key)
                #'cooked-program-line-pass-key)))

(cooked-program-line--rebuild-pass-map)

(defvar cooked-program-line-hold-map
  (let ((map (make-sparse-keymap)))
    ;; ASCII is bound to `cooked-send-key' outright, other characters reach it
    ;; by remapping `self-insert-command', and a remap is followed only once.
    (dolist (command '(cooked-send-key cooked-send-meta-key self-insert-command))
      (define-key map (vector 'remap command) #'cooked-program-line-hold-key))
    map)
  "Keys held while a line handed to the program waits for its Enter.")

(defvar cooked-program-line--map-alist
  `((cooked--program-line . ,cooked-program-line-pass-map)
    (cooked-program-line--submit . ,cooked-program-line-hold-map))
  "The `emulation-mode-map-alists' entry activating the pass and hold keys.")

(add-to-list 'emulation-mode-map-alists 'cooked-program-line--map-alist)

;;;; Hooks

(defun cooked-program-line--pre-command ()
  "Send typing aimed at a docked transcript to the dock, where the line is."
  (cooked--protect-hook
    (when (and cooked--program-line
               (memq this-command cooked-snap-commands))
      (when-let* ((region (cooked--input-region))
                  ((not (<= (car region) (point) (cdr region))))
                  ((fboundp 'cooked-dock-select-input))
                  ((cooked-dock-select-input)))
        (goto-char (cdr region))))))

(defun cooked-program-line--post-command ()
  "Watch what the last command sent the program, or did to the line Emacs owns."
  (cooked--protect-hook
    (let ((sent (/= cooked--sent-count cooked-program-line--sent-seen)))
      (setq cooked-program-line--sent-seen cooked--sent-count)
      (cond
       (cooked--program-line
        (let ((text (cooked--pending-input)))
          (if (or (null text) (string-empty-p text))
              ;; Nothing left to own, so the next key is the program's again --
              ;; an answer to a menu, say.
              (cooked-program-line--release)
            (setq cooked-program-line--text text))))
       ;; Or signalled rather than sent a character: a tty with no interrupt
       ;; character still has the line ended for it.
       ((or sent (memq this-command '(cooked-interrupt cooked-send-eof)))
        (cooked-program-line--observe last-command-event))))))

(defun cooked-program-line--waiting-p ()
  "Whether anything here depends on what the program draws next."
  (or cooked--program-line cooked-program-line--probe cooked-program-line--held
      cooked-program-line--submit cooked-program-line--aside))

(defun cooked-program-line--after-drain ()
  "Act on what the program just drew: an echo, a line taken, a line left.
On `cooked-drain-functions', and nothing at all unless something is waiting --
which, with `cooked-program-line-editor' at its default, is always."
  (cond
   ((not (cooked-program-line--waiting-p)))
   ((not (cooked-navigate--eligible-p))
    ;; Not a program on the main screen reading keys any more: nothing it drew
    ;; was an answer, and a line it held is not one anything reads.  Keys typed
    ;; while a line waited go wherever the keyboard now goes.
    (setq cooked-program-line--probe nil
          cooked-program-line--held nil)
    (cooked-program-line--rescue cooked-program-line--aside)
    (setq cooked-program-line--aside nil)
    (when cooked-program-line--submit
      (cooked-program-line--flush))
    (when cooked--program-line
      (cooked-program-line--release 'rescue)))
   (t
    (when cooked-program-line--submit
      (cooked-program-line--check-submit))
    (let ((taken nil))
      (when-let* ((probe cooked-program-line--probe))
        (if-let* ((at (cooked-program-line--echoed-p probe)))
            (progn
              (cooked-program-line--take (car at) (cdr at)
                                         (cooked-program-line-probe-sent probe))
              (setq taken t))
          (when (> (float-time) (cooked-program-line-probe-deadline probe))
            (setq cooked-program-line--probe nil))))
      (cooked-program-line--settle)
      (cond
       ;; Just taken: the program's cursor is still after its echo, and is not
       ;; to be looked for at its empty line until the Backspaces have landed.
       (taken nil)
       (cooked--program-line
        (if (cooked--input-region)
            (cooked-program-line--watch)
          (cooked-program-line--release 'rescue)))
       ((and cooked-program-line--aside
             (not cooked-program-line--submit)
             (not cooked-program-line--probe)
             (cooked-program-line--at-line-p))
        (cooked-program-line--restore)))))))

(defun cooked-program-line--setup ()
  "Install the buffer-local hooks."
  (setq-local cooked-navigate-yield-function #'cooked-program-line--asking-p)
  (add-hook 'cooked-drain-functions #'cooked-program-line--after-drain nil t)
  (add-hook 'pre-command-hook #'cooked-program-line--pre-command -60 t)
  (add-hook 'post-command-hook #'cooked-program-line--keep-point -20 t)
  (add-hook 'post-command-hook #'cooked-program-line--post-command 40 t))

(add-hook 'cooked-mode-hook #'cooked-program-line--setup)

(provide 'cooked-program-line)
;;; cooked-program-line.el ends here
