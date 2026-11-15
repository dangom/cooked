;;; cooked-tests-run.el --- following a command run out of sight -*- lexical-binding: t; -*-

;;; Commentary:

;; cooked-run.el against runs written the way `cooked-host run' writes them
;; (tests/run.rs is that half), and one against the program itself.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cooked-run)
(require 'cooked-tests-helpers)

(defmacro cooked-tests--with-runs (&rest body)
  "Run BODY with runs kept in a directory of this test's own, as session `s'."
  (declare (indent 0))
  `(let* ((cooked-run-directory (make-temp-file "cooked-runs" t))
          (cooked-run-interval 0.05))
     (unwind-protect
         (progn ,@body)
       (dolist (buffer (buffer-list))
         (when (buffer-local-value 'cooked-run--run buffer)
           (kill-buffer buffer)))
       (delete-directory cooked-run-directory t))))

(defun cooked-tests--write-run (id output &rest fields)
  "Write a run ID of session `s' that printed OUTPUT; FIELDS over the usual ones."
  (let* ((dir (expand-file-name "s" cooked-run-directory))
         (meta (append fields
                       `(:id ,id :session "s" :pid ,(emacs-pid) :cwd "/tmp"
                         :argv ["/bin/sh" "-c" "make"] :label "make" :started 1700000000.5))))
    (make-directory dir t)
    (let ((coding-system-for-write 'binary))
      (write-region output nil (expand-file-name (concat id ".out") dir) nil 'silent))
    (write-region (json-serialize (cl-loop for (key value) on meta by #'cddr
                                           unless (assq (intern (substring (symbol-name key) 1)) alist)
                                           collect (cons (intern (substring (symbol-name key) 1)) value)
                                           into alist
                                           finally return alist))
                  nil (expand-file-name (concat id ".json") dir) nil 'silent)
    (expand-file-name (concat id ".out") dir)))

(ert-deftest cooked-run-lists-a-sessions-runs-oldest-first ()
  "The runs of a session, as their files describe them; none for a name that
is not a session's."
  (cooked-tests--with-runs
    (cooked-tests--write-run "1700000002.000000-2" "b" :label "second" :ended 1700000003.0 :exit 2)
    (cooked-tests--write-run "1700000001.000000-1" "a" :label "first")
    (let ((runs (cooked-runs "s")))
      (should (equal (mapcar #'cooked-run-name runs) '("first" "second")))
      (should (equal (cooked-run-status (cadr runs)) "exit 2"))
      ;; Its process is this Emacs, which is alive.
      (should (equal (cooked-run-status (car runs)) "running"))
      (should (equal (plist-get (car runs) :cwd) "/tmp")))
    (should-not (cooked-runs "other"))
    (should-not (cooked-runs "../s"))
    (with-temp-buffer
      (setq-local cooked-host-name "s")
      (should (= (length (cooked-runs)) 2)))))

(ert-deftest cooked-run-shows-colours-and-obeys-nothing-else ()
  "Output is text: its colours are faces, a line drawn over shows as its last,
and every other sequence a terminal would have obeyed is dropped."
  (cooked-tests--with-runs
    (cooked-tests--write-run
     "1700000001.000000-1"
     (concat "\e[31mred\e[0m plain\n"
             "10%\r50%\r100%\n"
             "\e]52;c;c2VjcmV0\a\e]51;E1;F;/etc/passwd\e\\after\n"
             "\e[2J\e[10;10Hmoved\n")
     :ended 1700000002.0 :exit 0)
    (with-current-buffer (cooked-run-buffer (car (cooked-runs "s")))
      (should (derived-mode-p 'cooked-run-mode))
      (should buffer-read-only)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (equal text "$ make\n\nred plain\n100%\nafter\nmoved\n")))
      (goto-char (point-min))
      (search-forward "red")
      (should (get-text-property (1- (point)) 'face))
      (should-not (get-text-property (+ (point) 2) 'face))
      (should (string-match-p "exit 0" header-line-format))
      (should (equal default-directory "/tmp/"))
      ;; It has ended: nothing is left looking at it.
      (should-not cooked-run--timer))))

(ert-deftest cooked-run-follows-a-run-that-is-still-going ()
  "What is printed after the buffer was made is added to it, a whole line at a
time; when the run ends the rest is shown and the looking stops."
  (cooked-tests--with-runs
    (let* ((file (cooked-tests--write-run "1700000001.000000-1" "one\ntw"))
           (buffer (cooked-run-buffer (car (cooked-runs "s")))))
      (with-current-buffer buffer
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "$ make\n\none\n"))
        (should cooked-run--timer)
        (should (string-match-p "running" header-line-format))
        (let ((coding-system-for-write 'binary))
          (write-region "o\nthr" nil file t 'silent))
        (cooked-run-refresh)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "$ make\n\none\ntwo\n"))
        ;; Looking again with nothing new adds nothing.
        (cooked-run-refresh)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "$ make\n\none\ntwo\n"))
        (let ((coding-system-for-write 'binary))
          (write-region "ee" nil file t 'silent))
        (cooked-tests--write-run "1700000001.000000-1" "one\ntwo\nthree"
                                 :ended 1700000004.5 :signal 2)
        (cooked-run-refresh)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "$ make\n\none\ntwo\nthree"))
        (should (string-match-p "signal 2  ·  4.0s" header-line-format))
        (should-not cooked-run--timer)
        ;; The same run asked for again is the same buffer.
        (should (eq (cooked-run-buffer (car (cooked-runs "s"))) buffer))))))

(ert-deftest cooked-run-reads-what-the-program-writes ()
  "A command run through `cooked-host run' in a session is listed and shown."
  (let ((host (expand-file-name "target/release/cooked-host" (cooked--root))))
    (skip-unless (file-executable-p host))
    (cooked-tests--with-runs
      (let ((process-environment
             (append (list (concat "COOKED_RUN_DIR=" cooked-run-directory)
                           "COOKED_HOST_SESSION=s")
                     process-environment)))
        (should (= 3 (call-process host nil nil nil "run" "--label" "say it" "--"
                                   "/bin/sh" "-c" "printf 'said\\n'; exit 3"))))
      (let ((run (car (cooked-runs "s"))))
        (should (equal (cooked-run-name run) "say it"))
        (should (equal (cooked-run-status run) "exit 3"))
        (with-current-buffer (cooked-run-buffer run)
          (should (string-suffix-p "said\n" (buffer-string))))))))

(ert-deftest cooked-run-follows-the-program-as-it-prints ()
  "A buffer made while a command is going shows each line once, as it comes,
and how the command ended."
  (let ((host (expand-file-name "target/release/cooked-host" (cooked--root))))
    (skip-unless (file-executable-p host))
    (cooked-tests--with-runs
      (let* ((process-environment
              (append (list (concat "COOKED_RUN_DIR=" cooked-run-directory)
                            "COOKED_HOST_SESSION=s")
                      process-environment))
             (process (start-process
                       "cooked-run-test" nil host "run" "--label" "count" "--"
                       "/bin/sh" "-c"
                       "for i in 1 2 3 4 5; do echo \"line $i\"; sleep 0.2; done; exit 7"))
             (wait (lambda (done)
                     (let ((tries 0))
                       (while (and (not (funcall done)) (< (cl-incf tries) 200))
                         (accept-process-output nil 0.05))
                       (funcall done))))
             buffer)
        (set-process-query-on-exit-flag process nil)
        (should (funcall wait (lambda () (cooked-runs "s"))))
        (setq buffer (cooked-run-buffer (car (cooked-runs "s"))))
        (with-current-buffer buffer
          (should cooked-run--timer)
          (should (funcall wait (lambda () (null cooked-run--timer))))
          (should (equal (buffer-substring-no-properties (point-min) (point-max))
                         "$ count\n\nline 1\nline 2\nline 3\nline 4\nline 5\n"))
          (should (string-match-p "exit 7" header-line-format)))))))

(provide 'cooked-tests-run)
;;; cooked-tests-run.el ends here
