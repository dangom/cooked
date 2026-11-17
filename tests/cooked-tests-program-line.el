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
    (should (string-match-p "\n> hello\\'" (cooked-tests--text)))
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
    (should (string-match-p "\n> /mo\\'" (cooked-tests--text)))
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
