;;; cooked-tests-dock.el --- The dock that keeps a program's input in view -*- lexical-binding: t; -*-

;;; Commentary:

;; cooked-dock.el, and the scroll mapping in cooked-render.el that keeps a
;; window being read on the same text while the screen under it scrolls.
;; Driven through `execute-kbd-macro' on the program from
;; cooked-tests-navigate.el, so the command hooks that dock and undock are the
;; ones a key press really runs.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-tests-navigate)
(require 'cooked)
(require 'cooked-mode)
(require 'cooked-dock)

(defun cooked-tests--main-window ()
  "The window on this buffer that is not a dock."
  (car (seq-remove #'cooked--dock-window-p (get-buffer-window-list))))

(defmacro cooked-tests--with-docked (&rest body)
  "Run BODY on the navigable program, scrolled up a screen so it is docked."
  (declare (indent 0))
  `(cooked-tests--with-navigable
     (delete-other-windows)
     (let ((cooked-dock t)
           (cooked-dock-context-rows 1)
           (cooked-dock-max-fraction 0.5)
           (size (cooked--window-size)))
       (cooked-tests--keys "M-v")
       (should cooked-navigate--reading)
       (should (window-live-p (window-parameter (cooked-tests--main-window)
                                                'cooked-dock)))
       (ignore size)
       ,@body)))

(ert-deftest cooked-dock-scrolling-away-docks-the-input ()
  "Scrolled away from the bottom, the window's last rows become a dock showing
the program's input, and the program is not resized for it."
  (let ((size nil))
    (cooked-tests--with-navigable
      (delete-other-windows)
      (setq size (cooked--window-size))
      (let ((cooked-dock t) (cooked-dock-context-rows 1)
            (cooked-dock-max-fraction 0.5))
        (cooked-tests--keys "M-v")
        (let* ((main (cooked-tests--main-window))
               (dock (window-parameter main 'cooked-dock)))
          (should (window-live-p dock))
          (should (eq (window-buffer dock) (current-buffer)))
          (should (eq (window-parameter dock 'cooked-dock-main) main))
          ;; The pair is one terminal: the child keeps its size.
          (should (equal (cooked--window-size) size))
          ;; The dock shows the cursor's row, and the window above stops short
          ;; of the rows the dock shows.
          (should (<= (window-start dock) (cooked--cursor-position)))
          (should (< (cooked-dock--row main (1- (cooked--window-rows-of main)))
                     (window-start dock))))))))

(ert-deftest cooked-dock-a-small-scroll-leaves-point-in-view ()
  "Regression: docking after a scroll of a row left point on a row the dock
had just covered, and redisplay scrolled the window straight back to it."
  (cooked-tests--with-navigable
    (delete-other-windows)
    (let ((cooked-dock t) (cooked-dock-context-rows 1)
          (cooked-dock-max-fraction 0.5))
      ;; A one-row scroll, run the way the command loop runs one: at the input
      ;; `C-u' is the program's, so it cannot be typed as a prefix.
      (setq this-command 'ignore)
      (run-hooks 'pre-command-hook)
      (set-window-start nil (save-excursion (goto-char (window-start))
                                            (line-beginning-position 0)))
      (run-hooks 'post-command-hook)
      (let* ((main (cooked-tests--main-window))
             (dock (window-parameter main 'cooked-dock)))
        (should (window-live-p dock))
        (should (<= (window-point main)
                    (cooked-dock--row
                     main (1- (car (cooked-dock--visible-rows main))))))))))

(ert-deftest cooked-dock-typing-while-reading-goes-to-the-dock ()
  "A key typed while reading is sent from the dock, and the window being read
stays where it is."
  (cooked-tests--with-docked
    (let* ((main (cooked-tests--main-window))
           (dock (window-parameter main 'cooked-dock))
           (start (window-start main)))
      (cooked-tests--keys "z")
      (should (string-match-p "b'z'" (cooked-tests--text)))
      (should (eq (selected-window) dock))
      (should-not cooked-navigate--reading)
      (should (= (window-start main) start)))))

(ert-deftest cooked-dock-scroll-keys-in-the-dock-scroll-the-transcript ()
  "`M-v' typed in the dock scrolls the window above it, not the dock."
  (cooked-tests--with-docked
    (let* ((main (cooked-tests--main-window))
           (dock (window-parameter main 'cooked-dock)))
      (cooked-tests--keys "z")
      (should (eq (selected-window) dock))
      (let ((start (window-start main))
            (dock-start (window-start dock)))
        (cooked-tests--keys "M-v")
        (should (eq (selected-window) main))
        (should (< (window-start main) start))
        (should (= (window-start dock) dock-start))))))

(ert-deftest cooked-dock-submitting-from-the-dock-follows-again ()
  "RET sent from the dock undocks, and the window follows the program again."
  (cooked-tests--with-docked
    (let ((main (cooked-tests--main-window)))
      (cooked-tests--keys "z")
      (cooked-tests--keys "RET")
      (should-not (window-parameter main 'cooked-dock))
      (should (= 1 (length (get-buffer-window-list))))
      (should (eq (selected-window) main))
      (should-not cooked-navigate--reading)
      (should-not (window-parameter main 'mode-line-format)))))

(ert-deftest cooked-dock-scrolling-back-down-undocks ()
  "Scrolling the window back down into the live rows puts the two together."
  (cooked-tests--with-docked
    (let ((main (cooked-tests--main-window)))
      (cooked-tests--keys "C-v")
      (should-not (window-parameter main 'cooked-dock))
      (should (= 1 (length (get-buffer-window-list))))
      (should-not cooked-navigate--reading))))

(ert-deftest cooked-dock-goes-when-the-program-takes-the-screen ()
  "A program that takes the alternate screen ends the dock: its keys are its own."
  (cooked-tests--with-docked
    (cooked-tests--keys "z")
    (cooked--send cooked--session "A")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should (cooked-tests--settle
             (lambda () (= 1 (length (get-buffer-window-list))))))))

(ert-deftest cooked-dock-off-scrolls-as-one-window ()
  "With `cooked-dock' nil nothing is split."
  (cooked-tests--with-navigable
    (delete-other-windows)
    (let ((cooked-dock nil))
      (cooked-tests--keys "M-v")
      (should cooked-navigate--reading)
      (should (= 1 (length (get-buffer-window-list)))))))

(ert-deftest cooked-dock-stale-docks-are-cleaned-up ()
  "A window marked as a dock with no window it belongs to -- what a restored
window configuration leaves -- is removed."
  (cooked-tests--with-navigable
    (delete-other-windows)
    (let ((stale (split-window nil nil 'below)))
      (set-window-buffer stale (current-buffer))
      (set-window-parameter stale 'cooked-docked t)
      (cooked-dock--clean-up)
      (should-not (window-live-p stale))
      (should (= 1 (length (get-buffer-window-list)))))))

(ert-deftest cooked-map-cell-follows-text-across-a-scroll ()
  "A screen cell is carried to the same text after the screen scrolls: up by
the rows that left, or into the scrollback batch for one that left itself."
  (cooked-tests--with-navigable
    (let ((screen-row-1 (save-excursion (cooked--goto-screen-cell '(1 . 2))
                                        (point))))
      ;; Nothing scrolled: the cell is the answer.
      (should (= (cooked--map-cell '(1 . 2) nil nil) screen-row-1))
      ;; Two rows scrolled: what was on row 3 is now on row 1.
      (should (= (cooked--map-cell '(3 . 2) '((0 . 5) (6 . 5)) 100)
                 screen-row-1))
      ;; Row 1 itself scrolled away: it is in the batch at its span, column
      ;; clamped to what the row kept.
      (should (= (cooked--map-cell '(1 . 2) '((0 . 5) (6 . 5)) 100) 108))
      (should (= (cooked--map-cell '(1 . 9) '((0 . 5) (6 . 5)) 100) 111)))))

(defconst cooked-tests--scrolling-program
  (concat "import os, sys, tty\n"
          "tty.setraw(0)\n"
          "out = sys.stdout\n"
          "for i in range(1, 61):\n"
          "    out.write('line %d\\r\\n' % i)\n"
          "out.write('> ')\n"
          "out.flush()\n"
          "n = 60\n"
          "while True:\n"
          "    b = os.read(0, 64)\n"
          "    if not b:\n"
          "        break\n"
          "    for _ in b:\n"
          "        n += 1\n"
          "        out.write('\\r\\x1b[Kline %d\\r\\n> ' % n)\n"
          "    out.flush()\n")
  "Like `cooked-tests--echo-program', but each byte it is sent prints one more
line above its input, scrolling the screen the way an agent's chat does.")

(ert-deftest cooked-reading-point-stays-on-its-text-while-the-screen-scrolls ()
  "Regression: point parked on a scrolling main screen walked down through the
transcript, one row per scroll, because it was put back on the same cell --
which after a scroll holds newer text -- until the window had to follow it."
  (cooked-tests--with-session
      (list "python3" "-I" "-c" cooked-tests--scrolling-program)
    (switch-to-buffer (current-buffer))
    (should (cooked-tests--settle
             (lambda () (string-match-p "line 60\n>" (cooked-tests--text)))))
    (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
    (cooked--refresh-keymap)
    (cooked-tests--keys "C-p C-p C-p")
    (should cooked-navigate--reading)
    (should (cooked--screen-cell))
    (let ((text (buffer-substring-no-properties (line-beginning-position)
                                                (line-end-position)))
          (start-text (buffer-substring-no-properties
                       (window-start)
                       (save-excursion (goto-char (window-start))
                                       (line-end-position)))))
      ;; Three more lines from the program scroll its screen by three rows.
      (cooked--send cooked--session "xyz")
      (should (cooked-tests--settle
               (lambda () (string-match-p "line 63" (cooked-tests--text)))))
      (should (equal (buffer-substring-no-properties (line-beginning-position)
                                                     (line-end-position))
                     text))
      ;; And the window being read shows what it showed.
      (should (equal (buffer-substring-no-properties
                      (window-start)
                      (save-excursion (goto-char (window-start))
                                      (line-end-position)))
                     start-text)))))

;; Which windows follow: a window that is not the selected one.

(defmacro cooked-tests--with-unselected-terminal (&rest body)
  "Run BODY with the scrolling program in a window that is not selected.
`term' is that window, and the selected one shows another buffer; no dock."
  (declare (indent 0))
  `(cooked-tests--with-session
       (list "python3" "-I" "-c" cooked-tests--scrolling-program)
     (delete-other-windows)
     (switch-to-buffer (current-buffer))
     (should (cooked-tests--settle
              (lambda () (string-match-p "line 60\n>" (cooked-tests--text)))))
     (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
     (cooked--refresh-keymap)
     (let* ((cooked-dock nil)
            (session (current-buffer))
            (term (selected-window))
            (other (split-window-right)))
       (set-window-buffer other (get-buffer-create "*cooked-tests-other*"))
       (select-window other)
       (unwind-protect
           (progn
             (with-current-buffer session
               (cooked-tests--settle (lambda () nil) 0.2))
             ,@body)
         (select-window term)
         (delete-other-windows)
         (kill-buffer "*cooked-tests-other*")))))

(defun cooked-tests--command (function)
  "Run FUNCTION the way the command loop runs a command, in the selected window."
  (with-current-buffer (window-buffer (selected-window))
    (setq this-command 'ignore)
    (run-hooks 'pre-command-hook)
    (funcall function)
    (with-current-buffer (window-buffer (selected-window))
      (run-hooks 'post-command-hook))))

(defun cooked-tests--row-text (window)
  "The text of the row WINDOW starts on."
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char (window-start window))
      (buffer-substring-no-properties (pos-bol) (pos-eol)))))

(ert-deftest cooked-a-window-scrolled-up-from-elsewhere-is-left-alone ()
  "A terminal's window scrolled up while another window is selected -- the wheel
scrolls the window under the mouse -- stays where it was put while output
arrives.  Its point is still on the live screen, which used to make it count
as following: the next drain pinned it back to the bottom, and under a program
printing steadily it could not be scrolled up at all."
  (cooked-tests--with-unselected-terminal
    (should-not (cooked--window-held-p term))
    (cooked-tests--command
     (lambda ()
       (set-window-start term (with-current-buffer session
                                (save-excursion
                                  (goto-char (window-start term))
                                  (pos-bol -2))))))
    (should (cooked--window-held-p term))
    (let ((text (cooked-tests--row-text term)))
      (with-current-buffer session
        (cooked--send cooked--session "xyz")
        (should (cooked-tests--settle
                 (lambda () (string-match-p "line 63" (cooked-tests--text))))))
      (should (equal (cooked-tests--row-text term) text)))
    ;; Scrolled back down to the bottom, by the same means, it follows again.
    (cooked-tests--command
     (lambda ()
       (set-window-start term (with-current-buffer session
                                (cooked--bottom-start term)))))
    (should-not (cooked--window-held-p term))
    (with-current-buffer session
      (cooked--send cooked--session "x")
      (should (cooked-tests--settle
               (lambda () (string-match-p "line 64" (cooked-tests--text)))))
      (should (= (window-start term) (cooked--bottom-start term))))))

(ert-deftest cooked-a-scroll-past-the-bottom-from-elsewhere-is-undone ()
  "A window that follows and is not the selected one cannot be scrolled past
the bottom either: the overshoot is undone after the command, not left for the
next drain to pull back, a notch at a time, for as long as the wheel turns."
  (cooked-tests--with-unselected-terminal
    (let ((bottom (with-current-buffer session (cooked--bottom-start term))))
      (should (= (window-start term) bottom))
      (cooked-tests--command
       (lambda ()
         (set-window-start term (with-current-buffer session
                                  (save-excursion (goto-char bottom)
                                                  (pos-bol 4))))))
      (should (= (window-start term) bottom))
      (should-not (cooked--window-held-p term)))))

(ert-deftest cooked-a-window-made-shorter-still-follows ()
  "A window that shows less than it did because it was made shorter was not
scrolled by anyone, and goes on following."
  (cooked-tests--with-unselected-terminal
    (cooked-tests--command
     (lambda () (split-window term nil 'below)))
    (should-not (cooked--window-held-p term))))

(ert-deftest cooked-entering-a-window-left-scrolled-up-is-reading ()
  "Selecting a window that was scrolled up while it was not selected is taking
up reading where it was left: the keys are Emacs', and the next drain does not
take the window to the bottom."
  (cooked-tests--with-unselected-terminal
    (cooked-tests--command
     (lambda ()
       (set-window-start term (with-current-buffer session
                                (save-excursion
                                  (goto-char (window-start term))
                                  (pos-bol -2))))))
    (let ((text (cooked-tests--row-text term)))
      (cooked-tests--command (lambda () (select-window term)))
      (with-current-buffer session
        (should cooked-navigate--reading)
        (cooked--send cooked--session "xyz")
        (should (cooked-tests--settle
                 (lambda () (string-match-p "line 63" (cooked-tests--text))))))
      (should (equal (cooked-tests--row-text term) text)))))

(ert-deftest cooked-a-held-window-is-held-for-the-buffer-it-showed ()
  "What a window was scrolled away from is one buffer's bottom.  Showing another
session, it follows that one."
  (cooked-tests--with-unselected-terminal
    (cooked--hold-window term t)
    (should (cooked--window-held-p term))
    (let ((elsewhere (generate-new-buffer "*cooked-tests-elsewhere*")))
      (unwind-protect
          (progn
            (set-window-buffer term elsewhere)
            (should-not (cooked--window-held-p term)))
        (set-window-buffer term session)
        (kill-buffer elsewhere)))))

(ert-deftest cooked-a-window-being-read-keeps-its-place-when-made-shorter ()
  "A window scrolled up and then made shorter -- the minibuffer growing, a
pop-up -- goes on starting where it did: point, which the scroll left on its
last row, is moved onto the last row that still shows, so that redisplay has no
reason to scroll after it."
  (cooked-tests--with-navigable
    (delete-other-windows)
    (let ((cooked-dock nil)
          (window (selected-window)))
      (cooked-tests--keys "M-v")
      (should (cooked--window-held-p window))
      (goto-char (cooked-dock--row
                  window (1- (car (cooked-dock--visible-rows window)))))
      (let ((start (window-start window))
            (below (split-window window (/ (window-total-height window) 2)
                                 'below)))
        (unwind-protect
            (progn
              (cooked--keep-reading-place window)
              (should (= (window-start window) start))
              (should (<= (point)
                          (cooked-dock--row
                           window
                           (1- (car (cooked-dock--visible-rows window)))))))
          (delete-window below))))))

(provide 'cooked-tests-dock)
;;; cooked-tests-dock.el ends here
