;;; cooked-dnd.el --- Dropping files onto a terminal types their names -*- lexical-binding: t; -*-

;;; Commentary:

;; A file dropped onto a terminal window -- Terminal, iTerm, kitty -- does not
;; open the file: its path is typed at the cursor, quoted for a shell, so it
;; can be handed to whatever is running there.  An agent asked about a PDF is
;; given the PDF's path that way.
;;
;; Emacs' own default is to visit a dropped file, which in a terminal buffer
;; replaces the terminal in its window with the file.  This makes a drop onto a
;; cooked buffer do what a terminal does instead, through the buffer-local
;; `dnd-protocol-alist' every drag-and-drop backend consults:
;;
;; - At a prompt Emacs is editing, the names are inserted into the pending
;;   input, where they can be edited before the line is sent.
;; - Anywhere else, they go to the program as a paste -- bracketed if it asked
;;   for that -- exactly as if they had been typed.
;;
;; Several files dropped at once are typed space-separated.  Nothing is sent
;; but the names, followed by a space so the next word can be typed.  Drops of
;; anything that is not a local file are left to Emacs' usual handlers.

;;; Code:

(require 'dnd)
(require 'cooked)
(require 'cooked-keys)

(declare-function cooked--resume-forwarding "cooked-mode" ())

(defcustom cooked-dnd-insert-file-names t
  "Whether a file dropped on a cooked buffer types its name instead of opening it.

Non-nil, the default, is what a terminal does: the file's path, quoted for a
shell, is typed at the input.  nil leaves drops to `dnd-protocol-alist' as it
stands everywhere else, which visits the file."
  :type 'boolean
  :group 'cooked)

(defun cooked-dnd--file-name (url)
  "The local file name URL refers to, or nil if it is not a local file."
  (or (dnd-get-local-file-name url)
      ;; macOS hands over plain paths behind a bare \"file:\" prefix.
      (and (string-match "\\`file:\\(/[^/].*\\)\\'" url)
           (match-string 1 url))))

(defun cooked-dnd--text (files)
  "FILES as a terminal types them: each quoted for a shell, space-separated."
  (concat (mapconcat #'shell-quote-argument files " ") " "))

(defun cooked-dnd-insert-files (urls _action)
  "Type the file names URLS refer to at the terminal's input.
A `dnd-protocol-alist' handler for every URL at once; see the commentary
of cooked-dnd.el."
  (let ((files (delq nil (mapcar #'cooked-dnd--file-name urls))))
    (when files
      (let ((text (cooked-dnd--text files)))
        (cond
         ((not (cooked--live-session))
          (user-error "No live session to give %s to"
                      (if (cdr files) "these files" (car files))))
         ((cooked--input-state-p)
          ;; Into the line being edited, at its end: a drop lands wherever the
          ;; pointer was, which is rarely where the name should go.
          (goto-char (or (cdr (cooked--input-region)) (point)))
          (insert text))
         (t
          (cooked--resume-forwarding)
          (cooked--send-paste text)))
        'copy))))

(put 'cooked-dnd-insert-files 'dnd-multiple-handler t)

(defun cooked-dnd--setup ()
  "Make a drop onto this buffer type file names, as a terminal does."
  (when cooked-dnd-insert-file-names
    (setq-local dnd-protocol-alist
                (cons '("\\`file:" . cooked-dnd-insert-files)
                      (default-value 'dnd-protocol-alist)))))

(add-hook 'cooked-mode-hook #'cooked-dnd--setup)

(provide 'cooked-dnd)
;;; cooked-dnd.el ends here
