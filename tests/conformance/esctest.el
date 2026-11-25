;;; esctest.el --- Run esctest against cooked  -*- lexical-binding: t; -*-

;;; Commentary:

;; esctest is the automated terminal conformance suite George Nachman wrote for
;; iTerm2 and Thomas Dickey maintains for xterm
;; (https://github.com/ThomasDickey/esctest2).  It prints escape sequences and
;; reads the screen back a cell at a time with DECRQCRA, so it runs here as an
;; ordinary child of a real session with `cooked-checksum-reports' on: what it
;; measures is the emulator, the reply path and the pty together.
;;
;; It is not vendored.  Check it out somewhere and say where:
;;
;;   make conformance ESCTEST=/path/to/esctest2
;;
;; or, by hand, from the top of the tree:
;;
;;   ESCTEST=/path/to/esctest2 emacs -Q --batch -L lisp -L tests \
;;     -l tests/conformance/esctest.el -f cooked-esctest
;;
;; `ESCTEST_INCLUDE' is an Emacs regexp over test names, to run a few of them;
;; `ESCTEST_LOG' is where esctest's own log goes, every test's in turn; and
;; `ESCTEST_FAILURES' names a file to write the failing names to.  Each test
;; runs in a session of its own -- see `cooked-esctest--run' for why -- so a
;; full run is a few minutes.  The verdict is compared with
;; tests/conformance/esctest-expected-failures.txt: a test that fails and is
;; not listed there fails the run, and so does one that is listed and passes,
;; so the list can only get shorter on purpose.

;;; Code:

(require 'cooked-tests-helpers)

(defconst cooked-esctest--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Where this file and the list of expected failures live.")

(defun cooked-esctest--expected ()
  "The names of the tests known to fail, from the list beside this file."
  (let ((file (expand-file-name "esctest-expected-failures.txt"
                                cooked-esctest--directory))
        names)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (while (not (eobp))
          (when (looking-at "\\([A-Za-z0-9_]+\\.test_[A-Za-z0-9_]+\\)")
            (push (match-string 1) names))
          (forward-line 1))))
    names))

(defun cooked-esctest--names (root)
  "The name of every test in the esctest checkout at ROOT, in the order run."
  (with-temp-buffer
    (unless (eq 0 (call-process "python3" nil t nil "-E" "-s"
                                (expand-file-name "esctest_names.py"
                                                  cooked-esctest--directory)
                                root))
      (error "Could not list esctest's tests: %s" (buffer-string)))
    (split-string (buffer-string) "\n" t)))

(defun cooked-esctest--verdict (log)
  "What esctest wrote in LOG about the one test it ran there.
One of `passed', `failed' and `skipped' -- the last for a test esctest itself
declines or knows to fail -- or nil when it reached no verdict at all."
  (with-temp-buffer
    (ignore-errors (insert-file-contents log))
    (goto-char (point-min))
    (cond ((re-search-forward "^\\*\\*\\* TEST .* FAILED:" nil t) 'failed)
          ((re-search-forward "Passed\\.$" nil t) 'passed)
          ((re-search-forward "Fails as expected\\|Skipped because" nil t) 'skipped))))

(defun cooked-esctest--run (script name log)
  "Run the test NAME of esctest's SCRIPT in a session of its own, logging to LOG.
Return its verdict; see `cooked-esctest--verdict'.

A session each, because esctest takes the terminal for xterm and never throws
away an answer it did not wait for.  One that arrives late, or that xterm would
not have sent, is read as the answer to the next question, and from there every
test fails in its own reset: run as one program, three quarters of the suite's
failures here were that and nothing to do with what they test."
  (let ((done (make-temp-file "cooked-esctest-done")))
    (delete-file done)
    (unwind-protect
        ;; esctest wants 80 columns by 25 rows and asks the terminal to become
        ;; that, which is Emacs' to decide and is refused -- so it starts that way.
        (cl-letf (((symbol-function 'cooked--window-size) (lambda (&rest _) '(25 . 80))))
          (cooked-tests--with-session
              (list "/bin/sh" "-c"
                    ;; `-E -s', not `-I': isolated mode also keeps the script's own
                    ;; directory off `sys.path', and esctest imports from there.
                    (format "python3 -E -s %s --expected-terminal=xterm \
--xterm-checksum=334 --max-vt-level=4 --timeout=0.4 --no-print-logs --v=3 \
--logfile=%s --include=%s; echo $? > %s"
                            (shell-quote-argument script)
                            (shell-quote-argument log)
                            (shell-quote-argument (concat "^" (regexp-quote name) "$"))
                            (shell-quote-argument done)))
            (cooked-tests--settle (lambda () (file-exists-p done)) 60))
          (cooked-esctest--verdict log))
      (ignore-errors (delete-file done)))))

(defun cooked-esctest ()
  "Run esctest under cooked, a session a test, and exit with the verdict."
  (let* ((root (or (getenv "ESCTEST")
                   (error "Set ESCTEST to a checkout of esctest2")))
         (script (expand-file-name "esctest/esctest.py" root))
         (include (or (getenv "ESCTEST_INCLUDE") ""))
         (log (or (getenv "ESCTEST_LOG") (make-temp-file "cooked-esctest" nil ".log")))
         (one (make-temp-file "cooked-esctest-one" nil ".log"))
         (cooked-checksum-reports t)
         passed failed skipped)
    (unless (file-readable-p script)
      (error "No esctest at %s" script))
    (with-temp-file log)
    (let* ((names (seq-filter (lambda (name) (string-match-p include name))
                              (cooked-esctest--names root)))
           (count 0))
      (dolist (name names)
        (with-temp-file one)
        (pcase (cooked-esctest--run script name one)
          ('passed (push name passed))
          ('skipped (push name skipped))
          ;; No verdict is a failure too: esctest died, or outlasted its minute.
          (_ (push name failed)))
        (write-region (format "\n===== %s\n" name) nil log t 'silent)
        (let ((coding-system-for-read 'no-conversion)
              (coding-system-for-write 'no-conversion))
          (with-temp-buffer
            (insert-file-contents one)
            (write-region nil nil log t 'silent)))
        (when (zerop (% (cl-incf count) 50))
          (message "esctest: %d of %d run, %d failed so far"
                   count (length names) (length failed)))))
    (ignore-errors (delete-file one))
    (setq passed (nreverse passed) failed (nreverse failed) skipped (nreverse skipped))
    (let* ((expected (cooked-esctest--expected))
           (regressions (seq-difference failed expected))
           (fixed (seq-intersection passed expected)))
      (message "esctest: %d passed, %d failed, %d skipped or known to esctest; log in %s"
               (length passed) (length failed) (length skipped) log)
      (when-let* ((file (getenv "ESCTEST_FAILURES")))
        (with-temp-file file
          (dolist (name failed) (insert name "\n")))
        (message "esctest: the %d failing names are in %s" (length failed) file))
      (if (> (length regressions) 40)
          (message "%d UNEXPECTED FAILURES; set ESCTEST_FAILURES=file to list them"
                   (length regressions))
        (dolist (name regressions) (message "UNEXPECTED FAILURE %s" name)))
      (dolist (name fixed)
        (message "NOW PASSES %s (remove it from esctest-expected-failures.txt)" name))
      (kill-emacs (if (or regressions fixed (null passed)) 1 0)))))

(provide 'esctest)
;;; esctest.el ends here
