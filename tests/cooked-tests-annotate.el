;;; cooked-tests-annotate.el --- clickable notes on stretches of output -*- lexical-binding: t; -*-

;;; Commentary:

;; cooked-annotate.el, against a real child that repaints a row in place and
;; scrolls its output into scrollback -- the two things that destroy an
;; overlay on a terminal's rows.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-annotate)

(defconst cooked-tests--repaint-program
  (concat "import os, sys, tty\n"
          "tty.setraw(0)\n"
          "out = sys.stdout\n"
          "out.write('row-a\\r\\nrow-b\\r\\nrow-c\\r\\n> ')\n"
          "out.flush()\n"
          "while True:\n"
          "    b = os.read(0, 64)\n"
          "    if not b:\n"
          "        break\n"
          "    if b == b'R':\n"
          ;; Up two rows to row-b, rewrite it, and come back.
          "        out.write('\\x1b[2A\\r\\x1b[2Krow-B\\x1b[2B\\r> ')\n"
          "    if b == b'T':\n"
          "        out.write('\\r\\x1b[2Kmore 1\\r\\nmore 2\\r\\nmore 3\\r\\n> ')\n"
          "    if b == b'S':\n"
          "        out.write(''.join('fill %d\\r\\n' % i for i in range(80)) + '> ')\n"
          "    out.flush()\n")
  "Three rows and a prompt.  `R' repaints the middle row; `S' scrolls a lot,
`T' three rows.")

(defmacro cooked-tests--with-repainting (&rest body)
  "Run BODY on `cooked-tests--repaint-program', its rows drawn."
  (declare (indent 0))
  `(cooked-tests--with-session
       (list "python3" "-I" "-c" cooked-tests--repaint-program)
     (should (cooked-tests--settle
              (lambda () (string-match-p "row-c\n>" (cooked-tests--text)))))
     ,@body))

(defun cooked-tests--row-position (text)
  "The start of the first row whose text begins with TEXT."
  (save-excursion
    (goto-char (point-min))
    (and (let ((case-fold-search nil))
           (re-search-forward (concat "^" (regexp-quote text)) nil t))
         (line-beginning-position))))

(defun cooked-tests--annotation-text (annotation)
  "The text of ANNOTATION's rows, as its overlay covers them."
  (let ((overlay (cooked-annotation-overlay annotation)))
    (and overlay (overlay-buffer overlay)
         (buffer-substring-no-properties (overlay-start overlay)
                                         (overlay-end overlay)))))

(ert-deftest cooked-annotate-marks-rows-and-activates ()
  "An annotation covers whole rows, carries a fringe mark, and RET on it calls
its action with it."
  (cooked-tests--with-repainting
    (let* ((called nil)
           (beg (cooked-tests--row-position "row-a"))
           (annotation (cooked-annotate (+ beg 2) (cooked-tests--row-position "row-b")
                                        :help "two rows" :data 'payload
                                        :action (lambda (a) (setq called a)))))
      (should cooked-annotation-mode)
      (should (equal (cooked-tests--annotation-text annotation) "row-a\nrow-b"))
      (should (eq (car (get-text-property
                        0 'display (overlay-get (cooked-annotation-overlay annotation)
                                                'before-string)))
                  'left-fringe))
      (should (eq (cooked-annotation-at (cooked-tests--row-position "row-b")) annotation))
      (should-not (cooked-annotation-at (cooked-tests--row-position "row-c")))
      (goto-char (cooked-tests--row-position "row-b"))
      (cooked-annotation-activate)
      (should (eq called annotation))
      (should (eq (cooked-annotation-data called) 'payload)))))

(ert-deftest cooked-annotate-survives-a-repaint-of-its-row ()
  "A row the program rewrites in place loses its overlay with its text; the
re-arm after the render puts the annotation back on the same row."
  (cooked-tests--with-repainting
    (let ((annotation (cooked-annotate (cooked-tests--row-position "row-b")
                                       (cooked-tests--row-position "row-b"))))
      (cooked--send cooked--session "R")
      (should (cooked-tests--settle
               (lambda () (cooked-tests--row-position "row-B"))))
      (should (equal (cooked-tests--annotation-text annotation) "row-B")))))

(ert-deftest cooked-annotate-follows-its-rows-into-scrollback ()
  "Output that scrolls the annotated rows into scrollback takes the annotation
with them."
  (cooked-tests--with-repainting
    (let ((annotation (cooked-annotate (cooked-tests--row-position "row-a")
                                       (cooked-tests--row-position "row-c"))))
      (cooked--send cooked--session "S")
      (should (cooked-tests--settle
               (lambda () (string-match-p "fill 79\n>" (cooked-tests--text)))))
      (should (< (overlay-end (cooked-annotation-overlay annotation))
                 (cooked--screen-start-position)))
      (should (equal (cooked-tests--annotation-text annotation)
                     "row-a\nrow-b\nrow-c")))))

(ert-deftest cooked-annotate-stays-on-a-row-scrolled-up-the-screen ()
  "A few rows of output move an annotated row up the live screen without
evicting it; the annotation moves with the row, not with the screen index."
  (cooked-tests--with-repainting
    (cooked--send cooked--session "S")
    (should (cooked-tests--settle
             (lambda () (string-match-p "fill 79\n>" (cooked-tests--text)))))
    (let ((annotation (cooked-annotate (cooked-tests--row-position "fill 75")
                                       (cooked-tests--row-position "fill 75"))))
      (should (>= (overlay-start (cooked-annotation-overlay annotation))
                  (cooked--screen-start-position)))
      (cooked--send cooked--session "T")
      (should (cooked-tests--settle
               (lambda () (string-match-p "more 3\n>" (cooked-tests--text)))))
      (should (equal (cooked-tests--annotation-text annotation) "fill 75")))))

(ert-deftest cooked-annotate-steps-and-deletes ()
  "`cooked-annotation-next'/`-previous' visit annotations in buffer order, and a
deleted one is gone from the buffer and the list."
  (cooked-tests--with-repainting
    (let ((a (cooked-annotate (cooked-tests--row-position "row-a")
                              (cooked-tests--row-position "row-a")))
          (c (cooked-annotate (cooked-tests--row-position "row-c")
                              (cooked-tests--row-position "row-c"))))
      (should (equal (cooked-annotations) (list a c)))
      (goto-char (point-min))
      (cooked-annotation-next)
      (should (= (point) (cooked-tests--row-position "row-c")))
      (cooked-annotation-previous)
      (should (= (point) (cooked-tests--row-position "row-a")))
      (should-error (cooked-annotation-previous) :type 'user-error)
      (cooked-annotation-delete c)
      (should (equal (cooked-annotations) (list a)))
      (should-not (cooked-annotation-at (cooked-tests--row-position "row-c"))))))

(provide 'cooked-tests-annotate)
;;; cooked-tests-annotate.el ends here
