;;; cooked-annotate.el --- Clickable notes on a stretch of a terminal's output -*- lexical-binding: t; -*-

;;; Commentary:

;; A small, generic seam for packages that know something about a stretch of
;; output that the terminal does not: "these rows are where the agent ran that
;; command", "this is where the build reported that error".  cooked does not
;; decide what is annotated or what activating it does; it keeps the note on its
;; rows through repaints and gives it a mark in the fringe that can be clicked.
;;
;;   (cooked-annotate BEG END :help "ran: make test" :data CALL
;;                    :action (lambda (annotation) ...))
;;
;; - The rows from BEG's to END's get a mark in the left fringe.  A click on it,
;;   or RET with point on those rows, calls ACTION with the annotation.
;; - `cooked-annotation-next' and `cooked-annotation-previous' step between them.
;; - `cooked-annotations' lists them, `cooked-annotation-at' finds one, and
;;   `cooked-annotation-delete' removes one.
;;
;; Annotations are anchored by row, not by character.  A row the program
;; repaints is deleted and written again, which takes overlays with it and
;; collapses markers to the row's start -- so what is kept is a marker at the
;; start of the first and of the last row, and the overlay showing it is
;; re-derived from those after every render, on `cooked-row-rendered-functions',
;; the way `cooked-command-decorations' re-arms its markers.
;;
;; Rows are rendered in place, by screen index, so a scroll does not move a
;; row's text: the rows that leave the top are inserted again above the screen
;; as scrollback, and every screen row is rewritten with what is now there.
;; The buffer's text is conserved -- what was at a position is still at that
;; position afterwards (see `cooked--relocate-marks') -- but a marker is not: the
;; insertion above it pushes it down, onto whatever row now has its old index.
;; So an annotation also remembers where its rows began and what they said, and
;; when a render leaves other text under its markers while the remembered
;; position still holds the remembered text, it moves back there.  Text found
;; at neither was repainted with something else, and what was annotated is no
;; longer there: the annotation is removed, and the caller told if it asked
;; to be (`:removed').  A row in permanent scrollback is never rewritten, so
;; the re-arm only looks at annotations that were on the live screen.
;;
;; Nothing here reads what the program draws, and nothing is sent to it: an
;; annotation is the caller's statement about positions in the buffer.

;;; Code:

(require 'cl-lib)
(require 'cooked)

(when (fboundp 'define-fringe-bitmap)
  ;; A small right-pointing wedge: "there is more here", and distinct from the
  ;; per-command bar of `cooked-command-decorations', which may share the fringe.
  (define-fringe-bitmap 'cooked-annotation-wedge
    [#b10000000
     #b11000000
     #b11100000
     #b11110000
     #b11100000
     #b11000000
     #b10000000]
    nil nil 'center))

(defgroup cooked-annotate nil
  "Clickable notes on stretches of a terminal's output."
  :group 'cooked)

(defcustom cooked-annotation-bitmap 'cooked-annotation-wedge
  "Fringe bitmap marking an annotated stretch of output."
  :type 'symbol
  :group 'cooked-annotate)

(defface cooked-annotation
  '((t :inherit (font-lock-keyword-face fringe)))
  "Face of the fringe mark of an annotation, unless the annotation names one."
  :group 'cooked-annotate)

(cl-defstruct (cooked-annotation (:constructor cooked-annotation--make)
                                 (:copier nil))
  "A note on a stretch of output, from one row to another."
  (beg nil :documentation "Marker at the start of the first row.")
  (end nil :documentation "Marker at the start of the last row.")
  (help nil :documentation "Tooltip text, or nil.")
  (action nil :documentation "Function called with the annotation, or nil.")
  (face nil :documentation "Face of the fringe mark, or nil for the default.")
  (data nil :documentation "Whatever the caller attached.")
  (removed nil :documentation "Function called with it if its rows are gone.")
  (text nil :documentation "The text of its rows, when last seen in place.")
  (pos nil :documentation "Where its first row began, when last seen in place.")
  (overlay nil :documentation "The overlay showing it, re-derived as needed."))

(defvar-local cooked--annotations nil
  "This buffer's annotations, last-placed first.")

(defvar cooked-annotation-overlay-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cooked-annotation-activate)
    (define-key map (kbd "<return>") #'cooked-annotation-activate)
    map)
  "Keymap in force with point on annotated rows.
A `keymap' overlay property, so it outranks cooked's own maps there: RET on
an annotated row of output activates the annotation rather than going back
to the program's input.")

(defvar cooked-annotation-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [left-fringe mouse-1] #'cooked-annotation-click)
    map)
  "Keymap of `cooked-annotation-mode': a click on an annotation's fringe mark.
Bound here rather than on the mark's own string, because a click in the
fringe is looked up in the buffer's keymaps, not in the string's.")

(define-minor-mode cooked-annotation-mode
  "Show and activate the annotations of this terminal's output.
Turned on by `cooked-annotate' the first time a buffer gets one."
  :lighter nil
  (if cooked-annotation-mode
      (add-hook 'cooked-row-rendered-functions #'cooked--annotation-rearm nil t)
    (remove-hook 'cooked-row-rendered-functions #'cooked--annotation-rearm t)))

(defun cooked--annotation-row-start (pos)
  "The start of the row POS is on."
  (save-excursion (goto-char pos) (line-beginning-position)))

(defun cooked--annotation-bounds (annotation)
  "ANNOTATION's (BEG . END) as they are now, or nil if its rows are gone."
  (let ((beg (marker-position (cooked-annotation-beg annotation)))
        (end (marker-position (cooked-annotation-end annotation))))
    (when (and beg end)
      (save-excursion
        (goto-char (max beg end))
        (cons (min beg end) (line-end-position))))))

(defun cooked--annotation-current-text (annotation)
  "The text under ANNOTATION's markers now, or nil if its rows are gone."
  (when-let* ((bounds (cooked--annotation-bounds annotation)))
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(defun cooked--annotation-heal (annotation)
  "Put ANNOTATION back on its rows if a scroll has pushed its markers off them.
See the commentary for why that happens and why position, not a search, is
what finds the rows again.  Return nil if the rows are gone, else non-nil."
  (let ((text (cooked-annotation-text annotation))
        (pos (cooked-annotation-pos annotation))
        (now (cooked--annotation-current-text annotation)))
    (cond
     ((null now))
     ((equal text now))
     ((and text pos (<= (+ pos (length text)) (point-max))
           (equal text (buffer-substring-no-properties pos (+ pos (length text))))
           (save-excursion (goto-char pos) (bolp)))
      (set-marker (cooked-annotation-beg annotation) pos)
      (set-marker (cooked-annotation-end annotation)
                  (cooked--annotation-row-start (+ pos (length text)))))
     (t (setq now 'gone)))
    (if (eq now 'gone)
        nil
      (setf (cooked-annotation-pos annotation)
            (marker-position (cooked-annotation-beg annotation))))))

(defun cooked--annotation-paint (annotation)
  "Make ANNOTATION's overlay agree with its markers; return it."
  (let ((bounds (cooked--annotation-bounds annotation))
        (overlay (cooked-annotation-overlay annotation)))
    (cond
     ((null bounds)
      (when overlay (delete-overlay overlay)))
     ((and overlay (overlay-buffer overlay)
           (= (overlay-start overlay) (car bounds))
           (= (overlay-end overlay) (cdr bounds))))
     (t
      (if (and overlay (overlay-buffer overlay))
          (move-overlay overlay (car bounds) (cdr bounds))
        (setq overlay (make-overlay (car bounds) (cdr bounds) nil t nil))
        (overlay-put overlay 'cooked-annotation annotation)
        (overlay-put overlay 'keymap cooked-annotation-overlay-map)
        (overlay-put overlay 'help-echo (cooked-annotation-help annotation))
        (overlay-put overlay 'before-string
                     (propertize
                      " " 'display
                      `(left-fringe ,cooked-annotation-bitmap
                                    ,(or (cooked-annotation-face annotation)
                                         'cooked-annotation))))
        (setf (cooked-annotation-overlay annotation) overlay))))
    annotation))

(defun cooked--annotation-rearm (_beg _end)
  "Repaint the annotations a render may have unpainted or left behind.
On `cooked-row-rendered-functions'.  Annotations are newest first and only
those that were on the live screen can have been touched, so the walk stops
at the first one wholly in permanent scrollback that is intact."
  (let ((screen (cooked--screen-start-position))
        (moved nil)
        (gone nil))
    (catch 'done
      (dolist (annotation cooked--annotations)
        (let ((overlay (cooked-annotation-overlay annotation))
              (end (marker-position (cooked-annotation-end annotation))))
          (when (and screen end (< end screen)
                     overlay (overlay-buffer overlay)
                     (equal (cooked-annotation-text annotation)
                            (cooked--annotation-current-text annotation)))
            (throw 'done nil))
          (let ((before (marker-position (cooked-annotation-beg annotation))))
            (if (not (cooked--annotation-heal annotation))
                (push annotation gone)
              (unless (eql before (marker-position (cooked-annotation-beg annotation)))
                (setq moved t))
              (cooked--annotation-paint annotation))))))
    (dolist (annotation gone)
      (cooked-annotation-delete annotation)
      (when-let* ((removed (cooked-annotation-removed annotation)))
        (funcall removed annotation)))
    (when moved (cooked--annotation-sort))))

(defun cooked--annotation-sort ()
  "Keep `cooked--annotations' newest -- furthest down the buffer -- first."
  (setq cooked--annotations
        (sort cooked--annotations
              (lambda (a b)
                (> (or (marker-position (cooked-annotation-beg a)) 0)
                   (or (marker-position (cooked-annotation-beg b)) 0))))))

;;;###autoload
(cl-defun cooked-annotate (beg end &key help action face data removed)
  "Annotate the rows of output from BEG's to END's in the current buffer.

HELP is tooltip text.  ACTION, if given, is called with the annotation when
its fringe mark is clicked or RET is pressed on its rows.  FACE colours the
fringe mark; the default is `cooked-annotation'.  DATA is kept with it, for
ACTION or anyone else to read with `cooked-annotation-data'.  REMOVED, if
given, is called with the annotation when its rows are repainted with other
text, which removes it.

Returns the annotation."
  (let* ((first (cooked--annotation-row-start (min beg end)))
         (last (cooked--annotation-row-start (max beg end)))
         (annotation (cooked-annotation--make
                      :beg (copy-marker first) :end (copy-marker last)
                      :help help :action action :face face :data data
                      :removed removed)))
    (setf (cooked-annotation-text annotation)
          (cooked--annotation-current-text annotation)
          (cooked-annotation-pos annotation) first)
    (push annotation cooked--annotations)
    (cooked--annotation-sort)
    (unless cooked-annotation-mode (cooked-annotation-mode 1))
    (cooked--annotation-paint annotation)))

(defun cooked-annotation-delete (annotation)
  "Remove ANNOTATION from its buffer."
  (when-let* ((overlay (cooked-annotation-overlay annotation)))
    (delete-overlay overlay))
  (when-let* ((buffer (marker-buffer (cooked-annotation-beg annotation))))
    (with-current-buffer buffer
      (setq cooked--annotations (delq annotation cooked--annotations))))
  (set-marker (cooked-annotation-beg annotation) nil)
  (set-marker (cooked-annotation-end annotation) nil))

(defun cooked-annotations ()
  "The current buffer's annotations, in buffer order."
  (reverse (cl-remove-if-not #'cooked--annotation-bounds cooked--annotations)))

(defun cooked-annotation-at (&optional pos)
  "The annotation covering POS, default point, or nil."
  (let ((pos (or pos (point))))
    (cl-find-if (lambda (annotation)
                  (when-let* ((bounds (cooked--annotation-bounds annotation)))
                    (<= (car bounds) pos (cdr bounds))))
                cooked--annotations)))

(defun cooked-annotation-activate (&optional pos)
  "Activate the annotation at POS, default point."
  (interactive)
  (let ((annotation (or (cooked-annotation-at pos)
                        (user-error "No annotation here"))))
    (if-let* ((action (cooked-annotation-action annotation)))
        (funcall action annotation)
      (message "%s" (or (cooked-annotation-help annotation) "")))))

(defun cooked-annotation-click (event)
  "Activate the annotation whose fringe mark EVENT clicked."
  (interactive "e")
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (pos (posn-point posn)))
    (when (and (windowp window) pos)
      (with-current-buffer (window-buffer window)
        (when-let* ((annotation (cooked-annotation-at pos)))
          (cooked-annotation-activate pos)
          annotation)))))

(defun cooked--annotation-step (n)
  "Move point to the start of the Nth annotation after it; before, if negative."
  (let* ((starts (mapcar (lambda (annotation)
                           (car (cooked--annotation-bounds annotation)))
                         (cooked-annotations)))
         (here (line-beginning-position))
         (candidates (if (> n 0)
                         (cl-remove-if-not (lambda (s) (> s here)) starts)
                       (reverse (cl-remove-if-not (lambda (s) (< s here)) starts))))
         (target (nth (1- (abs n)) candidates)))
    (unless target
      (user-error "No %s annotation" (if (> n 0) "next" "previous")))
    (goto-char target)))

(defun cooked-annotation-next (&optional n)
  "Move to the Nth next annotated stretch of output."
  (interactive "p")
  (cooked--annotation-step (or n 1)))

(defun cooked-annotation-previous (&optional n)
  "Move to the Nth previous annotated stretch of output."
  (interactive "p")
  (cooked--annotation-step (- (or n 1))))

(provide 'cooked-annotate)
;;; cooked-annotate.el ends here
