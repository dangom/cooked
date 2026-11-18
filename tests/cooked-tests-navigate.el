;;; cooked-tests-navigate.el --- Navigation over a running program, and closing -*- lexical-binding: t; -*-

;;; Commentary:

;; cooked-navigate.el, the foreground program's
;; name, and `cooked-close'.  Driven through `execute-kbd-macro' with the buffer
;; in the selected window, so that the keymaps and the command hooks are the
;; ones a key press really goes through.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked)
(require 'cooked-mode)
(require 'cooked-navigate)

(defconst cooked-tests--echo-program
  (concat "import os, sys, tty\n"
          "tty.setraw(0)\n"
          "out = sys.stdout\n"
          "for i in range(1, 61):\n"
          "    out.write('line %d\\r\\n' % i)\n"
          "out.write('> ')\n"
          "out.flush()\n"
          "while True:\n"
          "    b = os.read(0, 64)\n"
          "    if not b:\n"
          "        break\n"
          "    if b == b'A':\n"
          "        out.write('\\x1b[?1049h')\n"
          "    if b == b'M':\n"
          "        out.write('\\x1b[?1000h\\x1b[?1006h')\n"
          "    out.write(repr(b) + ' ')\n"
          "    out.flush()\n")
  "A program that owns the keyboard on the main screen and says what it is sent.

Nothing like a real agent but the shape: output scrolling up the main screen, and
an input on the cursor's row.  Sent an `A' it takes the alternate screen, and
sent an `M' it asks for mouse reports, the two ways a program says it will
look after its own scrolling.")

(defmacro cooked-tests--with-navigable (&rest body)
  "Run BODY in the selected window, on a program that echoes its input.
With `cooked-navigable-programs' at its default: nothing names this program."
  (declare (indent 0))
  `(progn
     (cooked-tests--with-session
         (list "python3" "-I" "-c" cooked-tests--echo-program)
       (switch-to-buffer (current-buffer))
       (should (cooked-tests--settle
                (lambda () (string-match-p "line 60\n>" (cooked-tests--text)))))
       (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
       (cooked--refresh-keymap)
       (should cooked-navigate--applies)
       ,@body)))

(defun cooked-tests--keys (keys)
  "Press KEYS, then let the child answer."
  (execute-kbd-macro (kbd keys))
  (cooked-tests--settle (lambda () nil) 0.3))

(ert-deftest cooked-navigate-keys-go-to-the-program-at-its-input ()
  "At the input every key but `cooked-navigation-keys' is the program's, as in a
terminal: control keys included."
  (cooked-tests--with-navigable
    (should-not cooked-navigate--reading)
    (cooked-tests--keys "a")
    (should (string-match-p "b'a'" (cooked-tests--text)))
    (cooked-tests--keys "C-t")
    (should (string-match-p (regexp-quote "b'\\x14'") (cooked-tests--text)))
    (should-not cooked-navigate--reading)))

(ert-deftest cooked-navigate-isearch-from-the-input-searches-the-output ()
  "`C-s' and `C-r' at the input are isearch, as everywhere in Emacs: the search
lands in the output, which is then being read, and nothing reaches the program."
  (cooked-tests--with-navigable
    (cooked-tests--keys "C-r line SPC 42 RET")
    (should cooked-navigate--reading)
    (should (string-match-p "line 42" (buffer-substring (line-beginning-position)
                                                       (line-end-position))))
    (should-not (string-match-p (regexp-quote "b'\\x12'") (cooked-tests--text)))
    (should-not (string-match-p "b'l'" (cooked-tests--text)))
    (cooked-tests--keys "M-<")
    (cooked-tests--keys "C-s line SPC 7 RET")
    (should (string-match-p "line 7" (buffer-substring (line-beginning-position)
                                                      (line-end-position))))))

(ert-deftest cooked-navigate-emacs-motion-leaves-the-input-to-read ()
  "\\`M-<' is Emacs' even at the input, and leaves it: the buffer is then an
ordinary read-only one, `C-n' is line motion, and nothing reaches the program."
  (cooked-tests--with-navigable
    (cooked-tests--keys "M-<")
    (should (= (point) (point-min)))
    (should cooked-navigate--reading)
    (should (eq cooked--input-mode 'still))
    (should buffer-read-only)
    (cooked-tests--keys "C-n")
    (should (= (line-number-at-pos) 2))
    (should-not (string-match-p "b'" (cooked-tests--text)))))

(ert-deftest cooked-navigate-line-motion-at-the-input-is-emacs ()
  "`C-p' at the input is line motion, as at a shell prompt: it steps up into the
output, and nothing reaches the program."
  (cooked-tests--with-navigable
    (cooked-tests--keys "C-p")
    (should cooked-navigate--reading)
    (should (string-match-p "\\`line 60" (buffer-substring (line-beginning-position)
                                                           (line-end-position))))
    (should-not (string-match-p (regexp-quote "b'\\x10'") (cooked-tests--text)))
    (cooked-tests--keys "C-n")
    (should-not cooked-navigate--reading)
    (should (= (point) (cooked--cursor-position)))))

(ert-deftest cooked-navigate-history-keys-send-up-and-down ()
  "`M-p'/`M-n' are the input history, as at a shell prompt: the program is sent
Up and Down, from the input and from the output alike."
  (cooked-tests--with-navigable
    (cooked-tests--keys "M-p")
    (should (string-match-p (regexp-quote "b'\\x1b[A'") (cooked-tests--text)))
    (cooked-tests--keys "M-n")
    (should (string-match-p (regexp-quote "b'\\x1b[B'") (cooked-tests--text)))
    (should-not cooked-navigate--reading)
    (cooked-tests--keys "M-<")
    (should cooked-navigate--reading)
    (cooked-tests--keys "M-p")
    (should-not cooked-navigate--reading)
    (should (= (point) (cooked--cursor-position)))
    ;; Two Ups now: the one from the input, and this one.
    (should (= 3 (length (split-string (cooked-tests--text)
                                       (regexp-quote "b'\\x1b[A'")))))))

(ert-deftest cooked-navigate-typing-while-reading-goes-back-to-the-input ()
  "A character typed while reading lands in the program's input, like comint."
  (cooked-tests--with-navigable
    (cooked-tests--keys "M-<")
    (should cooked-navigate--reading)
    (cooked-tests--keys "z")
    (should (string-match-p "b'z'" (cooked-tests--text)))
    (should-not cooked-navigate--reading)
    (should-not buffer-read-only)
    (should (= (point) (cooked--cursor-position)))))

(ert-deftest cooked-navigate-return-while-reading-sends-nothing ()
  "RET while reading goes back to the input and does not submit anything."
  (cooked-tests--with-navigable
    (cooked-tests--keys "M-<")
    (cooked-tests--keys "RET")
    (should-not cooked-navigate--reading)
    (should (= (point) (cooked--cursor-position)))
    (should-not (string-match-p (regexp-quote "b'\\r'") (cooked-tests--text)))))

(ert-deftest cooked-navigate-moving-onto-the-input-row-goes-back ()
  "Line motion from the output onto the input row hands the keys back."
  (cooked-tests--with-navigable
    (cooked-tests--keys "M-<")
    (cooked-tests--keys "C-s line SPC 60 RET")
    (should cooked-navigate--reading)
    (cooked-tests--keys "C-n")
    (should-not cooked-navigate--reading)
    (should (= (point) (cooked--cursor-position)))))

(ert-deftest cooked-navigate-output-does-not-move-point-while-reading ()
  "The program keeps drawing while its output is read, and point stays put."
  (cooked-tests--with-navigable
    (cooked-tests--keys "M-<")
    (cooked-tests--keys "C-n C-n")
    (let ((line (line-number-at-pos)))
      ;; Output the user did not type: the echo of a key sent from Lisp.
      (cooked--send cooked--session "q")
      (should (cooked-tests--settle
               (lambda () (string-match-p "b'q'" (cooked-tests--text)))))
      (should (= (line-number-at-pos) line))
      (should cooked-navigate--reading))))

(ert-deftest cooked-navigate-leaves-unnamed-programs-alone ()
  "A list in `cooked-navigable-programs' that does not name the program leaves
every key with it."
  (let ((cooked-navigable-programs '("\\`no-such-program\\'")))
    (cooked-tests--with-session
        (list "python3" "-I" "-c" cooked-tests--echo-program)
      (switch-to-buffer (current-buffer))
      (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
      (cooked--refresh-keymap)
      (should-not cooked-navigate--applies)
      (should-not (eq (key-binding (kbd "M-<")) #'beginning-of-buffer))
      (let ((before (point)))
        (cooked-tests--keys "M-<")
        (should (= (point) before)))
      (should-not cooked-navigate--reading))))

(ert-deftest cooked-navigate-list-matches-the-command-line ()
  "A program run by an interpreter is named by its command line."
  (let ((cooked-navigable-programs '("tty\\.setraw")))
    (cooked-tests--with-session
        (list "python3" "-I" "-c" cooked-tests--echo-program)
      (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
      (cooked--refresh-keymap)
      (should cooked-navigate--applies))))

(ert-deftest cooked-navigate-turns-off-on-the-alternate-screen ()
  "A program that takes the alternate screen while its output is being read
gets every key back, and the buffer is not left read-only."
  (cooked-tests--with-navigable
    (cooked-tests--keys "M-<")
    (should cooked-navigate--reading)
    (should buffer-read-only)
    (cooked--send cooked--session "A")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should-not cooked-navigate--applies)
    (should-not cooked-navigate--reading)
    (should-not buffer-read-only)
    (should-not (eq cooked--input-mode 'still))
    (should-not (eq (key-binding (kbd "M-<")) #'beginning-of-buffer))
    (cooked-tests--keys "x")
    (should (cooked-tests--settle
             (lambda () (string-match-p "b'x'" (cooked-tests--text)))))))

(ert-deftest cooked-navigate-turns-off-when-the-program-asks-for-the-mouse ()
  "Mouse reports mean the program scrolls itself: its keys are its own again."
  (cooked-tests--with-navigable
    (cooked-tests--keys "M-<")
    (should cooked-navigate--reading)
    (cooked--send cooked--session "M")
    (should (cooked-tests--settle
             (lambda () (cooked-mouse-state-enabled cooked--mouse-state))))
    (should-not cooked-navigate--applies)
    (should-not cooked-navigate--reading)
    (should-not buffer-read-only)))

(ert-deftest cooked-navigate-is-off-at-a-marked-shell-prompt ()
  "A shell editing its own marked prompt is Emacs' line, not a program's."
  (cooked-tests--with-zsh
    (should (cooked-tests--settle (lambda () (cooked--input-state-p))))
    (cooked--refresh-keymap)
    (should-not cooked-navigate--applies)))

(ert-deftest cooked-shell-line-editor-shell-gives-zsh-its-line ()
  "With `cooked-shell-line-editor' set to `shell', a marked prompt is the shell's:
keys go to zsh's line editor (so its plugins run), Emacs does not lift the line
into an input region, and the output around it reads like any program's."
  (let ((cooked-shell-line-editor 'shell))
    (cooked-tests--with-shell ("zsh" :settle (lambda () (eq (cooked--policy) 'prompt)))
      (switch-to-buffer (current-buffer))
      (should-not (cooked--input-state-p))
      (cooked--refresh-keymap)
      (should cooked-navigate--applies)
      ;; Typed keys reach zsh, which echoes them in its own line.
      (cooked-tests--keys "e c h o SPC h i")
      (should (cooked-tests--settle
               (lambda () (string-match-p "echo hi" (cooked-tests--text)))))
      (cooked-tests--keys "RET")
      (should (cooked-tests--settle
               (lambda () (string-match-p "^hi$" (cooked-tests--text))))))))

(ert-deftest cooked-program-name-is-argv-zero ()
  "argv[0]'s basename: what was typed, or what a wrapper exec'd."
  ;; The native installer: a versioned file behind an `agent' symlink.
  (should (equal (cooked--program-name '((comm . "2.1.0")
                                         (args . "agent --resume abc")))
                 "agent"))
  (should (equal (cooked--program-name '((comm . "2.1.0")
                                         (args . "/home/u/.local/bin/agent")))
                 "agent"))
  ;; Run by an interpreter: the interpreter is the name ...
  (should (equal (cooked--program-name
                  '((comm . "node")
                    (args . "node /usr/lib/node_modules/some-agent/cli.js")))
                 "node"))
  (should (equal (cooked--program-name '((comm . "zsh") (args . "-zsh"))) "zsh"))
  (should (equal (cooked--program-name '((comm . "cat"))) "cat")))

(ert-deftest cooked-navigate-names-an-interpreted-program-by-command-line ()
  "... and the command line is what a list entry can name it by."
  (let ((cooked-navigable-programs '("agent")))
    (cl-letf (((symbol-function 'cooked--foreground-attributes)
               (lambda ()
                 '("node" . "node /usr/lib/node_modules/some-agent/cli.js"))))
      (should (cooked-navigate--program-p))))
  (let ((cooked-navigable-programs '("agent")))
    (cl-letf (((symbol-function 'cooked--foreground-attributes)
               (lambda () '("node" . "node server.js"))))
      (should-not (cooked-navigate--program-p)))))

(ert-deftest cooked-buffer-closes-on-a-clean-exit-by-default ()
  "The shipped default, which the suite itself overrides to read transcripts."
  (should (eq (eval (car (get 'cooked-kill-buffer-on-exit 'standard-value)) t)
              'on-success)))

(ert-deftest cooked-close-hangs-up-and-takes-the-buffer ()
  "`cooked-close' hangs up on the child, waits for it, and kills the buffer."
  (let* ((flag (make-temp-file "cooked-close"))
         (buffer (generate-new-buffer "*cooked-close*"))
         (cooked-close-grace 3))
    (delete-file flag)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (cooked-mode)
            (cooked--start
             (list "/bin/sh" "-c"
                   (format "trap 'echo hup > %s; exit 0' HUP; while :; do sleep 0.05; done"
                           (shell-quote-argument flag))))
            (cooked--refresh-keymap)
            (cooked-tests--settle (lambda () nil) 0.3)
            (cooked-close))
          (let ((deadline (+ (float-time) 5)))
            (while (and (buffer-live-p buffer) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should-not (buffer-live-p buffer))
          (should (file-exists-p flag)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer))
      (ignore-errors (delete-file flag)))))

(ert-deftest cooked-exit-puts-away-a-window-made-for-the-buffer ()
  "A buffer killed on exit takes with it the window that was made to show it."
  (let ((cooked-kill-buffer-on-exit t)
        (buffer (generate-new-buffer "*cooked-exit-window*")))
    (delete-other-windows)
    (unwind-protect
        (let (window)
          (with-current-buffer buffer
            (cooked-mode)
            (cooked--start '("/bin/sh" "-c" "sleep 0.3; exit 0")))
          (setq window (display-buffer buffer '(display-buffer-pop-up-window)))
          (should (window-live-p window))
          (let ((deadline (+ (float-time) 5)))
            (while (and (buffer-live-p buffer) (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should-not (buffer-live-p buffer))
          (should-not (window-live-p window)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

(ert-deftest cooked-navigate-yank-at-the-input-pastes-the-kill-ring ()
  "`C-y' at the input pastes Emacs' kill ring, as `yank' does everywhere else,
rather than handing the program a control character."
  (cooked-tests--with-navigable
    (let ((kill-ring nil) (interprogram-paste-function nil))
      (kill-new "hello")
      (cooked-tests--keys "C-y"))
    (should (string-match-p "b'hello'" (cooked-tests--text)))
    (should-not (string-match-p (regexp-quote "b'\\x19'") (cooked-tests--text)))))

(ert-deftest cooked-dnd-a-dropped-file-types-its-name ()
  "A file dropped onto the buffer is not visited: its quoted path is typed at the
program's input, the way a terminal does it."
  (cooked-tests--with-navigable
    (should (eq (cdr (assoc "\\`file:" dnd-protocol-alist)) 'cooked-dnd-insert-files))
    (let ((buffer (current-buffer)))
      (dnd-handle-multiple-urls (selected-window) (list "file:/tmp/paper.pdf") 'copy)
      (should (eq (window-buffer (selected-window)) buffer)))
    (should (cooked-tests--settle
             (lambda () (string-match-p "/tmp/paper\\.pdf " (cooked-tests--text)))))))

(ert-deftest cooked-dnd-file-names-are-quoted-and-joined ()
  "Several files at once, space-separated and quoted for a shell."
  (should (equal (cooked-dnd--text '("/tmp/a.pdf" "/tmp/my paper.pdf"))
                 (concat "/tmp/a.pdf " (shell-quote-argument "/tmp/my paper.pdf") " ")))
  (should (equal (cooked-dnd--file-name "file:/Users/u/x.pdf") "/Users/u/x.pdf"))
  (should (equal (cooked-dnd--file-name "file:///tmp/a%20b.pdf") "/tmp/a b.pdf"))
  (should-not (cooked-dnd--file-name "https://example.com/x.pdf")))

(ert-deftest cooked-dnd-at-a-shell-prompt-edits-the-pending-line ()
  "At a prompt Emacs is editing, a drop goes into the pending input, unsent."
  (cooked-tests--with-zsh
    (should (cooked-tests--settle (lambda () (cooked--input-state-p))))
    (cooked-dnd-insert-files (list "file:/tmp/paper.pdf") 'copy)
    (should (equal (cooked--pending-input) "/tmp/paper.pdf "))))

(ert-deftest cooked-scroll-settings-come-back-after-another-package-clobbers-them ()
  "Regression: a scrolling package `setq'ing its saved global back from a timer
in a cooked buffer left it at `scroll-conservatively' 10, and redisplay then
recentred the window on every burst of output.  The next drain restores it."
  (cooked-tests--with-navigable
    (setq-local scroll-conservatively 10
                scroll-margin 3)
    (cooked--send cooked--session "q")
    (should (cooked-tests--settle
             (lambda () (string-match-p "b'q'" (cooked-tests--text)))))
    (should (cooked-tests--settle (lambda () (eql scroll-conservatively 101))))
    (should (eql scroll-margin 0))))

(ert-deftest cooked-a-click-reaches-emacs-while-a-program-owns-the-keyboard ()
  "Regression: with the program reading every key, the forwarding map binds the
mouse too, and the fallback's \"what would Emacs do\" lookup found cooked's own
handler there and did nothing -- a click placed no point and a drag selected
nothing.  The lookup now answers with Emacs' own bindings."
  (cooked-tests--with-navigable
    (should (eq (lookup-key (current-local-map) [mouse-1]) #'cooked-mouse-event))
    (should (memq (cooked--mouse-fallback-command [down-mouse-1] nil)
                  '(mouse-drag-region)))
    (should (eq (cooked--mouse-fallback-command [mouse-1] nil) #'mouse-set-point))
    ;; And the lookup leaves the buffer's own map as it found it.
    (should (eq (lookup-key (current-local-map) [mouse-1]) #'cooked-mouse-event))))

(ert-deftest cooked-a-selection-survives-output-that-does-not-touch-it ()
  "A selection on the live screen is dropped only when its own text is redrawn:
output on another row -- an agent's spinner, the next line of its reply --
leaves it alone, so a region dragged over a program's output can be copied
while the program keeps working."
  (cooked-tests--with-navigable
    (let ((beg (save-excursion (goto-char (point-min))
                               (re-search-forward "^line 58$") (match-beginning 0)))
          (end (save-excursion (goto-char (point-min))
                               (re-search-forward "^line 59$") (match-end 0))))
      (should (>= beg (cooked--screen-start-position)))
      ;; Leave the input first, as the click or drag that makes a selection does.
      (cooked-tests--keys "M-<")
      (should cooked-navigate--reading)
      (goto-char end)
      (set-mark beg)
      (activate-mark)
      (cooked--send cooked--session "q")
      (should (cooked-tests--settle
               (lambda () (string-match-p "b'q'" (cooked-tests--text)))))
      (should mark-active)
      (should (equal (buffer-substring-no-properties (region-beginning) (region-end))
                     "line 58\nline 59")))))

(ert-deftest cooked-a-scroll-past-the-bottom-is-clamped-while-following ()
  "Regression: a wheel notch past the end scrolled a following window down a
line and the next drain pinned it back up, so the window jittered for as long
as the wheel turned.  The overshoot is now undone in the same command."
  (cooked-tests--with-navigable
    (let* ((w (selected-window))
           (bottom (cooked--bottom-start w)))
      (should-not cooked-navigate--reading)
      (set-window-start w (save-excursion (goto-char bottom) (forward-line 2) (point)) t)
      (cooked--clamp-overscroll)
      (should (= (window-start w) bottom))
      ;; While reading, the window is the user's: nothing is clamped.
      (cooked-tests--keys "M-<")
      (should cooked-navigate--reading)
      (set-window-start w (point-min) t)
      (cooked--clamp-overscroll)
      (should (= (window-start w) (point-min))))))

;; What a command is judged against.

(ert-deftest cooked-navigate-judges-a-command-by-what-it-found ()
  "Whether a command left the input is decided against the window as that
command found it.  A command that began in another buffer and ended in this
one -- `other-window' -- found nothing here, and is not compared with what the
last command to run in this buffer left behind: against that, a screen that had
grown shorter meanwhile read as a window scrolled up, and the keys were taken
from the program."
  (cooked-tests--with-navigable
    (let ((window (selected-window)))
      ;; What some earlier command found: the window further down than it is.
      (setq cooked-navigate--before nil)
      (cooked-navigate--pre-command)
      (should (eq (car cooked-navigate--before) window))
      (cooked-navigate--post-command)
      ;; Used up by the command it was taken for.
      (should-not cooked-navigate--before)
      (should-not cooked-navigate--reading)
      ;; The screen moves under the window, and a command arrives from
      ;; elsewhere: nothing was found here before it, so nothing is concluded.
      (set-window-start window (point-min))
      (let ((this-command 'other-window)
            (last-command-event ?o))
        (cooked-navigate--post-command))
      (should-not cooked-navigate--reading)
      (should (eq (key-binding (kbd "RET")) #'cooked-send-key)))))

(provide 'cooked-tests-navigate)
;;; cooked-tests-navigate.el ends here
