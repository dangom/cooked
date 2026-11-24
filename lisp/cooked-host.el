;;; cooked-host.el --- Sessions that outlive Emacs -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional, and require-to-enable, on the model of `cooked-osc-eval.el': nothing
;; requires this file, and with it not loaded a session is what it has always
;; been -- a child of Emacs, ended with its buffer.
;;
;;   (require 'cooked-host)
;;
;; A *hosted* session is a child of a small process of its own, `cooked-host',
;; which keeps it running whether or not anything is looking.  This file is the
;; Emacs half of that: starting one, attaching a buffer to one, letting go.  The
;; program's own half -- holding the pty, keeping the recent output, handing both
;; to whoever attaches -- is src/host.rs, and the reasons for its shape are there.
;;
;;   cooked-host-shell     a shell that will still be there after Emacs is not
;;   cooked-host-attach    look at a session, by name
;;   cooked-host-detach    stop looking; the session runs on
;;   cooked-host-kill      end a session
;;   cooked-host-restore   attach to every session there is, and start again the
;;                         shells that a reboot cut off
;;
;; From Lisp, `cooked-host-exec' is `cooked-exec' for a session that is kept:
;; given a name, it attaches to the session of that name and starts it first if
;; there is none.
;;
;; Four things are different about a buffer attached to a host, and only four.
;;
;; Killing it ends nothing.  The buffer is a view, so `kill-buffer' asks no
;; question and exiting Emacs warns of no running process; ending the session
;; is `cooked-host-kill', by name.
;;
;; It begins with a replay.  What the child wrote before the buffer existed is
;; sent again, and the buffer is built from it exactly as it would have been
;; built the first time: scrollback, prompts, command records, links.  While that
;; is happening nothing the old output *asks for* is done -- see
;; `cooked--replaying'.
;;
;; It can lose its place and take it up again.  A host hangs up on a terminal
;; that has stopped reading -- Emacs busy for seconds while the child prints --
;; because the child must not wait for it.  The session is unharmed, so the
;; buffer attaches again by itself and is rebuilt from the replay; see
;; `cooked-host--reattach'.
;;
;; And it can be saved.  `desktop-save-mode' leaves ordinary cooked buffers out,
;; rightly: restoring one would mean starting a shell nobody asked for.  A hosted
;; buffer is restored by attaching to a session that is already running, which
;; starts nothing, so these are saved -- by name -- and come back.
;;
;; That is the whole of what this file does about layouts, and it is on purpose.
;; Which buffer is in which window, and which windows make up a workspace, is
;; already somebody's to remember: `desktop', or `persp-mode' and the workspaces
;; built on it.  Both restore a layout by restoring its buffers under the names
;; they had and then putting the windows back.  So a hosted buffer only has to
;; be one of the buffers they know how to bring back, and every layout it was
;; part of comes back with it; see "Saved sessions of Emacs" below.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cooked)
(require 'cooked-mode)

(declare-function cooked--attach "ext:cooked-core")
(declare-function cooked--resize "ext:cooked-core")
(declare-function cooked--signal "ext:cooked-core")
(defvar desktop-buffer-mode-handlers)
(defvar desktop-save-buffer)

(defgroup cooked-host nil
  "Terminal sessions that outlive Emacs."
  :group 'cooked)

(defcustom cooked-host-program nil
  "The `cooked-host' program, or nil to use the one built in the source tree.
That one is `target/release/cooked-host', beside the native core, and
`make host' builds it."
  :type '(choice (const :tag "The one in the source tree" nil) file))

(defcustom cooked-host-directory nil
  "Where hosted sessions keep their sockets and descriptions, or nil.
Nil leaves it to the program: `$COOKED_HOST_DIR', or failing that
`cooked/hosts' under `$XDG_STATE_HOME' or `~/.local/state'."
  :type '(choice (const :tag "The program's default" nil) directory))

(defvar cooked-host-attach-hook nil
  "Run in a buffer once it is attached to a hosted session.
With `cooked-host-name' set, and again each time the buffer attaches: after a
host hung up on it, or when it is brought back with a saved session of Emacs.
The program in the session has the same name in its environment, as
COOKED_HOST_SESSION, so this is where a package that keeps something per
session -- filed under that name by the program -- finds the buffer for it.")

(defvar-local cooked-host-name nil
  "The name of the hosted session this buffer is attached to, or nil.")

;;;; The program

;; What other packages build on (coterie starts its agents with the program
;; and the directory; a configuration asks after a session) has public names:
;; `cooked-host-executable', `cooked-host-sessions-directory' and
;; `cooked-host-session'.  The names they had are kept for a while.
(define-obsolete-function-alias 'cooked-host--program #'cooked-host-executable "1.0.0")
(define-obsolete-function-alias 'cooked-host--directory #'cooked-host-sessions-directory "1.0.0")
(define-obsolete-function-alias 'cooked-host--session #'cooked-host-session "1.0.0")

(defun cooked-host-executable ()
  "The `cooked-host' program, or an error saying how to get one."
  (let ((program (or cooked-host-program
                     (expand-file-name "target/release/cooked-host" (cooked--root)))))
    (unless (file-executable-p program)
      (user-error "cooked: no `cooked-host' at %s (build it with `make host')"
                  (abbreviate-file-name program)))
    program))

(defun cooked-host-sessions-directory ()
  "The directory hosted sessions live in; the same rule src/host.rs follows."
  (file-name-as-directory
   (expand-file-name
    (or cooked-host-directory
        (let ((dir (getenv "COOKED_HOST_DIR")))
          (and dir (not (string-empty-p dir)) dir))
        (expand-file-name
         "cooked/hosts"
         (let ((state (getenv "XDG_STATE_HOME")))
           (if (and state (not (string-empty-p state))) state "~/.local/state")))))))

(defun cooked-host--call (input &rest arguments)
  "Run the host program with ARGUMENTS and return what it printed.
INPUT, if a string, is its standard input.  A failure is a `user-error'
carrying what the program said about it.

With the caller's environment and `exec-path', read before the buffer
holding the output is made current: where they are buffer-local -- envrc
makes them so in a direnv project -- that buffer would see only the global
ones, and a session started from such a buffer was given Emacs's global
environment rather than the project's, without the terminal settings
`cooked-host-start' binds."
  (let ((environment process-environment)
        (path exec-path))
    (with-temp-buffer
      (let* ((exec-path path)
             (process-environment
              (cons (concat "COOKED_HOST_DIR=" (directory-file-name (cooked-host-sessions-directory)))
                    environment))
             (status (if input
                         (progn (insert input)
                                (apply #'call-process-region (point-min) (point-max)
                                       (cooked-host-executable) t t nil arguments))
                       (apply #'call-process (cooked-host-executable) nil t nil arguments))))
        (unless (eql status 0)
          (user-error "%s" (string-trim (buffer-string))))
        (buffer-string)))))

(defun cooked-host-sessions ()
  "Every hosted session, as a list of alists.

Each has `state' -- \"live\", \"exited\", or \"dead\" for one whose host is gone,
which is what a reboot leaves behind -- `attached', `socket', and under
`session' what was started: its `name', `cwd', `argv', `pid' and `note'."
  (mapcar (lambda (line) (json-parse-string line :object-type 'alist
                                            :array-type 'list :null-object nil
                                            :false-object nil))
          (split-string (cooked-host--call nil "list") "\n" t)))

(defun cooked-host-session (name)
  "The session called NAME, as `cooked-host-sessions' describes it, or nil."
  (cl-find name (cooked-host-sessions)
           :key (lambda (entry) (alist-get 'name (alist-get 'session entry)))
           :test #'equal))

(defun cooked-host--live-p (name)
  "Whether a host is still answering for the session NAME."
  (member (alist-get 'state (cooked-host-session name)) '("live" "exited")))

(defun cooked-host--safe-name (text)
  "TEXT as something that can name a session: see `valid_name' in src/host.rs."
  (let ((name (replace-regexp-in-string "[^A-Za-z0-9._-]+" "-" text)))
    (setq name (string-trim name "[.-]+" "-+"))
    (if (string-empty-p name) "session" (truncate-string-to-width name 48))))

(defun cooked-host--fresh-name (text)
  "A session name made from TEXT that no session has yet."
  (let* ((base (cooked-host--safe-name text))
         (taken (mapcar (lambda (entry) (alist-get 'name (alist-get 'session entry)))
                        (cooked-host-sessions)))
         (name base)
         (n 1))
    (while (member name taken)
      (setq name (format "%s-%d" base (cl-incf n))))
    name))

;;;; Starting and ending

(defun cooked-host-start (name argv &optional directory extra-env note)
  "Start ARGV as the hosted session NAME, and return NAME.

In DIRECTORY, or `default-directory'.  EXTRA-ENV is an alist put in front of
the environment every cooked child is given.  NOTE is a string kept with the
session's description and never read by the host: it is how whoever starts a
session recognises it later, and knows how to start it again.

Nothing is displayed and no buffer is made; see `cooked-host-attach'."
  (let* ((directory (expand-file-name
                     (or (cooked--local-name (or directory default-directory)) "~")))
         ;; The child's environment is the program's own, so it is given here
         ;; rather than passed: exactly what `cooked--start' gives a child of ours.
         (process-environment
          (mapcar (lambda (pair) (concat (car pair) "=" (cdr pair)))
                  (cooked--child-environment extra-env))))
    (apply #'cooked-host--call nil "new" name "--dir" directory
           (append (and note (list "--note" note))
                   (cons "--" argv)))
    name))

(defun cooked-host-kill (name)
  "End the hosted session NAME, or forget it if it is already over."
  (interactive (list (cooked-host--read "End session: ")))
  (cooked-host--call nil "kill" name)
  (when (called-interactively-p 'interactive)
    (message "cooked: ended %s" name)))

(defun cooked-host-send (name string)
  "Type STRING at the hosted session NAME, attached to or not."
  (cooked-host--call string "send" name))

;;;; Attaching

(defun cooked-host--buffer (name)
  "The buffer attached to the session NAME with a live connection, or nil."
  (cl-find-if (lambda (buffer)
                (and (equal (buffer-local-value 'cooked-host-name buffer) name)
                     (buffer-local-value 'cooked--session buffer)))
              (buffer-list)))

(defun cooked-host--redraw (truncated)
  "Ask a full-screen program to draw itself again after a TRUNCATED replay.

On `cooked-replay-end-functions'.  A replay that began part-way through shows
whatever the recent output left on the screen, which for a program that paints
in place is some of a picture.  It draws the rest when its window changes
size, and being told that it has is enough."
  (when (and truncated cooked--session)
    (ignore-errors (cooked--signal cooked--session 'SIGWINCH))))

(defun cooked-host--attach (name buffer)
  "Make BUFFER a terminal on the hosted session NAME, and return BUFFER."
  (let ((socket (expand-file-name (concat name ".sock") (cooked-host-sessions-directory))))
    (with-current-buffer buffer
      (when cooked--session
        (user-error "cooked: %s already has a session" (buffer-name)))
      (let ((directory default-directory))
        (unless (derived-mode-p 'cooked-mode)
          (cooked-mode))
        (setq default-directory directory))
      (setq cooked--replaying t)
      (add-hook 'cooked-replay-end-functions #'cooked-host--redraw nil t)
      (add-hook 'cooked-exit-functions #'cooked-host--lost nil t)
      (condition-case err
          (cooked--begin
           (lambda ()
             (let ((session (cooked--attach socket cooked--wake
                                            (round (* 1000 cooked-min-redisplay-interval))
                                            cooked-backlog-limit)))
               ;; The tty is whatever size the last terminal left it, and this
               ;; buffer is not: the replay has to be laid out for the window it
               ;; is about to be read in.
               (cooked--resize session cooked--rows cooked--cols)
               session)))
        (error
         (setq cooked--replaying nil)
         (cooked--stop-session)
         (signal (car err) (cdr err))))
      (setq cooked-host-name name)
      ;; A view, not the thing itself: killing it ends nothing, so there is
      ;; nothing to ask about.  The variable as well as the flag, because the flag
      ;; is set again from the variable whenever the keyboard changes hands.
      (setq-local cooked-confirm-kill nil)
      (setq-local desktop-save-buffer #'cooked-host--desktop-save)
      (cooked--refresh-keymap)
      (run-hooks 'cooked-host-attach-hook))
    buffer))

(defun cooked-host--read (prompt)
  "Read the name of a hosted session with PROMPT."
  (let* ((sessions (or (cooked-host-sessions)
                       (user-error "cooked: there are no hosted sessions")))
         (table
          (mapcar (lambda (entry)
                    (let ((session (alist-get 'session entry)))
                      (cons (alist-get 'name session) entry)))
                  sessions))
         (completion-extra-properties
          (list :annotation-function
                (lambda (name)
                  (let* ((entry (cdr (assoc name table)))
                         (session (alist-get 'session entry)))
                    (format "  %s  %s  %s"
                            (alist-get 'state entry)
                            (abbreviate-file-name (or (alist-get 'cwd session) ""))
                            (string-join (alist-get 'argv session) " ")))))))
    (completing-read prompt table nil t)))

(defvar cooked-host--reattached nil
  "Session names and when each was last attached to again, unasked.")

(defconst cooked-host--reattach-interval 10
  "Seconds within which a session is not attached to again a second time.
A host that hangs up on every attempt is saying something, and the buffer
should be left saying it rather than trying for ever.")

(defun cooked-host--lost (code)
  "Attach again if what ended with CODE was the connection and not the session.
On `cooked-exit-functions'."
  (when (and (eql code -2) cooked-host-name)
    (let* ((name cooked-host-name)
           (buffer (current-buffer))
           (last (alist-get name cooked-host--reattached nil nil #'equal)))
      (unless (and last (< (- (float-time) last) cooked-host--reattach-interval))
        (setf (alist-get name cooked-host--reattached nil nil #'equal) (float-time))
        ;; Not from inside the drain that is reporting the loss.
        (run-at-time 0 nil #'cooked-host--reattach buffer name)))))

(defun cooked-host--reattach (buffer name)
  "Make BUFFER a terminal on the session NAME again, from nothing.

The buffer is emptied and rebuilt by the replay, as it was the first time: what
it held cannot be told apart from what the replay is about to say, and a
transcript with a stretch of itself repeated is worse than one that is whole.
What made the buffer somebody's -- `cooked-host-saved-locals' -- is carried
across, and so are the windows, which never stopped showing it."
  (when (and (buffer-live-p buffer)
             (null (buffer-local-value 'cooked--session buffer))
             (cooked-host--live-p name))
    (with-current-buffer buffer
      (let ((record (cooked-host--record))
            (directory default-directory)
            (inhibit-read-only t))
        (delete-all-overlays)
        (erase-buffer)
        (cooked-mode)
        (setq default-directory directory)
        (cooked-host--attach name buffer)
        (pcase-dolist (`(,variable . ,value) (plist-get record :locals))
          (set (make-local-variable variable) value))
        (message "cooked: attached to %s again" name)))))

;;;###autoload
(defun cooked-host-attach (name &optional buffer)
  "Show the hosted session NAME in a buffer, attaching one if none is.
Returns the buffer.  From Lisp, BUFFER is the buffer to attach, or the name
of one to create, for a caller that has its own idea of what it is called;
it is not used if some buffer is attached to NAME already."
  (interactive (list (cooked-host--read "Attach to session: ")))
  (let ((buffer (or (cooked-host--buffer name)
                    (let* ((session (alist-get 'session (cooked-host-session name)))
                           (directory (file-name-as-directory
                                       (or (alist-get 'cwd session) default-directory)))
                           (buffer (if buffer
                                       (get-buffer-create buffer)
                                     (let ((default-directory directory))
                                       (generate-new-buffer (cooked--buffer-name))))))
                      (with-current-buffer buffer
                        (setq default-directory directory))
                      (cooked-host--attach name buffer)))))
    (when (called-interactively-p 'interactive)
      (cooked--display buffer cooked-display-action))
    buffer))

(defun cooked-host-detach ()
  "Stop looking at this buffer's hosted session, which runs on."
  (interactive)
  (unless cooked-host-name
    (user-error "cooked: this buffer is not attached to a hosted session"))
  (kill-buffer))

;;;###autoload
(defun cooked-host-exec (buffer name program &optional args note)
  "Show the hosted session NAME in BUFFER, starting PROGRAM with ARGS if need be.

`cooked-exec' for a session that is kept: the program runs under a host, and
goes on running when BUFFER is killed and when Emacs exits.  If a session
called NAME is already there, PROGRAM is not run and BUFFER attaches to what
is.  The session is started in BUFFER's `default-directory', with the
environment `process-environment' holds at the call; NOTE is kept with it, as
for `cooked-host-start'.

BUFFER is a buffer or the name of one to create, and is returned; it is not
displayed.  `get-buffer-process' answers for it while it is attached."
  (let ((buffer (get-buffer-create buffer)))
    (unless (cooked-host--live-p name)
      (when (cooked-host-session name)
        (cooked-host-kill name))
      (with-current-buffer buffer
        (cooked-host-start name (cons program args) default-directory nil note)))
    (cooked-host--attach name buffer)))

;;;###autoload
(defun cooked-host-shell (&optional directory)
  "Start a shell that outlives Emacs, in DIRECTORY, and show it.

The shell is given the same integration `\\[cooked]' gives one, so everything
about it is what it would be there.  What differs is where it lives: killing
its buffer, or Emacs, leaves it running, and `cooked-host-attach' finds it
again -- with its scrollback, its prompts and the record of its commands."
  (interactive)
  (let ((buffer (cooked-host--start-shell
                 (cooked-host--fresh-name
                  (file-name-nondirectory
                   (directory-file-name (or directory default-directory))))
                 (or directory default-directory))))
    (cooked--display buffer cooked-display-action)
    buffer))

;;;###autoload
(defun cooked-host-exec-shell (buffer name &optional directory)
  "Show the hosted shell NAME in BUFFER, starting one in DIRECTORY if need be.

`cooked-host-exec' for the user's shell, with everything `\\[cooked]' gives a
shell.  If a session called NAME is running, BUFFER attaches to it and nothing
is started; one that was cut off is started again.  BUFFER is a buffer or the
name of one to create, and is returned; it is not displayed."
  (let ((directory (or directory default-directory)))
    (if (cooked-host--live-p name)
        (cooked-host-attach name buffer)
      (when (cooked-host-session name)
        (cooked-host-kill name))
      (cooked-host--start-shell name directory (get-buffer-create buffer)))))

(defun cooked-host--start-shell (name directory &optional buffer)
  "Start a hosted shell called NAME in DIRECTORY; return a buffer attached to it.
BUFFER is the buffer to attach, or nil to make one."
  ;; The startup files a shell is pointed at have to last as long as the shell,
  ;; which is no longer as long as the buffer.  The host keeps a directory per
  ;; session for exactly that and removes it with the session, so the files are
  ;; generated there and are nobody's to clean up from here.
  (let ((scratch (expand-file-name (concat name ".d/") (cooked-host-sessions-directory))))
    (make-directory scratch t)
    (set-file-modes (cooked-host-sessions-directory) #o700)
    (pcase-let ((`(,argv ,env ,_)
                 (let ((temporary-file-directory scratch))
                   (cooked--shell-invocation cooked-shell))))
      (cooked-host-start name argv directory env "shell")))
  (let ((default-directory (file-name-as-directory (expand-file-name directory))))
    (let ((buffer (or buffer (generate-new-buffer (cooked--buffer-name))))
          (directory default-directory))
      (with-current-buffer buffer
        (setq default-directory directory))
      (cooked-host--attach name buffer))))

;;;; Coming back

(defvar cooked-host-revive-functions nil
  "Functions that may start again a session whose host is gone.

Each is called with the session's entry, as `cooked-host-sessions' gives it,
when something wants a buffer on a session that was cut off and is not a
shell.  One that knows the session -- by its name, by its `note' -- and has
started it again under the same name returns non-nil, and the session is
then attached to; the rest are not asked.  This is how whoever started a
session says what running it a second time should mean.")

(defun cooked-host--revive (entry)
  "Bring back the session ENTRY describes, and return a buffer on it, or nil.

One whose host still answers is attached to.  One whose host is gone -- the
machine was restarted, the host was killed -- has nothing to attach to, and
what can be done about that depends on what it was: a shell is started again
in the directory it was in, under the name it had, and anything else is left
for whoever started it, since only they know whether running it twice is
right; see `cooked-host-revive-functions'."
  (let* ((session (alist-get 'session entry))
         (name (alist-get 'name session))
         (directory (alist-get 'cwd session)))
    (cond
     ((cooked-host--buffer name))
     ((member (alist-get 'state entry) '("live" "exited"))
      (let ((default-directory (file-name-as-directory (or directory "~"))))
        (cooked-host--attach name (generate-new-buffer (cooked--buffer-name)))))
     ((and (equal (alist-get 'note session) "shell")
           directory (file-directory-p directory))
      (cooked-host-kill name)
      (cooked-host--start-shell name directory))
     ((and (run-hook-with-args-until-success 'cooked-host-revive-functions entry)
           (cooked-host--live-p name))
      (let ((default-directory (file-name-as-directory (or directory "~"))))
        (cooked-host--attach name (generate-new-buffer (cooked--buffer-name))))))))

;;;###autoload
(defun cooked-host-restore ()
  "Attach a buffer to every hosted session that has none.

Sessions still running are attached to as they are.  Shells cut off by a
restart are started again where they were; see `cooked-host--revive'.  Returns
the buffers, and displays none of them."
  (interactive)
  (let ((buffers (delq nil (mapcar #'cooked-host--revive (cooked-host-sessions)))))
    (when (called-interactively-p 'interactive)
      (message "cooked: %d hosted session%s" (length buffers)
               (if (= (length buffers) 1) "" "s")))
    buffers))

;;;; Saved sessions of Emacs

;; A hosted buffer is written down as the name of its session, the name it had
;; as a buffer, and whatever else of it somebody asked to have kept; and it is
;; brought back by attaching to that session, under that name.  One record, and
;; two things that know how to carry it: `desktop', and `persp-mode', which is
;; what Doom's workspaces and Spacemacs's layouts are.
;;
;; The buffer's name matters more than it looks.  Neither of them restores a
;; window by anything else: a saved window configuration says "the buffer
;; called this", so a buffer that comes back under its old name is back in every
;; window it was in, in every workspace it was in, and nothing here has to know
;; what a window is.
;;
;; Registered, where cooked-mode.el deliberately registers nothing, and for the
;; reason given there turned around: restoring an ordinary session spawns a
;; shell, in bulk and unasked, and restoring one of these spawns nothing.  A
;; buffer whose session is not hosted has no record and is left out, exactly as
;; before.

(defvar cooked-host-saved-locals nil
  "Buffer-local variables kept with a hosted buffer when Emacs's session is saved.

A list of symbols.  Each one that is bound locally in a hosted buffer is
written into its record, if its value can be read back, and set again in the
buffer the record is restored to.  For a package that keeps buffers of its own
on hosted sessions, to say what makes one of its buffers its own.")

(defun cooked-host--record ()
  "What to remember of this buffer: its session, its name, and its saved locals."
  (list :host cooked-host-name
        :buffer (buffer-name)
        :directory default-directory
        :locals (let (kept)
                  (dolist (variable cooked-host-saved-locals (nreverse kept))
                    (when (local-variable-p variable)
                      (let ((value (symbol-value variable)))
                        ;; Only what reads back as itself: a record is text.
                        (when (ignore-errors
                                (equal value (car (read-from-string
                                                   (prin1-to-string value)))))
                          (push (cons variable value) kept))))))))

(defun cooked-host--restore (record)
  "Bring back the hosted buffer RECORD describes; the buffer, or nil."
  (when-let* ((name (plist-get record :host))
              (entry (cooked-host-session name))
              (buffer (cooked-host--revive entry)))
    (with-current-buffer buffer
      (when-let* ((wanted (plist-get record :buffer))
                  ((not (equal (buffer-name) wanted))))
        (rename-buffer wanted t))
      (when-let* ((directory (plist-get record :directory))
                  ((file-directory-p directory)))
        (setq default-directory directory))
      (pcase-dolist (`(,variable . ,value) (plist-get record :locals))
        (when (memq variable cooked-host-saved-locals)
          (set (make-local-variable variable) value))))
    buffer))

;; desktop.el

(defun cooked-host--desktop-save (_desktop-directory)
  "What `desktop' is to remember of this buffer.  For `desktop-save-buffer'."
  (cooked-host--record))

(defun cooked-host--desktop-restore (_file-name buffer-name misc)
  "Bring back a hosted session buffer called BUFFER-NAME from MISC.
For `desktop-buffer-mode-handlers'."
  (cooked-host--restore (plist-put (copy-sequence misc) :buffer buffer-name)))

(with-eval-after-load 'desktop
  (setf (alist-get 'cooked-mode desktop-buffer-mode-handlers)
        #'cooked-host--desktop-restore))

;; persp-mode

(defvar persp-save-buffer-functions)
(defvar persp-load-buffer-functions)

(defun cooked-host--persp-save (buffer)
  "BUFFER as `persp-mode' is to write it down, if it is a hosted one.
For `persp-save-buffer-functions', where nil passes the buffer on."
  (when (buffer-local-value 'cooked-host-name buffer)
    (cons 'def-cooked-host (with-current-buffer buffer (cooked-host--record)))))

(defun cooked-host--persp-load (saved)
  "The hosted buffer SAVED describes, for `persp-load-buffer-functions'.
Nil for a record that is not one of these; `skip' for one whose session is
gone, so that nothing else tries to make a buffer of it."
  (when (eq (car-safe saved) 'def-cooked-host)
    (or (ignore-errors (cooked-host--restore (cdr saved)))
        'skip)))

(with-eval-after-load 'persp-mode
  ;; In front: the first of the stock functions drops every buffer that visits
  ;; no file before anything after it is asked.
  (add-to-list 'persp-save-buffer-functions #'cooked-host--persp-save)
  (add-to-list 'persp-load-buffer-functions #'cooked-host--persp-load))

(provide 'cooked-host)

;;; cooked-host.el ends here
