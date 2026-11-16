;;; cooked-popup.el --- Look at a buffer or a file in a frame over this one -*- lexical-binding: t; -*-

;;; Commentary:

;; A look at something without giving it a window: a small frame over the
;; selected one, which takes the keyboard while it is up and gives it back to
;; where it was asked for.  The windows underneath are not touched, so a
;; terminal keeps its size and a program in it is never told to redraw.
;;
;;   (cooked-popup-buffer BUFFER)        any buffer, the caller's to fill
;;   (cooked-popup-file FILE LINE COL)   a file, read-only, in its own major mode
;;
;; Optional, and nothing requires it.  To have file names in a terminal's
;; output open this way rather than in a window:
;;
;;   (require 'cooked-popup)
;;   (setq-default cooked-file-open-function #'cooked-popup-open-file)
;;
;; or `setq-local' for some buffers only.
;;
;; `cooked-popup-mode' is the keys of a buffer shown this way -- q closes, l
;; goes back, v opens what is shown in a window of its own -- for a caller to
;; turn on in the buffers it shows.  What v opens is the caller's to say, in
;; `cooked-popup-visit-function'; `cooked-popup-file' sets both for its buffers.
;;
;; A pop-up opened from inside one -- a file name followed in what is shown --
;; replaces it, and l goes back to what was shown before.  One opened from
;; anywhere else starts afresh.
;;
;; A file is shown in a buffer that does not visit it.  Its major mode is the
;; one the file would be visited in, so it is highlighted as it would be there,
;; lazily, and an image is an image; but no mode hook is run and no local
;; variables are read, so looking at a file starts no language server, runs
;; nothing the file says, and leaves no buffer behind.  v is how to get the
;; real thing.
;;
;; Where there are no child frames -- a terminal frame -- a pop-up is a window,
;; and closing it is `quit-window'.
;;
;; Not to be confused with a peek (`cooked-toggle-peek'), which is a terminal
;; buffer's own keyboard handed to Emacs for reading back over its output.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup cooked-popup nil
  "A look at a buffer or a file in a frame over the selected one."
  :group 'cooked)

(defcustom cooked-popup-width 110
  "Widest, in columns, that the frame of a pop-up is made."
  :type 'natnum)

(defcustom cooked-popup-top 0.15
  "Where the top of a pop-up's frame sits, as a fraction of its parent's height."
  :type 'float)

(defcustom cooked-popup-bottom 0.15
  "How much of the parent's height a pop-up's frame leaves free at the bottom.
A fraction.  The frame reaches down to there whatever it shows, so stepping
between buffers of different lengths neither moves nor resizes it."
  :type 'float)

(defcustom cooked-popup-max-file-size (* 2 1024 1024)
  "Largest file, in bytes, that `cooked-popup-file' shows; larger ones are visited."
  :type 'natnum)

(defcustom cooked-popup-visit-modes
  '(doc-view-mode doc-view-mode-maybe pdf-view-mode archive-mode tar-mode)
  "Major modes whose files `cooked-popup-file' visits rather than shows.
Modes that need the file itself behind the buffer, or that do their work on
being turned on."
  :type '(repeat function))

(defcustom cooked-popup-frame-parameters nil
  "Frame parameters for the frame of a pop-up, over the ones it is made with."
  :type '(alist :key-type symbol :value-type sexp))

(defvar cooked-popup--frame nil "The child frame pop-ups are shown in.")
(defvar cooked-popup--buffer nil "The buffer being shown, if one is.")
(defvar cooked-popup--return-window nil "Where `cooked-popup-quit' goes back to.")
(defvar cooked-popup--history nil
  "The buffers shown before the one being shown, newest first.")
(defvar cooked-popup--owned nil
  "Buffers made here to show files, killed when the pop-up closes.")

(defvar-local cooked-popup--file nil "The file this buffer shows.")

(defvar-local cooked-popup-visit-function nil
  "How `cooked-popup-visit' opens what this buffer shows in a window of its own.
Called with no arguments in the buffer being shown.  It closes the pop-up
itself, with `cooked-popup-quit', once it knows there is something to open --
after which a buffer `cooked-popup-file' made is gone.")

(defvar cooked-popup-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'cooked-popup-quit)
    (define-key map (kbd "l") #'cooked-popup-back)
    (define-key map (kbd "v") #'cooked-popup-visit)
    map)
  "Keys of a buffer shown in a pop-up.")

(define-minor-mode cooked-popup-mode
  "Keys for a buffer shown by `cooked-popup-buffer'.
\\{cooked-popup-mode-map}"
  :lighter nil)

;; In evil's normal and motion states q would start recording a macro, and a
;; pop-up that cannot be closed is worse than one without l and v, which stay
;; evil's own there: motion and selection are what reading is done with.
(declare-function evil-define-key* "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")
(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) cooked-popup-mode-map
    "q" #'cooked-popup-quit)
  (add-hook 'cooked-popup-mode-hook #'evil-normalize-keymaps))

;;;; The frame

(defun cooked-popup--showing ()
  "The buffer being shown, if it is still on show."
  (and (buffer-live-p cooked-popup--buffer)
       (get-buffer-window cooked-popup--buffer 'visible)
       cooked-popup--buffer))

(defun cooked-popup-showing-p (buffer)
  "Whether BUFFER is the one the pop-up is showing."
  (eq (cooked-popup--showing) buffer))

(defun cooked-popup--frame-for (parent)
  "The frame pop-ups are shown in over PARENT, made if there is none."
  (unless (and (frame-live-p cooked-popup--frame)
               (eq (frame-parent cooked-popup--frame) parent))
    (when (frame-live-p cooked-popup--frame)
      (delete-frame cooked-popup--frame))
    (setq cooked-popup--frame
          (make-frame
           `(,@cooked-popup-frame-parameters
             (parent-frame . ,parent) (minibuffer . nil) (visibility . nil)
             (undecorated . t) (child-frame-border-width . 1)
             (internal-border-width . 1) (left-fringe . 8) (right-fringe . 0)
             (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
             (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
             (unsplittable . t) (no-other-frame . t) (desktop-dont-save . t)
             (name . "cooked-popup")))))
  cooked-popup--frame)

(defun cooked-popup--set-window-buffer (buffer)
  "Show BUFFER in the pop-up frame's one window, which is dedicated to it."
  (let ((window (frame-root-window cooked-popup--frame)))
    (set-window-dedicated-p window nil)
    (set-window-buffer window buffer)
    (set-window-dedicated-p window t)
    window))

(defun cooked-popup-fit ()
  "Size the frame of the pop-up to its parent, and put it in its place.
As wide as `cooked-popup-width' allows, and from `cooked-popup-top' down to
`cooked-popup-bottom'.  The same size whatever it shows: a frame that grew
and shrank with each buffer stepped through moved its edges under the eye,
and a short buffer is shown with room to spare instead.  For a caller whose
parent frame changed size while on show."
  (when (and (frame-live-p cooked-popup--frame)
             (display-graphic-p cooked-popup--frame))
    (let* ((frame cooked-popup--frame)
           (parent (frame-parent frame))
           (columns (min cooked-popup-width (max 20 (- (frame-width parent) 4))))
           (lines (max 6 (floor (* (- 1 cooked-popup-top cooked-popup-bottom)
                                   (frame-height parent))))))
      (unless (and (= (frame-width frame) columns) (= (frame-height frame) lines))
        (set-frame-size frame columns lines))
      (set-frame-position
       frame
       (max 0 (/ (- (frame-pixel-width parent) (frame-pixel-width frame)) 2))
       (max 0 (floor (* cooked-popup-top (frame-pixel-height parent))))))))

(defun cooked-popup--show (buffer)
  "Put BUFFER on show, in the frame or, where there are none, a window."
  (setq cooked-popup--buffer buffer)
  (if (not (display-graphic-p))
      (pop-to-buffer buffer)
    (let ((parent (or (frame-parent) (selected-frame))))
      (cooked-popup--frame-for parent)
      (let ((window (cooked-popup--set-window-buffer buffer)))
        (cooked-popup-fit)
        (set-window-point window (with-current-buffer buffer (point))))
      (make-frame-visible cooked-popup--frame)
      (select-frame-set-input-focus cooked-popup--frame))))

(defun cooked-popup--forget ()
  "Drop what the pop-up that just closed kept: its history, and its own buffers."
  (let ((owned cooked-popup--owned))
    (setq cooked-popup--buffer nil
          cooked-popup--history nil
          cooked-popup--owned nil)
    (when (and owned (frame-live-p cooked-popup--frame))
      ;; Killing a buffer in a dedicated window takes the window with it, and
      ;; here the frame; so the window is given something else to hold first.
      (cooked-popup--set-window-buffer (get-buffer-create " *cooked-popup*")))
    (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
          owned)))

;;;###autoload
(defun cooked-popup-buffer (buffer)
  "Show BUFFER in a frame over the selected one, and give it the keyboard.
Called from the buffer being shown, BUFFER takes its place and
`cooked-popup-back' returns to it; from anywhere else, the pop-up starts
afresh and `cooked-popup-quit' comes back here.  The same buffer shown again
is fitted again.  Returns BUFFER.

BUFFER is the caller's: `cooked-popup-mode' gives it the keys to close the
pop-up with, if the caller turns it on there."
  (let ((showing (cooked-popup--showing)))
    (if (and showing (eq (window-buffer) showing))
        (unless (eq showing buffer)
          (push showing cooked-popup--history))
      (cooked-popup--forget)
      (unless (and (frame-live-p cooked-popup--frame)
                   (eq (selected-frame) cooked-popup--frame))
        (setq cooked-popup--return-window (selected-window)))))
  (cooked-popup--show buffer)
  buffer)

(defun cooked-popup-quit ()
  "Close the pop-up, and go back to where it was asked for."
  (interactive)
  (let ((buffer cooked-popup--buffer)
        (frame cooked-popup--frame))
    (if (and (frame-live-p frame) (frame-visible-p frame)
             (display-graphic-p frame))
        (let ((inside (eq (selected-frame) frame)))
          (make-frame-invisible frame)
          (when (and inside (window-live-p cooked-popup--return-window))
            (select-frame-set-input-focus (window-frame cooked-popup--return-window))
            (select-window cooked-popup--return-window)))
      (when-let* (((buffer-live-p buffer))
                  (window (get-buffer-window buffer)))
        (quit-window nil window)))
    (cooked-popup--forget)))

(defun cooked-popup-back ()
  "Go back to what the pop-up showed before this."
  (interactive)
  (while (and cooked-popup--history
              (not (buffer-live-p (car cooked-popup--history))))
    (pop cooked-popup--history))
  (unless cooked-popup--history
    (user-error "Nothing to go back to"))
  (cooked-popup--show (pop cooked-popup--history)))

(defun cooked-popup-visit ()
  "Open what the pop-up shows in a window of its own, and close the pop-up."
  (interactive)
  (funcall (or cooked-popup-visit-function
               (user-error "Nothing here to open in a window"))))

;;;; Files

(defun cooked-popup--go-to (line col)
  "Move to LINE and COL, either of which may be nil."
  (when line
    (goto-char (point-min))
    (forward-line (1- line))
    (when col (move-to-column col))))

(defun cooked-popup--file-mode (file)
  "The major mode `auto-mode-alist' names for FILE, if it names one."
  (let ((mode (assoc-default file auto-mode-alist #'string-match)))
    (and (symbolp mode) (fboundp mode) mode)))

(defun cooked-popup--visit (file line col)
  "Visit FILE in a window of its own at LINE and COL, closing any pop-up."
  (when (cooked-popup--showing)
    (cooked-popup-quit))
  (find-file-other-window file)
  (cooked-popup--go-to line col))

(defun cooked-popup--visit-file ()
  "Visit the file this buffer shows, at the line shown.
The `cooked-popup-visit-function' of a buffer `cooked-popup-file' made."
  (let ((file cooked-popup--file)
        (line (line-number-at-pos nil t))
        (col (current-column)))
    (cooked-popup--visit file line col)))

(defun cooked-popup--file-buffer (file)
  "A new read-only buffer holding FILE, in the mode FILE would be visited in.
Without the mode's hooks, and without reading the file's local variables."
  (let ((buffer (generate-new-buffer
                 (format "*popup: %s*" (file-name-nondirectory file))))
        (image (eq (cooked-popup--file-mode file) 'image-mode)))
    (with-current-buffer buffer
      (if (not image)
          (insert-file-contents file)
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file))
      (setq default-directory (file-name-directory file))
      (goto-char (point-min))
      ;; Quietly: some modes say how they set themselves up.
      (let ((inhibit-message t) (message-log-max nil))
        (condition-case nil
            (delay-mode-hooks
              (if image
                  (image-mode)
                ;; By the file's name, as visiting it would choose; the name
                ;; is lent for the choosing only, so the buffer visits nothing.
                (let ((buffer-file-name file))
                  (set-auto-mode))))
          (error (delay-mode-hooks (fundamental-mode)))))
      ;; What turns highlighting on in a buffer is one of the hooks not run.
      (unless image (font-lock-mode 1))
      (setq buffer-read-only t
            buffer-undo-list t
            cooked-popup--file file
            cooked-popup-visit-function #'cooked-popup--visit-file
            header-line-format
            (format "%s  ·  q close  v open in a window  l back"
                    (abbreviate-file-name file)))
      (set-buffer-modified-p nil)
      (cooked-popup-mode 1))
    buffer))

;;;###autoload
(defun cooked-popup-file (file &optional line col)
  "Show FILE read-only in a frame over the selected one, at LINE and COL.
There, \\<cooked-popup-mode-map>\\[cooked-popup-visit] visits it in a window and \
\\[cooked-popup-quit] closes the frame.  A directory, a
file over `cooked-popup-max-file-size' or one in a mode among
`cooked-popup-visit-modes' is visited in a window instead.  Returns the buffer
showing it, or nil if it was visited."
  (interactive "fShow file: ")
  (setq file (expand-file-name file))
  (unless (file-readable-p file)
    (user-error "Cannot read %s" file))
  (if (or (file-directory-p file)
          (> (or (file-attribute-size (file-attributes file)) 0)
             cooked-popup-max-file-size)
          (memq (cooked-popup--file-mode file) cooked-popup-visit-modes))
      (progn (cooked-popup--visit file line col) nil)
    (let ((buffer (cooked-popup--file-buffer file)))
      (with-current-buffer buffer
        (cooked-popup--go-to line col))
      (cooked-popup-buffer buffer)
      (push buffer cooked-popup--owned)
      ;; Once it is on show: this is where the line belongs in its window.
      (when-let* ((window (get-buffer-window buffer t)))
        (with-selected-window window
          (cooked-popup--go-to line col)
          (when line (ignore-errors (recenter)))))
      buffer)))

;;;###autoload
(defun cooked-popup-open-file (file line col)
  "Show FILE at LINE and COL in a pop-up.  A `cooked-file-open-function'."
  (cooked-popup-file file line col)
  t)

(provide 'cooked-popup)

;;; cooked-popup.el ends here
