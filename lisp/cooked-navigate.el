;;; cooked-navigate.el --- Emacs navigation over a program that owns the keyboard -*- lexical-binding: t; -*-

;;; Commentary:

;; A program that reads every key raw but prints onto the main screen -- a REPL,
;; an agent's chat with an inline renderer -- leaves its
;; output in the buffer as ordinary text.  Without this file the only way to
;; read back through that text with Emacs' own commands is to step out by hand
;; (C-c C-v), because every key goes to the program.
;;
;; With it, where point is decides who a key is for:
;;
;; - Point in the program's input -- the row its cursor is on: every key is the
;;   program's, exactly as in a terminal, except the few in
;;   `cooked-navigation-keys' (by default `M-v' and `M-<'), which are the
;;   way out into the output.  The mouse is the other way out: a click, or the
;;   wheel.
;;
;; - Point anywhere else: the buffer is an ordinary read-only Emacs buffer.  Every
;;   motion, search, mark and copy command works on the output, and the output
;;   keeps arriving underneath without moving the view.  Typing a character goes
;;   back to the input and types it there, the way comint and eshell send you
;;   back to the prompt; RET just goes back.  Moving point onto the input row --
;;   `C-n' off the end of the output -- goes back too.
;;
;; Scrolling the window up away from the input counts as leaving it, even when
;; point is still on screen, so that live output cannot scroll a window the user
;; is reading back to the bottom.  Scrolling down until the input is in view
;; again counts as coming back.
;;
;; Nothing here knows what the program is.  Whether it applies is decided from
;; the terminal's own state, the same for any program: the main screen rather
;; than the alternate one, a child that owns the keyboard, and no request for
;; mouse reports -- a program that asks for the mouse scrolls itself.  "The
;; input" is the row the program's cursor is on.  Nothing reads what the program
;; draws.  When any of that stops holding -- the program switches to the
;; alternate screen, asks for the mouse, or exits -- navigation simply turns off
;; and every key is the program's again.
;;
;; This is the `still' input mode the rest of cooked already has, decided by
;; point instead of by a command: see `cooked-input-mode-functions',
;; `cooked-peek-map' and `cooked--wandered'.

;;; Code:

(require 'seq)
(require 'cooked)
(require 'cooked-keys)
(require 'cooked-mouse)

(declare-function cooked--refresh-keymap "cooked-mode" (&optional quiet))
(declare-function cooked--policy "cooked" ())
(declare-function cooked-previous-input "cooked-mode" (&optional n))
(declare-function cooked-next-input "cooked-mode" (&optional n))

(defcustom cooked-navigable-programs t
  "Which programs' output is read with ordinary Emacs commands while they run.

t, the default, is every program that owns the keyboard on the main screen
and has not asked for the mouse; see the commentary of cooked-navigate.el.  A
shell editing its own marked prompt is never included: Emacs owns that line
already.

A list of regexps narrows that to the programs one of them matches, by name
\(see `cooked--foreground-program') or by whole command line, so that a
program run by an interpreter -- \"node .../cli.js\" -- can be named by
its script.  nil turns navigation off."
  :type '(choice (const :tag "Every program on the main screen" t)
                 (const :tag "None" nil)
                 (repeat (regexp :tag "Program name or command line matching")))
  :group 'cooked)

(defcustom cooked-navigation-keys
  '(("M-v" . scroll-down-command)
    ("M-<" . beginning-of-buffer)
    ("C-p" . previous-line)
    ("C-n" . next-line)
    ("M-p" . cooked-previous-input)
    ("M-n" . cooked-next-input))
  "Keys that keep their Emacs meaning while point is in a program's input.

An alist of (KEY . COMMAND), KEY as `kbd' spells it.  Everywhere but the
program's input every key is Emacs' already; these are the way out of it.

The default makes a program's input behave like a shell prompt in cooked or
comint: \\`C-p' and \\`C-n' move by line, so \\`C-p' steps up into the
output; \\`M-p' and \\`M-n' are the input history, sent to the program as
the Up and Down keys it would have received for them in a terminal.  \\`M-v'
and \\`M-<' are the other ways out.

Every entry takes a key away from the program: a readline-based program loses
\\`M-<' (beginning of history), and a program with its own \\`M-p' (an agent's
model picker, say) loses that.  \\[cooked-send-literal-key] followed by the
key still sends it."
  :type '(alist :key-type (string :tag "Key") :value-type (function :tag "Command"))
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'cooked-navigate--rebuild-input-map)
           (cooked-navigate--rebuild-input-map)))
  :group 'cooked)

(defvar-local cooked-navigate--applies nil
  "Whether this buffer's child is one whose output is navigated by point.
Decided on each `cooked--refresh-keymap', which is when what the child is
running can change; asking on every command would be a syscall per key.")

(defvar-local cooked-navigate--reading nil
  "Whether the user has left the program's input to read its output.

Set and cleared only by the user's own commands -- see
`cooked-navigate--post-command' -- and never worked out from where point
happens to be.  Output moves the program's cursor between commands, and a
point that has not caught up with it yet has not gone anywhere.")

(defvar-local cooked-navigate--start nil
  "The selected window's start before the current command, if it shows us.")

(defvar-local cooked-navigate--point nil
  "Point before the current command.")

(defvar-local cooked-navigate--input-active nil
  "Whether `cooked-navigate-input-map' is in force.")

(defvar-local cooked-navigate--reading-active nil
  "Whether `cooked-navigate-reading-map' is in force.")

(defvar cooked-navigate-input-map (make-sparse-keymap)
  "Keys that are Emacs' while point is in a navigable program's input.
Built from `cooked-navigation-keys'.")

(defvar cooked-navigate-reading-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cooked-navigate-return)
    (define-key map (kbd "<return>") #'cooked-navigate-return)
    (define-key map (kbd "M-p") #'cooked-navigate-previous-input)
    (define-key map (kbd "M-n") #'cooked-navigate-next-input)
    map)
  "Keys for reading a navigable program's output, over `cooked-peek-map'.

RET goes back to the input without sending anything: a Return typed while
reading is far more likely to mean \"take me back\" than \"submit whatever is in
the prompt\", and the second is one more RET away.")

(defun cooked-navigate--rebuild-input-map ()
  "Rebuild `cooked-navigate-input-map' from `cooked-navigation-keys'."
  (setcdr cooked-navigate-input-map nil)
  (pcase-dolist (`(,key . ,command) cooked-navigation-keys)
    (define-key cooked-navigate-input-map (kbd key) command)))

(cooked-navigate--rebuild-input-map)

(defvar cooked-navigate--map-alist
  `((cooked-navigate--input-active . ,cooked-navigate-input-map)
    (cooked-navigate--reading-active . ,cooked-navigate-reading-map))
  "The `emulation-mode-map-alists' entry activating the navigation keymaps.")

(add-to-list 'emulation-mode-map-alists 'cooked-navigate--map-alist)

;;;; Where point is

(defun cooked-navigate--program-p ()
  "Whether `cooked-navigable-programs' includes the foreground program."
  (pcase cooked-navigable-programs
    ('t t)
    ('nil nil)
    (patterns
     (let ((name (cooked--foreground-program))
           (line (cooked--foreground-command-line)))
       (seq-some (lambda (re)
                   (or (and name (string-match-p re name))
                       (and line (string-match-p re line))))
                 patterns)))))

(defun cooked-navigate--eligible-p ()
  "Whether this buffer is in a terminal state navigation applies to.

Terminal state only: a live child that owns the keyboard, on the main screen,
that has not asked for mouse reports."
  (and cooked--session
       (not cooked--alt)
       (memq (cooked--policy) '(raw command))
       (not (cooked-mouse-state-enabled cooked--mouse-state))
       (cooked-navigate--program-p)))

(defun cooked-navigate--input-bounds ()
  "The start and end of the row the child's cursor is on, as a cons."
  (save-excursion
    (goto-char (cooked--cursor-position))
    (cons (line-beginning-position) (line-end-position))))

(defun cooked-navigate--at-input-p (&optional pos)
  "Whether POS, default point, is in the child's input."
  (let ((pos (or pos (point)))
        (bounds (cooked-navigate--input-bounds)))
    (<= (car bounds) pos (cdr bounds))))

;;;; The mode, and the maps

(defun cooked-navigate--input-mode ()
  "`still' while a navigable program's output is being read, else nil.
On `cooked-input-mode-functions'."
  (setq cooked-navigate--applies (cooked-navigate--eligible-p))
  ;; A deliberate peek is `frozen', and asked for: it is not ours to soften.
  (and cooked-navigate--applies
       (not cooked--peek-explicit)
       cooked-navigate--reading
       'still))

(add-hook 'cooked-input-mode-functions #'cooked-navigate--input-mode 50)

(defun cooked-navigate--update-maps ()
  "Switch the navigation keymaps on or off for the state just computed.
Called at the end of `cooked--refresh-keymap'."
  (let ((on (and cooked-navigate--applies cooked--session (not cooked--alt))))
    (unless on (setq cooked-navigate--reading nil))
    (setq cooked-navigate--reading-active
          (and on (eq cooked--input-mode 'still) (not cooked--peek-explicit))
          cooked-navigate--input-active
          (and on (null cooked--input-mode)))))

;;;; Following point

(defun cooked-navigate--pre-command ()
  "Remember point and the window's start, for `cooked-navigate--post-command'."
  (when cooked-navigate--applies
    (setq cooked-navigate--point (point)
          cooked-navigate--start
          (and (eq (window-buffer (selected-window)) (current-buffer))
               (window-start (selected-window))))))

(defun cooked-navigate--post-command ()
  "Decide whether the command just run left the input or came back to it."
  (when (and cooked-navigate--applies cooked--session (not cooked--alt)
             (not cooked--peek-explicit))
    (cooked--protect-hook
      (let* ((window (selected-window))
             (before cooked-navigate--start)
             (after (and (eq (window-buffer window) (current-buffer))
                         (window-start window)))
             (moved (not (eql (point) cooked-navigate--point)))
             (cursor (cooked--cursor-position)))
        (if cooked-navigate--reading
            (cond
             ;; Scrolled toward the end until the input is in view again.
             ((and before after (> after before)
                   (pos-visible-in-window-p cursor window)
                   (pos-visible-in-window-p (point-max) window))
              (setq cooked-navigate--reading nil)
              (goto-char cursor))
             ;; Moved onto the input row: back to the program, at its cursor
             ;; rather than wherever on the row the motion landed.
             ((and moved (cooked-navigate--at-input-p))
              (setq cooked-navigate--reading nil)
              (goto-char cursor)))
          (when (or
                 ;; Scrolled up off the bottom, even with point still in the
                 ;; input -- or live output would scroll the window straight back.
                 ;; Not a recentre, which is about where point sits in the
                 ;; window rather than about looking elsewhere.
                 (and before after (< after before)
                      (not (memq this-command '(recenter recenter-top-bottom))))
                 (and moved (not (cooked-navigate--at-input-p))))
            (setq cooked-navigate--reading t)))
        (unless (eq cooked-navigate--reading cooked-navigate--reading-active)
          (cooked--refresh-keymap t)
          (setq cooked--point (point)))))))

;;;; Commands

(defun cooked-navigate-return ()
  "Go back to the program's input, sending nothing."
  (interactive)
  (setq cooked-navigate--reading nil)
  (when cooked--session
    (goto-char (cooked--cursor-position))
    (setq cooked--wandered nil)
    (cooked--refresh-keymap t)))

(defun cooked-navigate-previous-input (&optional n)
  "Go back to the program's input and recall the Nth previous input there."
  (interactive "p")
  (cooked-navigate-return)
  (cooked-previous-input n))

(defun cooked-navigate-next-input (&optional n)
  "Go back to the program's input and recall the Nth next input there."
  (interactive "p")
  (cooked-navigate-return)
  (cooked-next-input n))

(provide 'cooked-navigate)
;;; cooked-navigate.el ends here
