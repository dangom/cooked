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
;; kill ring.
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

;;; Code:

(require 'cl-lib)
(require 'cooked)
(require 'cooked-keys)
(require 'cooked-navigate)

(declare-function cooked--refresh-keymap "cooked-mode" (&optional quiet))
(declare-function cooked--history-record "cooked-mode" (text))
(declare-function cooked-dock-select-input "cooked-dock" ())
(declare-function cooked--bracketed-paste-p "ext:cooked-core")
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

(defcustom cooked-program-line-echo-timeout 0.5
  "Seconds to wait for a program to echo a typed character.

No echo by then means the program was not reading a line: the character did
whatever it does in the program, and Emacs leaves it at that."
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
  "Non-nil while the program keeps its line until a key that ends one.
Set by a character from `cooked-program-line-delegate-characters', and by
handing the line back with `cooked-delegate-key'.")

(defvar-local cooked-program-line--submit nil
  "A line handed to the program and waiting for it to be taken, or nil.
A plist: `:text', `:cell' -- the cursor's cell when it was sent -- and
`:deadline'.")

(defvar-local cooked-program-line--text nil
  "The line Emacs owns, as of the last command.
Kept so that a line the program walked away from can still be given back.")

;;;; Asking the program

(defun cooked-program-line--eligible-p ()
  "Whether a character typed now should ask the program whether it echoes."
  (and (eq cooked-program-line-editor 'emacs)
       cooked--session
       cooked-navigate--applies
       (null cooked--input-mode)
       (not cooked--program-line)
       (not cooked-program-line--held)
       (not cooked-program-line--submit)))

(defun cooked-program-line--printable-p (event)
  "Whether EVENT is a character that types itself."
  (and (characterp event) (>= event ?\s) (/= event ?\d)))

(defun cooked-program-line--ends-line-p (event)
  "Whether EVENT, sent to the program, ends the line it is reading."
  (or (memq event '(return escape ?\r ?\n ?\e ?\C-c ?\C-u ?\C-d))
      (memq this-command '(cooked-interrupt cooked-send-eof))))

(defun cooked-program-line--observe (event)
  "Account for EVENT, which a command just sent to the program."
  (cond
   ((not (cooked-program-line--printable-p event))
    ;; Whatever follows another key is not a line being typed from empty.
    (setq cooked-program-line--probe nil)
    (when (cooked-program-line--ends-line-p event)
      (setq cooked-program-line--held nil)))
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
         (>= start (save-excursion (goto-char pos) (line-beginning-position)))
         (string= (buffer-substring-no-properties start pos) sent)
         (cons start pos))))

(defun cooked-program-line--take (start end text)
  "Take the program's line: TEXT, which it echoed between START and END.

The program is sent a Backspace for each character, so that it holds an empty
line again, and the echo already on screen becomes the input region -- nothing
moves.  The next drain lifts the region out and puts it back at the cursor the
Backspaces left, which is the same place."
  (let ((follow (= (point) end)))
    (setq cooked-program-line--probe nil
          cooked--program-line t
          cooked-program-line--text text)
    (cooked--send-to-child (make-string (length text) ?\d))
    (cooked--set-input-mark start)
    (set-marker comint-last-input-start start)
    (setq cooked--input-end (copy-marker end t))
    (let ((inhibit-read-only t))
      (cooked--protect start))
    (cooked--refresh-keymap)
    (when follow (goto-char end))))

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
    (cooked--clear-input-region)
    (cooked--history-record text)
    (setq cooked--program-line nil
          cooked-program-line--text nil
          cooked-program-line--submit
          (list :text text
                :cell (cooked--cursor-cell)
                :deadline (+ (float-time) cooked-program-line-accept-timeout)))
    (cooked--refresh-keymap)
    (cooked--send-to-child (if (cooked--bracketed-paste-p cooked--session)
                               (cooked--bracketed-paste text)
                             text))))

(defun cooked-program-line--check-submit ()
  "Send the Enter a handed-over line waits for, once the program took it."
  (let ((submit cooked-program-line--submit))
    (cond
     ((not (equal (cooked--cursor-cell) (plist-get submit :cell)))
      (setq cooked-program-line--submit nil)
      (cooked--send-if-live "\r"))
     ((> (float-time) (plist-get submit :deadline))
      (setq cooked-program-line--submit nil)
      (kill-new (plist-get submit :text))
      (message "cooked: the program did not take the line; it is on the kill ring")))))

(defun cooked-program-line--hand-over ()
  "Give the line Emacs owns back to the program, for it to keep.
Called by `cooked-delegate-key', which sends the text."
  (setq cooked--program-line nil
        cooked-program-line--text nil
        cooked-program-line--held t))

(defun cooked-program-line--release (&optional rescue)
  "Stop owning the program's line.
With RESCUE, what was typed in it goes to the kill ring, and the user is told."
  (when (and rescue cooked-program-line--text
             (not (string-empty-p cooked-program-line--text)))
    (kill-new cooked-program-line--text)
    (message "cooked: the program left its line; what you typed is on the kill ring"))
  (setq cooked--program-line nil
        cooked-program-line--text nil)
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

(defvar cooked-program-line--map-alist
  `((cooked--program-line . ,cooked-program-line-pass-map))
  "The `emulation-mode-map-alists' entry activating the pass keys.")

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
    (cond
     (cooked--program-line
      (let ((text (cooked--pending-input)))
        (if (or (null text) (string-empty-p text))
            ;; Nothing left to own, so the next key is the program's again --
            ;; an answer to a menu, say.
            (cooked-program-line--release)
          (setq cooked-program-line--text text))))
     ((memq this-command '(cooked-send-key cooked--peek-resume-and-send))
      (cooked-program-line--observe last-command-event)))))

(defun cooked-program-line--after-drain ()
  "Act on what the program just drew: an echo, or a line taken.
On `cooked-drain-functions', and nothing at all unless something is waiting --
which, with `cooked-program-line-editor' at its default, is always."
  (cond
   ((not (or cooked--program-line cooked-program-line--probe
             cooked-program-line--held cooked-program-line--submit)))
   ((not (cooked-navigate--eligible-p))
    ;; Not a program on the main screen reading keys any more: nothing it drew
    ;; was an answer, and a line it held is not one anything reads.
    (setq cooked-program-line--probe nil
          cooked-program-line--held nil
          cooked-program-line--submit nil)
    (when cooked--program-line
      (cooked-program-line--release 'rescue)))
   (t
    (when cooked-program-line--submit
      (cooked-program-line--check-submit))
    (when-let* ((probe cooked-program-line--probe))
      (if-let* ((at (cooked-program-line--echoed-p probe)))
          (cooked-program-line--take (car at) (cdr at)
                                     (cooked-program-line-probe-sent probe))
        (when (> (float-time) (cooked-program-line-probe-deadline probe))
          (setq cooked-program-line--probe nil))))
    (when (and cooked--program-line (not (cooked--input-region)))
      (cooked-program-line--release 'rescue)))))

(defun cooked-program-line--setup ()
  "Install the buffer-local hooks."
  (add-hook 'cooked-drain-functions #'cooked-program-line--after-drain nil t)
  (add-hook 'pre-command-hook #'cooked-program-line--pre-command -60 t)
  (add-hook 'post-command-hook #'cooked-program-line--post-command 40 t))

(add-hook 'cooked-mode-hook #'cooked-program-line--setup)

(provide 'cooked-program-line)
;;; cooked-program-line.el ends here
