;;; cooked-tests-host.el --- Tests for hosted sessions -*- lexical-binding: t; -*-

;;; Commentary:

;; Sessions kept by a `cooked-host' process: that they outlive the buffer looking
;; at them, that a buffer which comes later is shown what it missed, and that
;; being shown it does nothing but show it.
;;
;; Every test runs against a directory of its own, so no host started here is
;; visible to a session the person running the suite cares about, and none of
;; theirs to it.  The directory is short on purpose: a socket's address has to
;; fit in a hundred-odd bytes, and `temporary-file-directory' on macOS spends
;; most of them.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)
(require 'cooked-host)
(require 'desktop)

(defvar cooked-tests-host--count 0)

(defmacro cooked-tests-host--with-directory (&rest body)
  "Run BODY with hosted sessions kept in a directory of this test\\='s own.
Every session left in it is ended afterwards."
  (declare (indent 0))
  `(let* ((cooked-host-directory
           (format "/tmp/cooked-th-%d-%d/" (emacs-pid) (cl-incf cooked-tests-host--count)))
          (cooked-debug t))
     (skip-unless (file-executable-p
                   (or cooked-host-program
                       (expand-file-name "target/release/cooked-host" (cooked--root)))))
     (unwind-protect
         (progn ,@body)
       (dolist (entry (ignore-errors (cooked-host-sessions)))
         (ignore-errors
           (cooked-host-kill (alist-get 'name (alist-get 'session entry)))))
       (dolist (buffer (buffer-list))
         (when (buffer-local-value 'cooked-host-name buffer)
           (kill-buffer buffer)))
       (delete-directory cooked-host-directory t))))

(defun cooked-tests-host--alive-p (pid)
  "Whether the process PID exists."
  (eql 0 (ignore-errors (signal-process pid 0))))

(defconst cooked-tests-host--echo
  '("/bin/sh" "-c" "echo first; while read line; do echo \"got $line\"; done")
  "A child that says something, then answers each line it is given.")

(ert-deftest cooked-host-a-session-is-told-its-name-and-so-is-its-buffer ()
  "The child has its session's name in COOKED_HOST_SESSION, and
`cooked-host-attach-hook' runs in the buffer with the same name set."
  (cooked-tests-host--with-directory
    (let* ((seen nil)
           (cooked-host-attach-hook (list (lambda () (push cooked-host-name seen))))
           (process-environment (cons "COOKED_HOST_SESSION=outer" process-environment))
           (buffer (cooked-host-exec (generate-new-buffer "*cooked-host-test*") "named"
                                     "/bin/sh"
                                     '("-c" "echo \"I am $COOKED_HOST_SESSION.\"; read line"))))
      (with-current-buffer buffer
        (should (cooked-tests--settle
                 (lambda () (string-match-p "I am named\\." (cooked-tests--text)))))
        (should (equal seen '("named")))))))

(ert-deftest cooked-host-a-session-outlives-its-buffer-and-replays ()
  "The whole point, end to end: killing the buffer ends nothing, and a buffer
attached later is built from what the child wrote before it existed."
  (cooked-tests-host--with-directory
    (let ((buffer (cooked-host-exec (generate-new-buffer "*cooked-host-test*") "echo"
                                    (car cooked-tests-host--echo)
                                    (cdr cooked-tests-host--echo)))
          pid)
      (with-current-buffer buffer
        (should (cooked-tests--settle
                 (lambda () (string-match-p "first" (cooked-tests--text)))))
        (should (equal cooked-host-name "echo"))
        (setq pid (cooked--pid cooked--session))
        (cooked--send cooked--session "alpha\n")
        (should (cooked-tests--settle
                 (lambda () (string-match-p "got alpha" (cooked-tests--text)))))
        ;; A view, so nothing asks before it goes.
        (should-not (process-query-on-exit-flag (get-buffer-process buffer))))
      (kill-buffer buffer)
      (should (cooked-tests-host--alive-p pid))
      (should (equal (alist-get 'state (cooked-host--session "echo")) "live"))
      ;; Typed at it while nothing was attached.
      (cooked-host-send "echo" "beta\n")
      (with-current-buffer (cooked-host-attach "echo")
        (should (cooked-tests--settle
                 (lambda () (and (not cooked--replaying)
                                 (string-match-p "got beta" (cooked-tests--text))))))
        (should (string-match-p "first\\(.\\|\n\\)*got alpha" (cooked-tests--text)))
        (should (eql (cooked--pid cooked--session) pid))
        ;; Asking again for the same session is asking for the same buffer.
        (should (eq (cooked-host-attach "echo") (current-buffer)))
        (cooked-host-kill "echo")
        (should (cooked-tests--settle (lambda () (null cooked--session))))
        (should-not (cooked-tests-host--alive-p pid))))))

(ert-deftest cooked-host-a-replay-does-nothing-but-rebuild-the-buffer ()
  "What the child asked of its terminal before anyone was attached was asked
once.  Shown again to a buffer that comes later, it rings no bell and is given
no answer -- an answer now would arrive at the child as something typed."
  (cooked-tests-host--with-directory
    ;; A bell, and a request for the terminal to identify itself.
    (cooked-host-start "asks" '("/bin/sh" "-c" "printf '\\a\\033[c'; echo asked; cat"))
    (sleep-for 0.3)
    (let ((bells 0) (replies 0) ended)
      (cl-letf (((symbol-function 'ding) (lambda (&rest _) (cl-incf bells)))
                ((symbol-function 'cooked--send-if-live)
                 (lambda (&rest _) (cl-incf replies))))
        (with-current-buffer (cooked-host-attach "asks")
          (should cooked--replaying)
          (add-hook 'cooked-replay-end-functions (lambda (_) (setq ended t)) nil t)
          (should (cooked-tests--settle (lambda () ended)))
          (should-not cooked--replaying)
          (should (string-match-p "asked" (cooked-tests--text)))
          (should (zerop bells))
          (should (zerop replies)))))))

(ert-deftest cooked-host-a-hosted-buffer-comes-back-through-desktop ()
  "An ordinary session is left out of a desktop file because restoring it would
start a shell.  A hosted one is restored by attaching to what is already
running, so it is saved, by name, and comes back under the name it had."
  (cooked-tests-host--with-directory
    (let ((buffer (cooked-host-exec (generate-new-buffer "kept") "kept"
                                    (car cooked-tests-host--echo)
                                    (cdr cooked-tests-host--echo)))
          saved)
      (with-current-buffer buffer
        (should (functionp desktop-save-buffer))
        (setq saved (funcall desktop-save-buffer nil)))
      (kill-buffer buffer)
      (should (eq (alist-get 'cooked-mode desktop-buffer-mode-handlers)
                  #'cooked-host--desktop-restore))
      (let ((restored (cooked-host--desktop-restore nil "kept" saved)))
        (with-current-buffer restored
          (should (equal (buffer-name) "kept"))
          (should (equal cooked-host-name "kept"))
          (should (cooked-tests--settle
                   (lambda () (string-match-p "first" (cooked-tests--text))))))))))

(defvar cooked-tests-host--owner nil)

(ert-deftest cooked-host-a-saved-record-brings-back-name-and-locals ()
  "The record `persp-mode' and `desktop' both carry: the buffer comes back under
the name it had -- which is all either needs to put it back in its windows --
with the locals somebody asked to have kept, and only those."
  (cooked-tests-host--with-directory
    (let* ((cooked-host-saved-locals '(cooked-tests-host--owner))
           (buffer (cooked-host-attach
                    (cooked-host-start "rec" cooked-tests-host--echo)
                    "project: agent"))
           saved)
      (with-current-buffer buffer
        (should (equal (buffer-name) "project: agent"))
        (setq-local cooked-tests-host--owner '(:root "/tmp/" :role agent))
        (setq saved (cooked-host--persp-save buffer)))
      (should (eq (car saved) 'def-cooked-host))
      ;; A record is text by the time it is read again.
      (setq saved (car (read-from-string (prin1-to-string saved))))
      (should-not (cooked-host--persp-save (get-buffer-create "*scratch*")))
      (should-not (cooked-host--persp-load '(def-buffer "x" nil fundamental-mode)))
      (kill-buffer buffer)
      (let ((restored (cooked-host--persp-load saved)))
        (unwind-protect
            (with-current-buffer restored
              (should (equal (buffer-name) "project: agent"))
              (should (equal cooked-host-name "rec"))
              (should (equal cooked-tests-host--owner '(:root "/tmp/" :role agent)))
              (should (cooked-tests--settle
                       (lambda () (string-match-p "first" (cooked-tests--text))))))
          (kill-buffer restored)))
      ;; A session that is gone is not somebody else's to make a buffer of.
      (cooked-host-kill "rec")
      (should (cooked-tests--settle (lambda () (null (cooked-host--session "rec")))))
      (should (eq (cooked-host--persp-load saved) 'skip)))))

(ert-deftest cooked-host-a-cut-off-session-is-revived-by-whoever-knows-it ()
  "A session that is not a shell is not this file's to run twice; whoever
started it can say what that means, and is then attached to."
  (cooked-tests-host--with-directory
    (make-directory cooked-host-directory t)
    (with-temp-file (expand-file-name "agent.json" cooked-host-directory)
      (insert "{\"name\":\"agent\",\"pid\":1,\"cwd\":\"/tmp\",\"argv\":[\"x\"],\"created\":0,\"note\":\"mine\"}"))
    (should-not (cooked-host-restore))
    (let* ((asked nil)
           (cooked-host-revive-functions
            (list (lambda (entry)
                    (let ((session (alist-get 'session entry)))
                      (setq asked (alist-get 'note session))
                      (cooked-host-kill "agent")
                      (cooked-host-start "agent" cooked-tests-host--echo "/tmp/")))))
           (buffers (cooked-host-restore)))
      (should (equal asked "mine"))
      (should (= (length buffers) 1))
      (with-current-buffer (car buffers)
        (should (equal cooked-host-name "agent"))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "first" (cooked-tests--text)))))))))

(ert-deftest cooked-host-a-view-that-is-hung-up-on-attaches-again ()
  "A host drops a terminal that stops reading, and a second terminal attaching
takes the first one's place: either way the buffer is told its host is gone
while the session is fine.  It attaches again by itself, keeps what made it
somebody's, and holds the transcript once, not twice."
  (cooked-tests-host--with-directory
    (let* ((cooked-host-saved-locals '(cooked-tests-host--owner))
           (cooked-host--reattached nil)
           (buffer (cooked-host-attach
                    (cooked-host-start "hung" cooked-tests-host--echo) "hung")))
      (with-current-buffer buffer
        (setq-local cooked-tests-host--owner 'mine)
        (should (cooked-tests--settle
                 (lambda () (string-match-p "first" (cooked-tests--text)))))
        ;; Somebody else attaches, straight to the socket, and then lets go.
        (let ((thief (make-network-process
                      :name "thief" :family 'local :noquery t :coding 'binary
                      :service (expand-file-name "hung.sock" cooked-host-directory))))
          (process-send-string thief "attach\n")
          (should (cooked-tests--settle
                   (lambda ()
                     (and cooked--session
                          (not (string-match-p "detached" (cooked-tests--text)))
                          (progn (delete-process thief) t)
                          (eq (current-buffer) buffer)
                          (equal cooked-tests-host--owner 'mine)
                          (= 1 (how-many "^first$" (point-min) (point-max)))))
                   8)))
        (should (equal cooked-host-name "hung"))
        (cooked-host-send "hung" "again\n")
        (should (cooked-tests--settle
                 (lambda () (string-match-p "got again" (cooked-tests--text)))))))))

(ert-deftest cooked-host-a-replay-keeps-the-prompt-s-completion-announcement ()
  "The shell says at each prompt that it can be asked for completions.  A buffer
attached while it sits at that prompt has to hear it from the replay, or TAB
is Emacs's own until the next one.  Nothing else of OSC 51 gets through."
  (should (cooked--replay-osc-p 51 '("CH" "2" "12345" "1")))
  (should-not (cooked--replay-osc-p 51 '("Efind_file" "x")))
  (should-not (cooked--replay-osc-p 51 '("CR" "1" "" "" "0" "")))
  (should-not (cooked--replay-osc-p 52 '("c" "aGk=")))
  (should (cooked--replay-osc-p 7 '("file:///tmp")))
  (cooked-tests-host--with-directory
    (cooked-host-start "announces"
                       '("/bin/sh" "-c" "printf '\\033]51;CH;2;4242;1\\033\\\\'; echo said; cat"))
    (sleep-for 0.3)
    (with-current-buffer (cooked-host-attach "announces")
      (should (cooked-tests--settle
               (lambda () (string-match-p "said" (cooked-tests--text)))))
      (should (equal cooked--completion-nonce "4242")))))

(ert-deftest cooked-host-a-kept-shell-is-found-again-by-name ()
  "`cooked-host-exec-shell' starts a shell under a name once, and after that
attaches to it: the same process, in the buffer it is given."
  (cooked-tests-host--with-directory
    (let* ((cooked-shell "/bin/sh")
           (cooked-shell-integration 'none)
           (first (cooked-host-exec-shell "one: shell" "sh-one" "/tmp/"))
           (pid (with-current-buffer first
                  (should (equal (buffer-name) "one: shell"))
                  (cooked--pid cooked--session))))
      (kill-buffer first)
      (with-current-buffer (cooked-host-exec-shell "one: shell again" "sh-one" "/tmp/")
        (should (equal (buffer-name) "one: shell again"))
        (should (equal (cooked--pid cooked--session) pid))))))

(ert-deftest cooked-host-restore-starts-a-cut-off-shell-again ()
  "A description with no host answering for it is a session that was cut off.
If it was a shell it is started again where it was, under the name it had;
anything else is not this file\\='s to run twice."
  (cooked-tests-host--with-directory
    (make-directory cooked-host-directory t)
    (dolist (session '(("was-shell" . "\"shell\"") ("was-other" . "null")))
      (with-temp-file (expand-file-name (concat (car session) ".json")
                                        cooked-host-directory)
        (insert (format "{\"name\":\"%s\",\"pid\":1,\"cwd\":\"/tmp\",\"argv\":[\"/bin/sh\"],\"created\":0,\"note\":%s}"
                        (car session) (cdr session)))))
    (should (equal (mapcar (lambda (entry) (alist-get 'state entry))
                           (cooked-host-sessions))
                   '("dead" "dead")))
    (let* ((cooked-shell "/bin/sh")
           (cooked-shell-integration 'none)
           (buffers (cooked-host-restore)))
      (should (= (length buffers) 1))
      (with-current-buffer (car buffers)
        (should (equal cooked-host-name "was-shell"))
        (should (cooked--live-p cooked--session)))
      (should (equal (alist-get 'state (cooked-host--session "was-shell")) "live"))
      (should (equal (alist-get 'state (cooked-host--session "was-other")) "dead")))))

(provide 'cooked-tests-host)

;;; cooked-tests-host.el ends here
