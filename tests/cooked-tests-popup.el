;;; cooked-tests-popup.el --- a look at a buffer or a file -*- lexical-binding: t; -*-

;;; Commentary:

;; cooked-popup.el where there are no child frames, which is where the suite
;; runs: a pop-up is then a window, and everything but the frame's geometry is
;; the same -- what is shown, what going back returns to, what closing leaves
;; behind.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cooked-popup)

(defvar cooked-tests--popped nil "Set by what a pop-up must not run.")

(defmacro cooked-tests--with-popup-file (spec &rest body)
  "Run BODY with (VAR SUFFIX CONTENTS) of SPEC a temporary file, in a window
configuration and with a pop-up of its own."
  (declare (indent 1))
  (pcase-let ((`(,var ,suffix ,contents) spec))
    `(let ((,var (make-temp-file "cooked-popup" nil ,suffix ,contents)))
       (unwind-protect
           (save-window-excursion
             (unwind-protect (progn ,@body)
               (cooked-popup-quit)))
         (delete-file ,var)))))

(ert-deftest cooked-popup-shows-a-file-read-only-in-its-mode ()
  "A file is shown at its line in the mode it would be visited in, by a buffer
that does not visit it and cannot be changed; `v' visits it at the line shown."
  (cooked-tests--with-popup-file (file ".el" "(one)\n(two)\n(three)\n")
    (let ((buffer (cooked-popup-file file 2 1)))
      (with-current-buffer buffer
        (should (eq major-mode 'emacs-lisp-mode))
        (should-not buffer-file-name)
        (should buffer-read-only)
        (should-not (buffer-modified-p))
        (should (equal (buffer-string) "(one)\n(two)\n(three)\n"))
        (should (= (line-number-at-pos) 2))
        (should (= (current-column) 1))
        (should-error (insert "x") :type 'buffer-read-only)
        (should (eq (key-binding "q") #'cooked-popup-quit))
        ;; `v' is evil's own where evil has the buffer; see cooked-popup.el.
        (unless (bound-and-true-p evil-local-mode)
          (should (eq (key-binding "v") #'cooked-popup-visit)))
        (forward-line 1)
        (cooked-popup-visit))
      (should-not (buffer-live-p buffer))
      (let ((visiting (get-file-buffer file)))
        (unwind-protect
            (with-current-buffer visiting
              (should (eq (window-buffer) visiting))
              (should (= (line-number-at-pos) 3)))
          (kill-buffer visiting))))))

(ert-deftest cooked-popup-runs-nothing-a-file-says ()
  "Neither the mode's hooks nor the file's local variables are run for a look."
  (cooked-tests--with-popup-file
      (file ".el" ";; -*- eval: (setq cooked-tests--popped t) -*-\n(one)\n")
    (let ((cooked-tests--popped nil)
          (enable-local-eval t)
          (emacs-lisp-mode-hook (list (lambda () (setq cooked-tests--popped 'hook)))))
      (with-current-buffer (cooked-popup-file file)
        (should (eq major-mode 'emacs-lisp-mode)))
      (should-not cooked-tests--popped))))

(ert-deftest cooked-popup-goes-back-and-leaves-nothing-behind ()
  "A pop-up from inside a pop-up replaces it and `l' returns; closing kills the
buffers made for files and leaves the caller's alone."
  (cooked-tests--with-popup-file (file ".txt" "hello\n")
    (let ((mine (generate-new-buffer "*mine*"))
          (origin (selected-window)))
      (unwind-protect
          (progn
            (with-current-buffer mine (insert "call") (cooked-popup-mode 1))
            (cooked-popup-buffer mine)
            (should (eq (window-buffer) mine))
            (should-error (cooked-popup-back) :type 'user-error)
            (let ((shown (cooked-popup-file file)))
              (should (eq (window-buffer) shown))
              (cooked-popup-back)
              (should (eq (window-buffer) mine))
              (should (buffer-live-p shown))
              (cooked-popup-quit)
              (should-not (buffer-live-p shown)))
            (should (buffer-live-p mine))
            (should-not (get-buffer-window mine))
            (should (eq (selected-window) origin)))
        (kill-buffer mine)))))

(ert-deftest cooked-popup-visits-what-it-cannot-show ()
  "A directory, or a file over the limit, is visited in a window instead."
  (cooked-tests--with-popup-file (file ".txt" "0123456789\n")
    (let ((cooked-popup-max-file-size 4))
      (should-not (cooked-popup-file file))
      (let ((visiting (get-file-buffer file)))
        (should (eq (window-buffer) visiting))
        (kill-buffer visiting)))
    (should-error (cooked-popup-file (concat file ".missing")) :type 'user-error)))

(ert-deftest cooked-popup-is-a-file-open-function ()
  "`cooked-popup-open-file' answers for `cooked-file-open-function'."
  (cooked-tests--with-popup-file (file ".txt" "a\nb\n")
    (should (eq (cooked-popup-open-file file 2 nil) t))
    (with-current-buffer (window-buffer)
      (should (equal cooked-popup--file file))
      (should (= (line-number-at-pos) 2)))))

(provide 'cooked-tests-popup)
;;; cooked-tests-popup.el ends here
