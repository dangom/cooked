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
;;   `cooked-navigation-keys', which are the way out into the output.  The mouse
;;   is the other way out: a click, or the wheel.  A program that is asking
;;   something rather than reading its line gets some of those back; see
;;   `cooked-navigation-yield-keys'.
;;
;; - Point anywhere else: the buffer is an ordinary read-only Emacs buffer.  Every
;;   motion, search, mark and copy command works on the output, and the output
;;   keeps arriving underneath without moving the view.  Typing a character goes
;;   back to the input and types it there, the way comint and eshell send you
;;   back to the prompt; RET just goes back.  Moving point onto the input row --
;;   `C-n' off the end of the output -- goes back too.  Escape goes to the
;;   program from wherever point is, and point stays.
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
(defvar cooked-shell-line-editor)
(declare-function cooked-previous-input "cooked-mode" (&optional n))
(declare-function cooked-next-input "cooked-mode" (&optional n))
(declare-function cooked-dock-select-input "cooked-dock" ())
(declare-function cooked--window-held-p "cooked-render" (window))

(defcustom cooked-navigable-programs t
  "Which programs' output is read with ordinary Emacs commands while they run.

t, the default, is every program that owns the keyboard on the main screen
and has not asked for the mouse; see the commentary of cooked-navigate.el.  A
shell at its own marked prompt is included only when
`cooked-shell-line-editor' is `shell'; otherwise Emacs owns that line
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
    ("M-n" . cooked-next-input)
    ("C-y" . cooked-paste)
    ("C-SPC" . set-mark-command)
    ("C-@" . set-mark-command)
    ("C-s" . isearch-forward)
    ("C-r" . isearch-backward)
    ("C-M-s" . isearch-forward-regexp)
    ("C-M-r" . isearch-backward-regexp))
  "Keys that keep their Emacs meaning while point is in a program's input.

An alist of (KEY . COMMAND), KEY as `kbd' spells it.  Everywhere but the
program's input every key is Emacs' already; these are the way out of it.

The default makes a program's input behave like a shell prompt in cooked or
comint: \\`C-p' and \\`C-n' move by line, so \\`C-p' steps up into the
output; \\`M-p' and \\`M-n' are the input history, sent to the program as
the Up and Down keys it would have received for them in a terminal.  \\`C-y'
pastes Emacs' kill ring -- and so the clipboard -- as `yank' does everywhere
else.  \\`C-SPC' sets the mark, so a selection can be started from the input
and drawn up into the output; \\`C-@' is the same key as a terminal frame
reports it.  \\`C-s' and \\`C-r' are isearch over the output, which a search
from the input necessarily is.  \\`M-v' and \\`M-<' are the other ways out.

Every entry takes a key away from the program: a readline-based program loses
\\`M-<' (beginning of history) and \\`C-r' (history search), and a program with
its own \\`M-p' (an agent's model picker, say) or \\`C-s' loses that, as does
one with its own kill buffer on \\`C-y'.  \\[cooked-send-literal-key] followed by the key still sends it.

The keys in `cooked-navigation-yield-keys' go back to a program that is known
to be asking something rather than reading its line."
  :type '(alist :key-type (string :tag "Key") :value-type (function :tag "Command"))
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'cooked-navigate--rebuild-input-map)
           (cooked-navigate--rebuild-input-map)))
  :group 'cooked)

(defcustom cooked-navigation-yield-keys '("C-p" "C-n")
  "Keys of `cooked-navigation-keys' the program gets back while it is asking.

Each is a `kbd' string naming a key in that list.  A program showing a menu or
a question in place of its input moves through it with the same keys Emacs
moves by line with, and there the program must have them: \\`C-p' taken as a
motion leaves a menu unanswered.  So while `cooked-navigate-yield-function'
says the program is not at its line, these go to it like any other key --
except with a region active, where they extend it.

Nothing says so by default, and then this list does nothing; with
`cooked-program-line-editor' at `emacs' the program's line is watched, and it
is known when the program has left it."
  :type '(repeat string)
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'cooked-navigate--rebuild-input-map)
           (cooked-navigate--rebuild-input-map)))
  :group 'cooked)

(defvar-local cooked-navigate-yield-function nil
  "Function saying whether the program is somewhere other than at its line.
Called with no arguments in the session's buffer when a key in
`cooked-navigation-yield-keys' is looked up; non-nil gives the program the
key.  For a layer that can tell -- nothing here can.")

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

(defvar-local cooked-navigate--before nil
  "What the command now running found: (WINDOW POINT . SCROLL), or nil.

WINDOW is the selected window, POINT is point, and SCROLL is that window's
`cooked-navigate--scroll', or nil when it was not showing this buffer.

For the one command it was taken before, and no other.  It is taken on
`pre-command-hook' and used up on `post-command-hook', and a command that
began in another buffer and ended in this one -- `other-window', a click from
another window -- finds nil here, not what was left by whichever command last
ran in this buffer.  Compared with that, a screen that had since grown shorter
read as a window scrolled up to be read: the keys went to Emacs, and a
question the program had put up meanwhile could not be answered.")

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
    (define-key map (kbd "<escape>")
                '(menu-item "" cooked-navigate-send-key
                            :filter cooked-navigate--unless-modal))
    map)
  "Keys for reading a navigable program's output, over `cooked-peek-map'.

RET goes back to the input without sending anything: a Return typed while
reading is far more likely to mean \"take me back\" than \"submit whatever is in
the prompt\", and the second is one more RET away.

Escape is the program's wherever point is: it closes what the program has put
up, goes back a step, interrupts.  None of that is typing, so it is sent from
where point is and the output goes on being read; see
`cooked-navigate-send-key'.")

(defvar evil-state)

(defun cooked-navigate--unless-modal (binding)
  "BINDING, unless Escape is a key of the user's own editing here.
Under evil it leaves a state, in every state but the one that hands the
keyboard over, and this map can be looked in ahead of evil's."
  (unless (and (bound-and-true-p evil-local-mode)
               (not (eq evil-state 'emacs)))
    binding))

(defun cooked-navigate--yield-p ()
  "Whether the keys in `cooked-navigation-yield-keys' are the program's now.

Never while a region is being drawn: the mark was set on purpose and the key
that follows it extends the selection, whatever the program is showing.  That
matters most where the answer is a guess -- a program whose prompt is drawn
with nothing before the cursor reads as one that is asking until a line has
been typed to it, and its output could not be selected from the input at all."
  (and cooked-navigate-yield-function
       (not (region-active-p))
       (condition-case nil
           (funcall cooked-navigate-yield-function)
         (error nil))))

(defun cooked-navigate--rebuild-input-map ()
  "Rebuild `cooked-navigate-input-map' from `cooked-navigation-keys'.

A key in `cooked-navigation-yield-keys' is bound through a filter that answers
nothing while the program is asking: the lookup then goes on past this map, to
whatever the buffer forwards that key with."
  (setcdr cooked-navigate-input-map nil)
  (pcase-dolist (`(,key . ,command) cooked-navigation-keys)
    (define-key cooked-navigate-input-map (kbd key)
                (if (member (kbd key) (mapcar #'kbd cooked-navigation-yield-keys))
                    `(menu-item "" ,command
                                :filter ,(lambda (binding)
                                           (unless (cooked-navigate--yield-p)
                                             binding)))
                  command))))

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
       ;; The child's own state, not who owns the keyboard: a program whose line
       ;; Emacs is editing is still a program drawing on the main screen, and
       ;; its output is still read -- and docked -- the same way.
       (memq (cooked--child-policy)
             (if (eq cooked-shell-line-editor 'shell)
                 '(raw command prompt)
               '(raw command)))
       (not (cooked-mouse-state-enabled cooked--mouse-state))
       (cooked-navigate--program-p)))

(defun cooked-navigate--input-bounds ()
  "The start and end of the row the child's cursor is on, as a cons."
  (save-excursion
    (goto-char (cooked--cursor-position))
    (cons (line-beginning-position) (line-end-position))))

(defun cooked-navigate--at-input-p (&optional pos)
  "Whether POS, default point, is in the child's input.

The cursor's row, and all of a line Emacs owns for the program -- see
`cooked-program-line-editor' -- which is not on one row once it has a newline
in it."
  (let ((pos (or pos (point)))
        (bounds (cooked-navigate--input-bounds))
        (region (cooked--input-region)))
    (or (<= (car bounds) pos (cdr bounds))
        (and region (<= (car region) pos (cdr region))))))

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
  "Remember point and the window's scroll, for `cooked-navigate--post-command'."
  (setq cooked-navigate--before
        (and cooked-navigate--applies
             (let ((window (selected-window)))
               (cons window
                     (cons (point)
                           (and (eq (window-buffer window) (current-buffer))
                                (cooked-navigate--scroll window))))))))

(defun cooked-navigate--scroll (window)
  "WINDOW's scroll position: its start, and how far it is scrolled past it.
Both, because a pixel scroll -- `pixel-scroll-precision-mode', ultra-scroll --
moves the vertical scroll many times before it moves the start at all."
  (cons (window-start window) (window-vscroll window t)))

(defun cooked-navigate--later-p (a b)
  "Whether scroll position A shows later text than B."
  (or (> (car a) (car b))
      (and (= (car a) (car b)) (> (cdr a) (cdr b)))))

(defun cooked-navigate--placed-point-p (window)
  "Whether the command just run was a click of the mouse in WINDOW.
The one way a command that began in another buffer says where point should be."
  (and (mouse-event-p last-command-event)
       (eq (posn-window (event-start last-command-event)) window)))

(defun cooked-navigate--post-command ()
  "Decide whether the command just run left the input or came back to it.

By what the command itself did -- where it moved point, how it scrolled the
window -- and so only against `cooked-navigate--before' as that command found
it.  A command with nothing to compare with changed nothing, unless it was a
click, which puts point where the user pointed."
  (let ((found (prog1 cooked-navigate--before
                 (setq cooked-navigate--before nil))))
    (when (and cooked-navigate--applies cooked--session (not cooked--alt)
               (not cooked--peek-explicit))
      (cooked--protect-hook
        (let* ((window (selected-window))
               (same (eq (car found) window))
               (before (and same (cddr found)))
               (after (and before
                           (eq (window-buffer window) (current-buffer))
                           (cooked-navigate--scroll window)))
               (moved (if found
                          (not (eql (point) (cadr found)))
                        (cooked-navigate--placed-point-p window)))
               (cursor (cooked--cursor-position)))
          ;; Come in from another buffer, by a key: the window is the one to
          ;; ask.  One left scrolled away from the bottom -- by the wheel,
          ;; while it was not the selected one -- is being read; one showing
          ;; the bottom is not, unless point was parked in the output.
          (when (and (null found) (not moved)
                     (eq (window-buffer window) (current-buffer)))
            (setq cooked-navigate--reading
                  (and (or (cooked--window-held-p window)
                           (and cooked-navigate--reading
                                (not (cooked-navigate--at-input-p))))
                       t)))
          (if cooked-navigate--reading
              (cond
               ;; Scrolled toward the end until the input is in view again.
               ((and before after (cooked-navigate--later-p after before)
                     (pos-visible-in-window-p cursor window)
                     (pos-visible-in-window-p (point-max) window))
                (setq cooked-navigate--reading nil)
                (goto-char (cooked--point-after-input)))
               ;; Moved onto the input row: back to the program, at its cursor
               ;; rather than wherever on the row the motion landed.  A line Emacs
               ;; owns is edited where point is, so there point stays.
               ((and moved (cooked-navigate--at-input-p))
                (setq cooked-navigate--reading nil)
                (unless (cooked--input-region)
                  (goto-char cursor))))
            (when (or
                   ;; Scrolled up off the bottom, even with point still in the
                   ;; input -- or live output would scroll the window straight back.
                   ;; Not a recentre, which is about where point sits in the
                   ;; window rather than about looking elsewhere.
                   (and before after (cooked-navigate--later-p before after)
                        (not (memq this-command '(recenter recenter-top-bottom))))
                   (and moved (not (cooked-navigate--at-input-p))))
              (setq cooked-navigate--reading t)))
          (unless (eq cooked-navigate--reading cooked-navigate--reading-active)
            (cooked--refresh-keymap t)
            (setq cooked--point (point))))))))

;;;; Commands

(defun cooked-navigate-return ()
  "Go back to the program's input, sending nothing."
  (interactive)
  (setq cooked-navigate--reading nil)
  (when cooked--session
    (unless (and (fboundp 'cooked-dock-select-input)
                 (cooked-dock-select-input))
      (goto-char (cooked--cursor-position)))
    (setq cooked--wandered nil)
    (cooked--refresh-keymap t)))

(defun cooked-navigate-send-key ()
  "Send the key that invoked this command to the program, staying where point is.

For Escape while the output is being read.  A character typed there goes back
to the input, because it is text for the line; Escape is not, and a program
showing something with no line at all -- a login screen, a picker -- has no
input for point to be in while its one way out is this key.  Left unbound it
is Emacs' Meta prefix, and never reaches the program.

Not under evil outside emacs state, where Escape leaves a state.  And only
the Escape key of a graphical frame, which arrives as `escape'.  On a
terminal frame it is the byte every Meta chord begins with, and stays the
prefix; \\[cooked-send-literal-key] sends it from there."
  (interactive)
  (let* ((assumed (cooked--assumed-key-protocol))
         (cooked--keys (or assumed cooked--keys))
         (cooked--keys-assumed (and assumed t)))
    (when-let* ((bytes (cooked--encode-event last-command-event)))
      (cooked--send-to-child bytes))))

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
