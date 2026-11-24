;;; cooked-run.el --- Follow the commands a program runs out of sight -*- lexical-binding: t; -*-

;;; Commentary:

;; A program on a terminal may run commands whose output never reaches the
;; terminal: it reads them through a pipe and shows a summary of what came, or
;; nothing until they are done.  When it runs them through `cooked-host run'
;; (src/run.rs) in a hosted session, each is a *run*: what it prints is kept,
;; as it comes, in a file under the session's name.  This file is the Emacs
;; half: reading those, and following one in a buffer while it is still going.
;;
;;   cooked-run-latest   follow the newest run of this buffer's session
;;   cooked-run-select   choose one of them
;;
;; From Lisp, `cooked-runs' lists a session's runs and `cooked-run-buffer'
;; gives the buffer following one; `cooked-run-show' shows it, in a pop-up
;; where cooked-popup.el is loaded.  In that buffer `k' interrupts the command
;; and `g' reads what is new at once.
;;
;; Optional, and nothing requires it.  Nothing is sent to the program and
;; nothing it prints is acted on: the output is text, shown with its colours,
;; and every other control sequence in it is dropped.  The one thing that
;; reaches the command is the signal `k' sends, and that is the user's.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)
(require 'comint)

(declare-function cooked-popup-buffer "cooked-popup")
(declare-function cooked-popup-mode "cooked-popup")
(defvar cooked-host-name)

(defgroup cooked-run nil
  "Following the commands a program in a hosted session runs."
  :group 'cooked)

(defcustom cooked-run-directory nil
  "Where runs are kept, or nil for where `cooked-host run' keeps them.
That is $COOKED_RUN_DIR, by default ~/.local/state/cooked/runs: a directory
to a session."
  :type '(choice (const :tag "Where cooked-host keeps them" nil) directory))

(defcustom cooked-run-interval 0.25
  "Seconds between looks at a run that is being followed."
  :type 'number)

(define-obsolete-function-alias 'cooked-run--directory #'cooked-runs-directory "1.0.0")

(defun cooked-runs-directory ()
  "The directory runs are kept in."
  (file-name-as-directory
   (or cooked-run-directory
       (let ((dir (getenv "COOKED_RUN_DIR")))
         (and dir (not (string-empty-p dir)) dir))
       (expand-file-name "cooked/runs"
                         (let ((state (getenv "XDG_STATE_HOME")))
                           (if (and state (not (string-empty-p state)))
                               state
                             "~/.local/state"))))))

;;;; Runs

(defun cooked-run--read (file)
  "The run described by FILE, a plist, or nil if FILE does not describe one.
:id, :session, :pid, :cwd, :argv, :label, :key and :started; :ended with
:exit or :signal once it has; :output, the file of what it printed."
  (when-let* ((meta (ignore-errors
                      (with-temp-buffer
                        (insert-file-contents file)
                        (json-parse-buffer :object-type 'alist :array-type 'list
                                           :null-object nil :false-object nil))))
              ((consp meta))
              (id (alist-get 'id meta))
              ((stringp id)))
    (list :id id
          :session (alist-get 'session meta)
          :pid (alist-get 'pid meta)
          :cwd (alist-get 'cwd meta)
          :argv (alist-get 'argv meta)
          :label (alist-get 'label meta)
          :key (alist-get 'key meta)
          :started (alist-get 'started meta)
          :ended (alist-get 'ended meta)
          :exit (alist-get 'exit meta)
          :signal (alist-get 'signal meta)
          :meta file
          :output (concat (file-name-sans-extension file) ".out"))))

(defun cooked-run--session (&optional session)
  "SESSION, or the session of the current buffer, if it can name a directory."
  (let ((name (or session (bound-and-true-p cooked-host-name))))
    (and (stringp name)
         (string-match-p "\\`[[:alnum:]_-][[:alnum:]._-]*\\'" name)
         name)))

;;;###autoload
(defun cooked-runs (&optional session)
  "The runs of SESSION, by default the current buffer's, oldest first.
Each a plist; see `cooked-run--read'."
  (when-let* ((name (cooked-run--session session))
              (dir (expand-file-name name (cooked-runs-directory)))
              ((file-directory-p dir)))
    ;; A run's name begins with when it started, so their order is their age.
    (delq nil (mapcar #'cooked-run--read
                      (directory-files dir t "\\`[0-9].*\\.json\\'")))))

(defun cooked-run-name (run)
  "What RUN is called: its label, or the command it ran."
  (or (plist-get run :label)
      (string-join (plist-get run :argv) " ")))

(defun cooked-run-live-p (run)
  "Whether RUN's command is still going.
A run with no end whose process is gone was cut short with whatever ran it."
  (and (not (plist-get run :ended))
       (integerp (plist-get run :pid))
       (process-attributes (plist-get run :pid))
       t))

(defun cooked-run-status (run)
  "A word for how RUN is going, or how it went."
  (cond ((plist-get run :exit) (format "exit %s" (plist-get run :exit)))
        ((plist-get run :signal) (format "signal %s" (plist-get run :signal)))
        ((plist-get run :ended) "ended")
        ((cooked-run-live-p run) "running")
        (t "cut short")))

;;;; Following one

(defvar-local cooked-run--run nil "The run this buffer follows.")
(defvar-local cooked-run--offset 0 "How many bytes of its output are shown.")
(defvar-local cooked-run--timer nil "The timer that looks for more of it.")

(defvar cooked-run-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "k") #'cooked-run-interrupt)
    (define-key map (kbd "g") #'cooked-run-refresh)
    map)
  "Keys of a buffer following a run.")

(define-derived-mode cooked-run-mode special-mode "Run"
  "Following what a command prints, as it prints it.
\\{cooked-run-mode-map}"
  (setq-local font-lock-defaults nil)
  (font-lock-mode -1)
  (setq truncate-lines nil)
  (setq-local ansi-color-context-region nil)
  ;; As text properties, which a copy takes with it, and as `face': this
  ;; buffer has no font lock for `font-lock-face' to be shown by.
  (setq-local ansi-color-apply-face-function
              (lambda (beg end face)
                (when face (put-text-property beg end 'face face))))
  (add-hook 'kill-buffer-hook #'cooked-run--stop nil t))

(defun cooked-run--stop ()
  "Stop looking for more of this buffer's run."
  (when cooked-run--timer (cancel-timer cooked-run--timer))
  (setq cooked-run--timer nil))

(defun cooked-run--header (run)
  "The header line of a buffer following RUN."
  (let* ((started (plist-get run :started))
         (seconds (and (numberp started)
                       (- (or (plist-get run :ended) (float-time)) started))))
    (string-join
     (delq nil (list (cooked-run-status run)
                     (and seconds (format "%.1fs" seconds))
                     (and (stringp (plist-get run :cwd))
                          (abbreviate-file-name (plist-get run :cwd)))
                     (if (cooked-run-live-p run) "k interrupt" nil)))
     "  ·  ")))

(defconst cooked-run--control-regexp
  (concat "\e\\[[0-?]*[ -/]*[@-~]"          ; a CSI sequence that is not a colour
          "\\|\e[]P^_][^\a\e]*\\(?:\a\\|\e\\\\\\)?" ; OSC, DCS and their kin
          "\\|\e[@-Z\\\\^_]"                 ; a two-character escape
          "\\|[\0-\b\v\f\016-\032\034-\037]") ; and stray controls
  "What is left of a terminal's language once the colours have been taken.")

(defun cooked-run--insert (bytes)
  "Insert BYTES of output at the end of the buffer, as text with its colours."
  (let ((inhibit-read-only t)
        (start (point-max)))
    (save-excursion
      (goto-char start)
      (insert (decode-coding-string bytes 'utf-8))
      (let ((end (point-marker)))
        ;; A line drawn over and over, as a progress bar is, shows as its last.
        (comint-carriage-motion start end)
        (ansi-color-apply-on-region start end)
        ;; Nothing else a terminal would have obeyed is obeyed, or shown.
        (goto-char start)
        (while (re-search-forward cooked-run--control-regexp end t)
          (replace-match "" t t))
        (set-marker end nil)))))

(defun cooked-run--poll (buffer)
  "Show what BUFFER's run has printed since the last look, and how it stands."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((run (or (and (not (plist-get cooked-run--run :ended))
                           (cooked-run--read (plist-get cooked-run--run :meta)))
                      cooked-run--run))
             (live (cooked-run-live-p run))
             (file (plist-get run :output))
             (size (or (file-attribute-size (file-attributes file)) 0))
             (following (mapcar (lambda (window)
                                  (and (>= (window-point window) (point-max)) window))
                                (get-buffer-window-list buffer nil t))))
        (setq cooked-run--run run)
        (when (> size cooked-run--offset)
          (let* ((from cooked-run--offset) ; this buffer's, not the one read into
                 (bytes (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally file nil from size)
                          (buffer-string)))
                 ;; While it is going, only whole lines: the last may be half a
                 ;; character, or half of a sequence that colours the rest.
                 (whole (if live
                            (let ((at (cl-position-if (lambda (c) (memq c '(?\n ?\r)))
                                                      bytes :from-end t)))
                              (cond (at (1+ at))
                                    ((> (length bytes) 4096) (length bytes))
                                    (t 0)))
                          (length bytes))))
            (when (> whole 0)
              (cooked-run--insert (substring bytes 0 whole))
              (cl-incf cooked-run--offset whole)
              (dolist (window (delq nil following))
                (set-window-point window (point-max))))))
        (setq header-line-format
              (concat (cooked-run--header run)
                      (if (bound-and-true-p cooked-popup-mode) "  ·  q close" "")))
        (unless (or live (> size cooked-run--offset))
          (cooked-run--stop))))))

(defun cooked-run-refresh ()
  "Read what this buffer's run has printed since the last look."
  (interactive)
  (cooked-run--poll (current-buffer)))

;;;###autoload
(defun cooked-run-buffer (run)
  "The buffer following RUN, made if there is none.
It shows what RUN's command has printed and, while the command is going,
what it prints as it prints it."
  (let* ((id (plist-get run :id))
         (buffer (or (cl-find-if (lambda (buffer)
                                   (equal (plist-get (buffer-local-value 'cooked-run--run buffer)
                                                     :id)
                                          id))
                                 (buffer-list))
                     (generate-new-buffer
                      (format "*run: %s*"
                              (truncate-string-to-width
                               (car (split-string (cooked-run-name run) "\n")) 40 nil nil t))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cooked-run-mode)
        (cooked-run-mode)
        (setq cooked-run--run run
              cooked-run--offset 0)
        (when (stringp (plist-get run :cwd))
          (setq default-directory (file-name-as-directory (plist-get run :cwd))))
        (let ((inhibit-read-only t))
          (insert (propertize (concat "$ " (cooked-run-name run) "\n\n") 'face 'shadow))))
      (cooked-run--poll buffer)
      (when (and (cooked-run-live-p cooked-run--run) (not cooked-run--timer))
        (setq cooked-run--timer
              (run-with-timer cooked-run-interval cooked-run-interval
                              #'cooked-run--poll buffer))))
    buffer))

(defun cooked-run--descendants (pid)
  "PID and every process under it, deepest last."
  (let ((parents (mapcar (lambda (p) (cons p (alist-get 'ppid (process-attributes p))))
                         (list-system-processes)))
        (found (list pid))
        (grew t))
    (while grew
      (setq grew nil)
      (dolist (pair parents)
        (when (and (memq (cdr pair) found) (not (memq (car pair) found)))
          (setq found (append found (list (car pair))) grew t))))
    found))

(defun cooked-run-interrupt ()
  "Interrupt the command this buffer follows, and whatever it started.
As `C-c' at a terminal would: it is asked to stop, not made to."
  (interactive)
  (let ((run cooked-run--run))
    (unless (cooked-run-live-p run)
      (user-error "It is not running"))
    (when (yes-or-no-p (format "Interrupt `%s'? " (cooked-run-name run)))
      (dolist (pid (reverse (cooked-run--descendants (plist-get run :pid))))
        (ignore-errors (signal-process pid 'SIGINT)))
      (cooked-run--poll (current-buffer)))))

;;;###autoload
(defun cooked-run-show (run)
  "Show the buffer following RUN: in a pop-up where there are those, else a window.
Returns the buffer."
  (let ((buffer (cooked-run-buffer run)))
    (if (not (require 'cooked-popup nil t))
        (pop-to-buffer buffer)
      (with-current-buffer buffer
        (cooked-popup-mode 1)
        (goto-char (point-max)))
      (cooked-popup-buffer buffer))
    (cooked-run--poll buffer)
    buffer))

;;;###autoload
(defun cooked-run-latest ()
  "Follow the newest run of this buffer's session."
  (interactive)
  (cooked-run-show (or (car (last (cooked-runs)))
                       (user-error "No runs are kept for this buffer's session"))))

;;;###autoload
(defun cooked-run-select ()
  "Choose one of the runs of this buffer's session, newest first, and follow it."
  (interactive)
  (let* ((runs (or (reverse (cooked-runs))
                   (user-error "No runs are kept for this buffer's session")))
         (table (mapcar (lambda (run)
                          (cons (format "%s  %-10s %s"
                                        (format-time-string "%H:%M:%S" (plist-get run :started))
                                        (cooked-run-status run)
                                        (car (split-string (cooked-run-name run) "\n")))
                                run))
                        runs))
         (choice (completing-read
                  "Run: "
                  (lambda (string predicate action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity))
                      (complete-with-action action table string predicate)))
                  nil t)))
    (cooked-run-show (cdr (assoc choice table)))))

(provide 'cooked-run)

;;; cooked-run.el ends here
