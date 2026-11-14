;;; cooked-dock.el --- Keep a program's input in view while its output is read -*- lexical-binding: t; -*-

;;; Commentary:

;; A program that prints onto the main screen -- an agent's chat with an inline
;; renderer, a REPL -- keeps its input at the bottom of the screen and its
;; history above it.  Reading back through that history (cooked-navigate.el)
;; used to scroll the input out of view with it: to type, you went back down.
;;
;; A dock keeps the input where it was.  The moment a window on such a program
;; stops showing the bottom of the buffer, its bottom rows are split off into a
;; window of their own -- the dock -- which goes on showing the program's live
;; rows, pinned, while the window above scrolls freely through everything else.
;; Nothing moves when it happens: the dock takes over exactly the rows of the
;; window it is made from, showing exactly what they showed.  It is the same
;; terminal, in two windows, sized as one: the child is never told about it.
;;
;; While docked:
;;
;; - The window above is the transcript.  Output never moves it; any Emacs
;;   command or the wheel scrolls it.
;; - The dock is the input.  Typing anywhere goes there, without moving the
;;   transcript, so a reply can be written while the history is in view.
;;   `M-v', `C-p' and the other ways out of the input lead back up into the
;;   transcript rather than scrolling the dock.
;; - Submitting with RET, scrolling the transcript back down to the dock, or
;;   moving point onto the live rows puts the two back together, following.
;;
;; Which rows are "live" is decided from the terminal state only: the row the
;; program's cursor is on, everything below it, and `cooked-dock-context-rows'
;; above it.  Nothing reads what the program draws.  Docking applies exactly
;; when cooked-navigate.el does -- a program owning the keyboard on the main
;; screen that has not asked for the mouse -- and ends the moment it stops.
;;
;; The pair is an atomic window (see `window-make-atom'): splitting, deleting
;; and `delete-other-windows' treat it as one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'cooked)
(require 'cooked-navigate)

(declare-function cooked--refresh-keymap "cooked-mode" (&optional quiet))
(declare-function cooked--pin-transcript-bottom "cooked-render"
                  (windows &optional pos bottom))
(declare-function cooked--bottom-start "cooked-render" (window &optional foot))
(declare-function cooked--rows-height "cooked-render" (window from to))
(defvar cooked--after-scroll-hook)

(defcustom cooked-dock t
  "Whether a program's input stays in view while its output is read.

Non-nil splits the live rows of a navigable program into a dock at the bottom
of the window as soon as the window is scrolled away from them; see the
commentary of cooked-dock.el.  nil scrolls the input away with everything
else, as a single window does."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-dock-context-rows 3
  "Rows above the program's cursor that belong to its input.

The dock shows the cursor's row, every row below it, and this many above:
for an agent's chat, the border of its input box, the blank row above that and
the spinner or status line above it.  Counted in rows of the terminal, never
found from what is drawn."
  :type 'natnum
  :group 'cooked)

(defcustom cooked-dock-max-fraction 0.4
  "The largest part of a window a dock may take, as a fraction of its rows.
A window too short to leave the rest for reading is not docked at all."
  :type 'number
  :group 'cooked)

;;;; Where the live rows are

(defun cooked-dock--eligible-p ()
  "Whether this buffer's program is one whose input is docked."
  (and cooked-dock
       cooked-navigate--applies
       cooked--session
       (not cooked--alt)))

(defun cooked-dock--foot ()
  "The start of the last row with anything on it."
  (save-excursion
    (goto-char (point-max))
    (skip-chars-backward " \t\n")
    (line-beginning-position)))

(defun cooked-dock--live-top ()
  "The start of the first live row: the cursor's, less the context rows."
  (let ((screen (or (cooked--screen-start-position) (point-min))))
    (save-excursion
      (goto-char (cooked--cursor-position))
      (forward-line (- cooked-dock-context-rows))
      (max (line-beginning-position) screen))))

(defun cooked-dock--rows ()
  "How many rows the live region spans."
  (let ((foot (cooked-dock--foot))
        (top (cooked-dock--live-top)))
    (if (< foot top) 1 (1+ (count-lines top foot)))))

;;;; The windows

(defun cooked-dock--of (window)
  "WINDOW's dock, if it has a live one."
  (let ((dock (window-parameter window 'cooked-dock)))
    (and (window-live-p dock) dock)))

(defun cooked-dock--main (dock)
  "The window DOCK belongs to, if it is still there."
  (let ((main (window-parameter dock 'cooked-dock-main)))
    (and (window-live-p main) main)))

(defun cooked-dock--body-pixels (window rows)
  "The body height, in pixels, that shows ROWS live rows in WINDOW.

Measured, not multiplied, when ROWS is the whole live region: a row is the
default line height only nominally -- a fallback font's glyph, an emoji, the
cursor's row can each make one a pixel or two taller -- and a dock sized by
multiplication came up short and clipped its last row, which is the status line
under the input.  A dock capped below the live region has no last row to
protect, and keeps the nominal size."
  (let ((nominal (* rows (window-default-line-height window))))
    (if (< rows (cooked-dock--rows))
        nominal
      (max nominal (cooked--rows-height window (cooked-dock--live-top)
                                        (cooked-dock--foot))))))

(defun cooked-dock--pixels (window rows)
  "The total pixel height of a window on WINDOW's buffer showing ROWS rows."
  (+ (cooked-dock--body-pixels window rows)
     (window-mode-line-height window)
     (or (window-bottom-divider-width window) 0)))

(defun cooked-dock--create (window rows)
  "Split ROWS live rows off the bottom of WINDOW into a dock, and return it."
  (let* ((window-combination-limit t)
         (window-resize-pixelwise t)
         (window-min-height 1)
         (ignore-window-parameters t)
         (dock (split-window window (- (cooked-dock--pixels window rows))
                             'below t)))
    (set-window-buffer dock (window-buffer window))
    (set-window-dedicated-p dock t)
    (set-window-parameter dock 'cooked-dock-main window)
    (set-window-parameter dock 'cooked-docked t)
    (set-window-parameter dock 'no-other-window t)
    (set-window-parameter dock 'header-line-format 'none)
    (set-window-parameter dock 'tab-line-format 'none)
    (set-window-parameter dock 'cooked-dock-rows rows)
    (set-window-parameter window 'cooked-dock dock)
    ;; One mode line for the pair, the dock's, where the window's always was.
    (set-window-parameter window 'mode-line-format 'none)
    (window-make-atom (window-parent window))
    (set-window-point dock (cooked--cursor-position))
    (cooked-dock--pin dock)
    dock))

(defun cooked-dock--remove (dock)
  "Delete DOCK, giving its rows back to the window it belongs to."
  (let ((main (cooked-dock--main dock))
        (parent (window-parent dock)))
    (when (window-live-p dock)
      (when parent (set-window-parameter parent 'window-atom nil))
      (set-window-parameter dock 'window-atom nil)
      (when main
        (set-window-parameter main 'window-atom nil)
        (set-window-parameter main 'cooked-dock nil)
        (set-window-parameter main 'mode-line-format nil))
      (let ((ignore-window-parameters t)
            (window-resize-pixelwise t))
        (if (eq (selected-window) dock)
            (progn (when main (select-window main))
                   (delete-window dock))
          (delete-window dock))))
    main))

(defun cooked-dock--pin (dock)
  "Show the live rows in DOCK: its last row on the last row with text."
  (with-current-buffer (window-buffer dock)
    (let ((top (cooked--bottom-start dock (cooked-dock--foot))))
      (unless (eq dock (selected-window))
        (set-window-point dock (max top (cooked--cursor-position))))
      (unless (zerop (window-vscroll dock t))
        (set-window-vscroll dock 0 t))
      (unless (= top (window-start dock))
        (set-window-start dock top t)))))

(defun cooked--window-rows-of (window)
  "Rows WINDOW alone can show, ignoring any dock under it."
  (floor (window-body-height window t) (window-default-line-height window)))

(defun cooked-dock--resize (dock rows)
  "Grow DOCK to show ROWS rows whole; a dock never shrinks while it lives.
Shrinking on every redraw that happens to need fewer rows would move the
transcript's bottom edge back and forth under the reader."
  (let* ((have (or (window-parameter dock 'cooked-dock-rows) 0))
         (delta (- (cooked-dock--body-pixels dock (max rows have))
                   (window-body-height dock t))))
    (when (> delta 0)
      (let ((window-resize-pixelwise t)
            (window-min-height 1)
            (ignore-window-parameters t))
        (when (window-resizable-p dock delta nil nil t)
          (window-resize dock delta nil nil t)
          (set-window-parameter dock 'cooked-dock-rows (max rows have)))))))

(defun cooked-dock--max-rows (window)
  "The most rows a dock under WINDOW may take."
  (floor (* cooked-dock-max-fraction (cooked--window-rows window))))

(defun cooked-dock--row (window n)
  "The start of the Nth row WINDOW shows, counting its first as 0."
  (save-excursion
    (goto-char (window-start window))
    (vertical-motion n window)
    (point)))

(defun cooked-dock--visible-rows (window)
  "How many rows WINDOW shows: whole ones, and with a partial one at the foot.
As (WHOLE . ANY).  Counted from the window's start and its vertical scroll
rather than asked of `window-end', which is only as fresh as the last redisplay
-- and these questions are asked between a command and the redisplay after it."
  (let* ((lh (window-default-line-height window))
         (px (+ (window-body-height window t) (window-vscroll window t))))
    (cons (/ px lh) (/ (+ px lh -1) lh))))

(defun cooked-dock--shows-bottom-p (window)
  "Whether WINDOW, undocked, shows the whole of the last row with text.
In pixels, from the window's start and its vertical scroll, rather than asked of
`window-end', which is only as fresh as the last redisplay -- and these
questions are asked between a command and the redisplay after it."
  (let ((start (window-start window))
        (foot (cooked-dock--foot)))
    (or (> start foot)
        (<= (- (cooked--rows-height window start foot)
               (window-vscroll window t))
            (window-body-height window t)))))

(defun cooked-dock--reached-p (window)
  "Whether docked WINDOW has been scrolled down into its dock's rows.

Into, not onto: a window whose last row is the one just above the dock is
exactly what docking leaves behind, and treating that as arrival would undock
it on the very next scroll.  One pixel further and the window is showing a live
row, and the two are put back together where they meet."
  (let ((start (window-start window))
        (live (cooked-dock--live-top)))
    (or (>= start live)
        (< (- (cooked--rows-height window start
                                   (save-excursion (goto-char live)
                                                   (line-beginning-position 0)))
              (window-vscroll window t))
           (window-body-height window t)))))

;;;; Following the user

(defun cooked-dock--attach (window)
  "Remove WINDOW's dock, and have WINDOW follow the program again."
  (when-let* ((dock (cooked-dock--of window)))
    (let ((was-dock (eq (selected-window) dock)))
      (cooked-dock--remove dock)
      (when (or was-dock (eq (selected-window) window))
        (setq cooked-navigate--reading nil)
        (goto-char (cooked--cursor-position))
        (cooked--refresh-keymap t))
      (set-window-point window (cooked--cursor-position))
      (cooked--pin-transcript-bottom (list window) (cooked--cursor-position)
                                     (point-max)))))

(defun cooked-dock--detach (window)
  "Dock WINDOW's live rows, if it is tall enough to keep reading above them."
  (let ((rows (cooked-dock--rows)))
    (when (and (>= rows 1)
               (<= rows (cooked-dock--max-rows window)))
      (prog1 (cooked-dock--create window rows)
        ;; Point must be on a row the shortened window still shows, or
        ;; redisplay scrolls the window to find it -- which, after a scroll of a
        ;; row or two, is a jump straight back down.
        (let ((last (cooked-dock--row
                     window (max 0 (1- (car (cooked-dock--visible-rows window)))))))
          (when (> (window-point window) last)
            (if (eq window (selected-window))
                (goto-char last)
              (set-window-point window last))))))))

(defun cooked-dock--update-window (window)
  "Dock or undock WINDOW, a window on the current buffer, as it now stands."
  (let ((dock (cooked-dock--of window)))
    (cond
     ((not (cooked-dock--eligible-p))
      (when dock (cooked-dock--remove dock)))
     (dock
      (if (or (cooked-dock--reached-p window)
              (and (eq window (selected-window))
                   (>= (point) (cooked-dock--live-top))))
          (cooked-dock--attach window)
        (cooked-dock--resize dock (min (cooked-dock--rows)
                                       (cooked-dock--max-rows window)))
        (cooked-dock--pin dock)))
     ((not (cooked-dock--shows-bottom-p window))
      (cooked-dock--detach window)))))

(defun cooked-dock--windows ()
  "The windows on the current buffer that are not docks, in this frame."
  (seq-remove #'cooked--dock-window-p (get-buffer-window-list nil nil)))

(defun cooked-dock--post-command ()
  "Dock or undock the windows the last command may have scrolled.

Every window in the selected frame showing a cooked buffer, not only the
selected one: the wheel scrolls the window under the mouse."
  (cooked--protect-hook
    (dolist (window (window-list nil 'no-minibuffer))
      (let ((buffer (window-buffer window)))
        (when (and (not (cooked--dock-window-p window))
                   (buffer-local-value 'cooked--session buffer))
          (with-current-buffer buffer
            (cooked-dock--update-window window)))))
    ;; RET in the dock submits; the reply is what is wanted next.
    (let ((window (selected-window)))
      (when-let* (((cooked--dock-window-p window))
                  (main (cooked-dock--main window))
                  ((memq this-command '(cooked-send-key
                                        cooked--peek-resume-and-send)))
                  ((member (this-command-keys-vector) '([13] [return]))))
        (with-current-buffer (window-buffer window)
          (cooked-dock--attach main))))))

(defun cooked-dock--after-drain ()
  "Keep this buffer's docks pinned, and gone once they no longer apply.
On `cooked--after-scroll-hook'.  Never docks a window: only the user's own
scrolling does that, so a redraw cannot make a window jump."
  (dolist (window (get-buffer-window-list nil nil t))
    (when-let* ((dock (cooked-dock--of window)))
      (if (cooked-dock--eligible-p)
          (progn (cooked-dock--resize dock (min (cooked-dock--rows)
                                                (cooked-dock--max-rows window)))
                 (cooked-dock--pin dock))
        (cooked-dock--remove dock)))))

(defun cooked-dock-select-input ()
  "If the selected window is docked, select its dock and return non-nil.

What typing and the other ways back to the input call before they move point:
with a dock, the input is already in view, so the window being read stays
where it is and the keys go to the dock instead."
  (when-let* ((window (selected-window))
              (dock (cooked-dock--of window))
              ((eq (window-buffer dock) (current-buffer))))
    (select-window dock)
    (goto-char (cooked--cursor-position))
    (setq cooked-navigate--reading nil)
    t))

(defun cooked-dock--pre-command ()
  "Send the ways out of the input up into the transcript when typed in a dock."
  (when-let* ((window (selected-window))
              ((cooked--dock-window-p window))
              (main (cooked-dock--main window))
              ((memq this-command
                     (mapcar #'cdr (seq-remove
                                    (lambda (entry)
                                      (memq (cdr entry)
                                            '(cooked-previous-input
                                              cooked-next-input
                                              cooked-paste)))
                                    cooked-navigation-keys)))))
    (select-window main)))

(defun cooked-dock--clean-up ()
  "Remove docks whose window has gone or no longer shows their buffer.
Also docks restored from a saved window configuration, which come back as
plain windows marked as docks of nothing."
  (dolist (frame (frame-list))
    (dolist (window (window-list frame 'no-minibuffer))
      (when (cooked--dock-window-p window)
        (let ((main (cooked-dock--main window)))
          (unless (and main
                       (eq (window-buffer main) (window-buffer window))
                       (eq (window-parameter main 'cooked-dock) window))
            (cooked-dock--remove window)))))))

(defvar cooked-dock--clean-up-timer nil)

(defun cooked-dock--schedule-clean-up (&rest _)
  "Clean up stale docks once the window change that made them is over."
  (unless (timerp cooked-dock--clean-up-timer)
    (setq cooked-dock--clean-up-timer
          (run-with-timer 0 nil (lambda ()
                                  (setq cooked-dock--clean-up-timer nil)
                                  (cooked-dock--clean-up))))))

(defun cooked-dock--kill-buffer ()
  "Remove this buffer's docks before it goes."
  (dolist (window (get-buffer-window-list nil nil t))
    (when-let* ((dock (cooked-dock--of window)))
      (cooked-dock--remove dock))))

(defun cooked-dock--post-command-elsewhere ()
  "`cooked-dock--post-command', for a command run from a buffer that is not ours.
The wheel scrolls the window under the mouse, whatever buffer is current."
  (unless (derived-mode-p 'cooked-mode)
    (cooked-dock--post-command)))

(defun cooked-dock--setup ()
  "Install the dock's buffer-local hooks."
  (add-hook 'cooked--after-scroll-hook #'cooked-dock--after-drain nil t)
  ;; Locally and deeper than `cooked-navigate--post-command' (50), so it runs
  ;; after it: a buffer-local hook of positive depth runs after every global
  ;; one, and navigate would otherwise read the switch between the dock and
  ;; the window above it as a scroll, and undo what docking just decided.
  (add-hook 'post-command-hook #'cooked-dock--post-command 60 t)
  (add-hook 'kill-buffer-hook #'cooked-dock--kill-buffer nil t))

(add-hook 'cooked-mode-hook #'cooked-dock--setup)
(add-hook 'post-command-hook #'cooked-dock--post-command-elsewhere)
(add-hook 'pre-command-hook #'cooked-dock--pre-command)
(add-hook 'window-buffer-change-functions #'cooked-dock--schedule-clean-up)
;; Only the flag outlives a saved window configuration -- a window is not a
;; thing that can be written to a file -- so a dock restored by `desktop' or
;; `persp-mode' comes back marked but orphaned, and is cleaned up.
(add-to-list 'window-persistent-parameters '(cooked-docked . writable))

(provide 'cooked-dock)
;;; cooked-dock.el ends here
