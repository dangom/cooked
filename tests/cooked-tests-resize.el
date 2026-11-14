;;; cooked-tests-resize.el --- Resizing a program that repaints everything -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-defer-resize-on-main-screen': a program drawing inline redraws on
;; SIGWINCH, and whatever it redraws taller than the screen is left behind in the
;; scrollback, where nothing can erase it.  The fake here makes that as plain as
;; it gets -- it reprints its whole transcript, banner first, on every resize, as
;; Claude Code's classic renderer can -- so each resize that reaches it adds a
;; banner.  Only a shrink in height is held back, and only while the program
;; owns the keyboard on the main screen.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)

(defconst cooked-tests--repainter-program
  (concat "import os, sys, tty, signal, fcntl, termios, struct\n"
          "tty.setraw(0)\n"
          "out = sys.stdout\n"
          "lines = ['BANNER'] + ['line %d' % i for i in range(1, 61)] + ['> ']\n"
          "def size():\n"
          "    r, c, _, _ = struct.unpack('HHHH', fcntl.ioctl(1, termios.TIOCGWINSZ, b'\\0' * 8))\n"
          "    return r, c\n"
          "def paint():\n"
          "    out.write('\\r\\n'.join(lines))\n"
          "    out.flush()\n"
          "count = [0]\n"
          "def repaint(*_):\n"
          "    count[0] += 1\n"
          "    rows, _ = size()\n"
          ;; What Claude Code's classic renderer sends on a resize: home, erase
          ;; every screen row, then the whole transcript again from the top.
          "    out.write('\\x1b[H' + '\\x1b[2K\\x1b[1B' * rows + '\\x1b[H')\n"
          "    paint()\n"
          "    out.write(' repaint=%d' % count[0])\n"
          "    out.flush()\n"
          "signal.signal(signal.SIGWINCH, repaint)\n"
          "paint()\n"
          "while True:\n"
          "    try:\n"
          "        b = os.read(0, 64)\n"
          "    except InterruptedError:\n"
          "        continue\n"
          "    if b == b'A':\n"
          "        out.write('\\x1b[?1049h' + ' alt=%dx%d' % size())\n"
          "        out.flush()\n"
          "    if not b or b == b'q':\n"
          "        break\n")
  "An inline program that reprints its whole transcript whenever it is resized.")

(defun cooked-tests--count (regexp)
  "How many times REGEXP matches in the buffer's text."
  (let ((text (cooked-tests--text)) (n 0) (start 0))
    (while (string-match regexp text start)
      (setq n (1+ n) start (match-end 0)))
    n))

(defun cooked-tests--banners ()
  "How many copies of the repainter's first line the buffer holds."
  (cooked-tests--count "^BANNER"))

(defun cooked-tests--repaints ()
  "How many times the repainter says it has repainted so far."
  (let ((text (cooked-tests--text)) (n 0) (start 0))
    (while (string-match "repaint=\\([0-9]+\\)" text start)
      (setq n (max n (string-to-number (match-string 1 text)))
            start (match-end 0)))
    n))

(defun cooked-tests--repainted (count)
  "Wait until the repainter has repainted COUNT times in all, and say whether."
  (cooked-tests--settle (lambda () (= (cooked-tests--repaints) count))))

(defmacro cooked-tests--with-repainter (&rest body)
  "Run BODY in the sole window, on `cooked-tests--repainter-program'."
  (declare (indent 0))
  `(cooked-tests--with-session
       (list "python3" "-I" "-c" cooked-tests--repainter-program)
     (delete-other-windows)
     (switch-to-buffer (current-buffer))
     (should (cooked-tests--settle
              (lambda () (string-match-p "line 60" (cooked-tests--text)))))
     (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
     ;; Settled at the window's size first, whatever that costs: the
     ;; repaints that counts are the ones after this.
     (cooked--sync-size)
     (cooked-tests--settle (lambda () nil) 0.5)
     ;; The transcript has outgrown the screen: the banner is history now.
     (should (< cooked--rows 61))
     (let ((cooked-tests--banners-before (cooked-tests--banners))
           (cooked-tests--repaints-before (cooked-tests--repaints)))
       (ignore cooked-tests--banners-before cooked-tests--repaints-before)
       ,@body)))

(defun cooked-tests--shorten-window ()
  "Take a few lines off the selected window, as a split below it does."
  (set-window-buffer (split-window nil (- (window-total-height) 4) 'below)
                     (get-buffer-create " *cooked-tests-other*"))
  (cooked--sync-size))

(ert-deftest cooked-resize-height-is-held-for-an-inline-program ()
  "A shorter window does not resize a program drawing inline, so it does not
repaint, and its transcript is not copied into the scrollback again."
  (cooked-tests--with-repainter
    (let ((rows cooked--rows))
      (cooked-tests--shorten-window)
      (should cooked--resize-deferred)
      (should (= cooked--rows rows))
      (cooked-tests--settle (lambda () nil) 0.5)
      (should (= (cooked-tests--repaints) cooked-tests--repaints-before))
      (should (= (cooked-tests--banners) cooked-tests--banners-before)))))

(ert-deftest cooked-resize-without-the-hold-copies-the-transcript ()
  "What the hold prevents: told about the new height, the program repaints its
whole transcript from the top, and the copy already in the scrollback stays."
  (let ((cooked-defer-resize-on-main-screen nil))
    (cooked-tests--with-repainter
      (cooked-tests--shorten-window)
      (should-not cooked--resize-deferred)
      (should (cooked-tests--repainted (1+ cooked-tests--repaints-before)))
      (should (= (cooked-tests--banners) (1+ cooked-tests--banners-before))))))

(ert-deftest cooked-resize-held-height-is-delivered-on-the-alternate-screen ()
  "The height held back is owed, and paid the moment the program takes the
alternate screen, where a full-screen drawing needs the exact size."
  (cooked-tests--with-repainter
    (cooked-tests--shorten-window)
    (should cooked--resize-deferred)
    (cooked--send cooked--session "A")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should (cooked-tests--settle (lambda () (not cooked--resize-deferred))))
    (should (= cooked--rows (car (cooked--window-size))))))

(ert-deftest cooked-resize-taller-is-passed-on-at-once ()
  "More room is never held back: a window that gets taller resizes the program
straight away, and nothing is owed afterwards."
  (cooked-tests--with-repainter
    (let ((cooked-defer-resize-on-main-screen nil))
      (cooked-tests--shorten-window))
    (let ((rows cooked--rows))
      (should (cooked-tests--repainted (1+ cooked-tests--repaints-before)))
      (delete-other-windows)
      (cooked--sync-size)
      (should-not cooked--resize-deferred)
      (should (> cooked--rows rows)))))

(ert-deftest cooked-resize-width-waits-to-settle ()
  "A change of width reaches an inline program once it has held for
`cooked-resize-settle-delay', and not before: told of every passing width, the
program's erase of its last frame counts rows at the wrong one, and Claude
Code's classic renderer prints the conversation again each time."
  (cooked-tests--with-repainter
    (let ((cols cooked--cols)
          (cooked-resize-settle-delay 0.2))
      (set-window-buffer (split-window nil (- (window-total-width) 10) 'right)
                         (get-buffer-create " *cooked-tests-other*"))
      (cooked--sync-size)
      (should cooked--resize-deferred)
      (should (= cooked--cols cols))
      (should (cooked-tests--settle (lambda () (< cooked--cols cols)) 3))
      (should-not cooked--resize-deferred)
      (should (cooked-tests--repainted (1+ cooked-tests--repaints-before))))))

(ert-deftest cooked-resize-width-at-once-without-a-delay ()
  "With `cooked-resize-settle-delay' nil a change of width reaches the program
at once."
  (cooked-tests--with-repainter
    (let ((cols cooked--cols)
          (cooked-resize-settle-delay nil))
      (set-window-buffer (split-window nil (- (window-total-width) 10) 'right)
                         (get-buffer-create " *cooked-tests-other*"))
      (cooked--sync-size)
      (should-not cooked--resize-deferred)
      (should (< cooked--cols cols))
      (should (cooked-tests--repainted (1+ cooked-tests--repaints-before))))))

(provide 'cooked-tests-resize)
;;; cooked-tests-resize.el ends here
