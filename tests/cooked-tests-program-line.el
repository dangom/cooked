;;; cooked-tests-program-line.el --- Emacs editing a program's line -*- lexical-binding: t; -*-

;;; Commentary:

;; cooked-program-line.el, against program-line-editor.py: a program that reads
;; a line raw, as an agent's chat does, and opens a menu on `?'.  Driven through
;; `execute-kbd-macro' with the buffer in the selected window, so the keymaps and
;; command hooks are the ones a key press really goes through.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked)
(require 'cooked-mode)
(require 'cooked-program-line)
(require 'cooked-dock)

(declare-function evil-mode "evil" (&optional arg))

(defconst cooked-tests--line-editor
  (expand-file-name "program-line-editor.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The program these tests type at.")

(defmacro cooked-tests--with-line-editor (&rest body)
  "Run BODY in the selected window, on a program reading a line raw.
With `cooked-program-line-editor' set to `emacs', and with `evil-mode' off for
the duration: these are the Emacs keys, and the evil tests leave it on."
  (declare (indent 0))
  `(let ((cooked-program-line-editor 'emacs)
         (evil (bound-and-true-p evil-mode)))
     (when evil (evil-mode -1))
     (unwind-protect
         (cooked-tests--with-session
             (list "python3" "-I" cooked-tests--line-editor)
           (switch-to-buffer (current-buffer))
           (should (cooked-tests--settle
                    (lambda () (string-match-p "line 60\n>" (cooked-tests--text)))))
           (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
           (cooked--refresh-keymap)
           (should cooked-navigate--applies)
           ,@body)
       (when evil (evil-mode 1)))))

(defun cooked-tests--line-keys (keys)
  "Press KEYS, then let the program answer."
  (execute-kbd-macro (kbd keys))
  (cooked-tests--settle (lambda () nil) 0.3))

(defun cooked-tests--sent-p (line)
  "Whether the program has reported LINE submitted, as Python's `repr' spells it."
  (string-search (format "sent: '%s'" line) (cooked-tests--text)))

(ert-deftest cooked-program-line-is-the-programs-by-default ()
  "With the option at its default, every typed key is the program's: Emacs never
takes the line."
  (cooked-tests--with-session
      (list "python3" "-I" cooked-tests--line-editor)
    (switch-to-buffer (current-buffer))
    (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
    (cooked--refresh-keymap)
    (cooked-tests--line-keys "h i")
    (should-not cooked--program-line)
    (should-not (cooked--input-region))
    (should (eq (cooked--policy) 'raw))
    (cooked-tests--line-keys "RET")
    (should (cooked-tests--settle (lambda () (cooked-tests--sent-p "hi"))))))

(ert-deftest cooked-program-line-takes-a-line-the-program-echoes ()
  "Typed into an empty line the program echoes, the characters become Emacs'
line, and the program's own copy is rubbed out: RET submits them once."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "h e l l o")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (should (eq (cooked--policy) 'cooked))
    (should (equal (cooked--pending-input) "hello"))
    (should (string-search "\n> hello" (cooked-tests--text)))
    (cooked-tests--line-keys "RET")
    (should (cooked-tests--settle (lambda () (cooked-tests--sent-p "hello"))))
    (should-not cooked--program-line)
    (should (eq (cooked--policy) 'raw))))

(ert-deftest cooked-program-line-keeps-typing-after-the-echo ()
  "Keys typed once Emacs has the line are edits to it, not keys for the program."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "h")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (cooked-tests--line-keys "e l l o")
    (should (equal (cooked--pending-input) "hello"))
    (cooked-tests--line-keys "RET")
    (should (cooked-tests--settle (lambda () (cooked-tests--sent-p "hello"))))))

(ert-deftest cooked-program-line-is-edited-with-emacs-commands ()
  "Motion, the mark and the region work on the line, and what is sent is the line
as edited."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "o n e SPC t w o SPC t h r e e")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    ;; To the start of the line, over a word, and kill the next one.
    (cooked-tests--line-keys "C-a M-f C-SPC M-f C-w")
    (should (equal (cooked--pending-input) "one three"))
    (cooked-tests--line-keys "C-e SPC C-y")
    (should (equal (cooked--pending-input) "one three  two"))
    (cooked-tests--line-keys "RET")
    (should (cooked-tests--settle
             (lambda () (cooked-tests--sent-p "one three  two"))))))

(ert-deftest cooked-program-line-ends-where-the-line-does ()
  "`C-e' and `C-k' stop at the end of the line being typed, not at the end of
the row, which goes on with the program's own cursor cell."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "o n e SPC t w o")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (should (> (line-end-position) (cdr (cooked--input-region))))
    (cooked-tests--line-keys "C-a C-e")
    (should (= (point) (cdr (cooked--input-region))))
    (cooked-tests--line-keys "C-a M-f C-k")
    (should (equal (cooked--pending-input) "one"))
    (cooked-tests--line-keys "C-a C-k")
    ;; Killed to nothing: the line is the program's again.
    (should-not cooked--program-line)))

;; The line's edges.

(defun cooked-tests--visible (beg end)
  "The text between BEG and END that is not invisible."
  (let ((out ""))
    (dotimes (i (- end beg))
      (let ((pos (+ beg i)))
        (unless (invisible-p pos)
          (setq out (concat out (string (char-after pos)))))))
    out))

(ert-deftest cooked-program-line-hides-what-the-program-draws-after-it ()
  "What the program draws after its cursor for an empty line -- its own cursor,
a suggestion -- is not shown after the line Emacs owns: there is one cursor,
and no text that is not the user's."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "h i")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    ;; The program's line is empty again, so it is drawing its suggestion.
    (should (cooked-tests--settle
             (lambda () (string-search "try me" (cooked-tests--text)))))
    (let ((end (cdr (cooked--input-region))))
      (should (equal (cooked-tests--visible (pos-bol) (pos-eol)) "> hi"))
      (should (invisible-p end)))
    ;; Typed at the end, the text is still the user's and still shown.
    (cooked-tests--line-keys "C-e !")
    (should (equal (cooked--pending-input) "hi!"))
    (should (equal (cooked-tests--visible (pos-bol) (pos-eol)) "> hi!"))))

(ert-deftest cooked-program-line-motion-stops-at-the-line ()
  "Any command finding a line's beginning or end stops at the line Emacs owns,
not only cooked's own: for the length of a command, the prompt before it and
the program's text after it are fields of their own, as comint's prompts are."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "a b c")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (unwind-protect
        (pcase-let ((`(,start . ,end) (cooked--input-region)))
          ;; A package's own line commands, on keys nothing in cooked binds.
          (global-set-key [f5] #'beginning-of-line)
          (global-set-key [f6] #'end-of-line)
          (goto-char (1+ start))
          (execute-kbd-macro [f5])
          (should (= (point) start))
          (execute-kbd-macro [f6])
          (should (= (point) end))
          ;; And between commands, nothing of it is left on the screen.
          (should-not (text-property-not-all (point-min) (point-max) 'field nil)))
      (global-unset-key [f5])
      (global-unset-key [f6]))))

(ert-deftest cooked-program-line-keeps-point-through-a-redraw ()
  "A program redrawing while its line is edited -- a status update, a spinner
-- does not move point: editing at the start of the line stays there."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "a b c")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (cooked-tests--line-keys "C-a")
    (should (= (point) (car (cooked--input-region))))
    (cooked--send cooked--session "\C-b")
    (cooked-tests--settle (lambda () nil) 0.3)
    (should (= (point) (car (cooked--input-region))))
    (cooked-tests--line-keys "x")
    (should (equal (cooked--pending-input) "xabc"))))

(ert-deftest cooked-program-line-keeps-kills-off-the-programs-rows ()
  "\\`C-k' and \\`C-d' at the end of the line leave the program's rows below it
alone."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "a b c")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (let ((below (buffer-substring-no-properties (cdr (cooked--input-region))
                                                 (point-max))))
      (cooked-tests--line-keys "C-e")
      (should-error (execute-kbd-macro (kbd "C-k")))
      (should-error (execute-kbd-macro (kbd "C-d")))
      (should (equal (cooked--pending-input) "abc"))
      (should (equal (buffer-substring-no-properties (cdr (cooked--input-region))
                                                     (point-max))
                     below))
      (should (string-search "status row" below)))))

;; Shells.

(ert-deftest cooked-program-line-leaves-a-shell-its-own-line ()
  "A shell that keeps its own prompt (`cooked-shell-line-editor' `shell') is not
a program whose line Emacs takes: what is typed there stays the shell's, and is
never rubbed out."
  (let ((cooked-shell-line-editor 'shell)
        (cooked-program-line-editor 'emacs))
    (cooked-tests--with-shell ("zsh" :settle (lambda () (eq (cooked--policy) 'prompt)))
      (switch-to-buffer (current-buffer))
      (cooked--refresh-keymap)
      (should cooked-navigate--applies)
      (cooked-tests--line-keys "e c h o SPC h i")
      (cooked-tests--settle (lambda () nil) cooked-program-line-echo-timeout)
      (should-not cooked--program-line)
      (should-not cooked-program-line--probe)
      (should (string-search "echo hi" (cooked-tests--text)))
      (cooked-tests--line-keys "RET")
      (should (cooked-tests--settle
               (lambda () (string-match-p "^hi$" (cooked-tests--text))))))))

(ert-deftest cooked-program-line-leaves-zsh-completion-and-continuations-alone ()
  "With zsh keeping its own line and program lines on, zsh is untouched: its own
TAB completes, and a construct over several lines runs as one."
  (let ((cooked-shell-line-editor 'shell)
        (cooked-program-line-editor 'emacs))
    (cooked-tests--with-shell ("zsh" :settle (lambda () (eq (cooked--policy) 'prompt)))
      (switch-to-buffer (current-buffer))
      (cooked--refresh-keymap)
      ;; zsh's own completion of a command name.
      (cooked-tests--line-keys "u n a m TAB")
      (should (cooked-tests--settle
               (lambda () (string-search "$ uname" (cooked-tests--text)))))
      (cooked-tests--line-keys "C-u")
      ;; A loop typed over three lines, each one zsh's.
      (cooked-tests--line-keys "f o r SPC x SPC i n SPC a a SPC b b ; SPC d o RET")
      (cooked-tests--line-keys "e c h o SPC x - $ x RET")
      (cooked-tests--line-keys "d o n e RET")
      (should (cooked-tests--settle
               (lambda () (and (string-search "\nx-aa" (cooked-tests--text))
                               (string-search "\nx-bb" (cooked-tests--text))))))
      (should-not cooked--program-line)
      (should-not cooked-program-line--probe))))

(ert-deftest cooked-program-line-names-shells-without-marks ()
  "A shell with no integration reads raw keys like any program; it is told
apart by name."
  (cl-letf (((symbol-function 'cooked--foreground-program) (lambda () "zsh")))
    (should (cooked-program-line--shell-p)))
  (cl-letf (((symbol-function 'cooked--foreground-program) (lambda () "bash")))
    (should (cooked-program-line--shell-p)))
  (cl-letf (((symbol-function 'cooked--foreground-program) (lambda () "agent")))
    (should-not (cooked-program-line--shell-p)))
  ;; A remote login is a shell on another machine.
  (cl-letf (((symbol-function 'cooked--foreground-program) (lambda () "ssh")))
    (should (cooked-program-line--shell-p)))
  (cl-letf (((symbol-function 'cooked--foreground-program) (lambda () "python3")))
    (should-not (cooked-program-line--shell-p))))

(ert-deftest cooked-program-line-leaves-a-menu-its-keys ()
  "A program showing a menu does not echo, so its keys stay its own: `1'
answers the menu, and Emacs takes nothing."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "?")
    (should (cooked-tests--settle
             (lambda () (string-search "1. yes" (cooked-tests--text)))))
    (cooked-tests--settle (lambda () nil) cooked-program-line-echo-timeout)
    (should-not cooked--program-line)
    (cooked-tests--line-keys "1")
    (should (cooked-tests--settle
             (lambda () (string-search "chose 1" (cooked-tests--text)))))
    (cooked-tests--settle (lambda () nil) cooked-program-line-echo-timeout)
    (should-not cooked--program-line)
    (should-not (cooked--input-region))))

(ert-deftest cooked-program-line-gives-up-an-emptied-line ()
  "A line rubbed out to nothing is the program's again, so a menu that follows
gets its keys."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "a b")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (cooked-tests--line-keys "DEL DEL")
    (should-not cooked--program-line)
    (should (eq (cooked--policy) 'raw))
    (cooked-tests--line-keys "?")
    (should (cooked-tests--settle
             (lambda () (string-search "1. yes" (cooked-tests--text)))))
    (cooked-tests--line-keys "2")
    (should (cooked-tests--settle
             (lambda () (string-search "chose 2" (cooked-tests--text)))))))

(ert-deftest cooked-program-line-leaves-delegated-lines-to-the-program ()
  "A character from `cooked-program-line-delegate-characters' typed into an empty
line keeps the line the program's until it ends."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "/ m o")
    (cooked-tests--settle (lambda () nil) cooked-program-line-echo-timeout)
    (should-not cooked--program-line)
    (should (string-search "\n> /mo" (cooked-tests--text)))
    (cooked-tests--line-keys "RET")
    (should (cooked-tests--settle (lambda () (cooked-tests--sent-p "/mo"))))
    ;; The line ended, and with it the delegation.
    (cooked-tests--line-keys "x")
    (should (cooked-tests--settle (lambda () cooked--program-line)))))

(ert-deftest cooked-program-line-sends-newlines-as-text ()
  "A line with a newline in it reaches the program as one paste, not as two
Enters."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "a")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (cooked-tests--line-keys "S-<return> b")
    (should (equal (cooked--pending-input) "a\nb"))
    (cooked-tests--line-keys "RET")
    (should (cooked-tests--settle (lambda () (cooked-tests--sent-p "a\\nb"))))
    (should-not (cooked-tests--sent-p "a"))))

(ert-deftest cooked-program-line-withholds-enter-from-a-menu ()
  "A line handed to a program that has put a menu up meanwhile is not taken, and
no Enter follows it: the menu is not answered, and the line goes to the kill
ring."
  (let ((cooked-program-line-accept-timeout 0.5))
    (cooked-tests--with-line-editor
      (cooked-tests--line-keys "a b c")
      (should (cooked-tests--settle (lambda () cooked--program-line)))
      ;; The program puts a menu up on its own; its line is empty, as Emacs left it.
      (cooked--send cooked--session "?")
      (should (cooked-tests--settle
               (lambda () (string-search "1. yes" (cooked-tests--text)))))
      (let ((kill-ring nil))
        (cooked-tests--line-keys "RET")
        (should (cooked-tests--settle
                 (lambda () (null cooked-program-line--submit)) 2))
        (should (equal (car kill-ring) "abc")))
      (should-not (string-search "sent:" (cooked-tests--text)))
      (should-not (string-search "chose" (cooked-tests--text)))
      ;; The menu still takes its own answer.
      (cooked-tests--line-keys "1")
      (should (cooked-tests--settle
               (lambda () (string-search "chose 1" (cooked-tests--text))))))))

(ert-deftest cooked-program-line-passes-escape-and-keeps-the-line ()
  "Escape reaches the program while Emacs owns the line, and the line stays."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "a b")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (cooked-tests--line-keys "<escape>")
    (should (cooked-tests--settle
             (lambda () (string-search "got escape" (cooked-tests--text)))))
    (should cooked--program-line)
    (should (equal (cooked--pending-input) "ab"))))

(ert-deftest cooked-program-line-rescues-a-line-the-program-leaves ()
  "A program that takes the alternate screen while Emacs owns its line ends the
claim, and what was typed goes to the kill ring rather than nowhere."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "k e e p")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (let ((kill-ring nil))
      (cooked--send cooked--session "\C-a")
      (should (cooked-tests--settle (lambda () cooked--alt)))
      (should (cooked-tests--settle (lambda () (not cooked--program-line))))
      (should (equal (car kill-ring) "keep")))
    (should (eq (cooked--policy) 'alt))))

(ert-deftest cooked-program-line-recalls-what-was-sent ()
  "A submitted line is in Emacs' history, and `M-p' recalls it into the next."
  (cooked-tests--with-line-editor
    (cooked-tests--line-keys "f i r s t")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (cooked-tests--line-keys "RET")
    (should (cooked-tests--settle (lambda () (cooked-tests--sent-p "first"))))
    (cooked-tests--line-keys "x")
    (should (cooked-tests--settle (lambda () cooked--program-line)))
    (cooked-tests--line-keys "M-p")
    (should (equal (cooked--pending-input) "first"))))

(ert-deftest cooked-program-line-is-typed-in-the-dock-while-reading ()
  "Reading back docks the program's input as it does for any program, a line
Emacs owns included: typing goes on in the dock, the window being read stays
where it is, and RET from the dock submits and follows again."
  (cooked-tests--with-line-editor
    (delete-other-windows)
    (let ((cooked-dock t)
          (cooked-dock-context-rows 1)
          (cooked-dock-max-fraction 0.5))
      (cooked-tests--line-keys "a b")
      (should (cooked-tests--settle (lambda () cooked--program-line)))
      (let ((main (selected-window)))
        (cooked-tests--line-keys "M-v")
        (should cooked-navigate--reading)
        (let ((dock (window-parameter main 'cooked-dock))
              (start (window-start main)))
          (should (window-live-p dock))
          (cooked-tests--line-keys "c")
          (should (eq (selected-window) dock))
          (should (equal (cooked--pending-input) "abc"))
          (should (= (window-start main) start))
          (cooked-tests--line-keys "RET")
          (should (cooked-tests--settle (lambda () (cooked-tests--sent-p "abc"))))
          (should-not (window-parameter main 'cooked-dock)))))))

(provide 'cooked-tests-program-line)
;;; cooked-tests-program-line.el ends here
