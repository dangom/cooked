;;; cooked-render.el --- Applying a drain to the buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything between the native core saying "something changed" and the buffer
;; showing it: the drain itself, the order an update is applied in, and the view
;; put back on top afterwards.
;;
;; Not opt-in, unlike `cooked-next-error' and its neighbours; `cooked-mode'
;; requires this, on the argument cooked-mouse.el and cooked-keys.el each make in
;; turn -- a self-contained subject that had grown too large to keep sharing a
;; file with everything else in it.  Here the file was cooked.el and the section
;; was "Session lifecycle", which at a thousand lines was three subjects filed
;; together because they were written in that order: starting a child, drawing
;; what it sends, and capping how much of it the buffer keeps.  Only the first is
;; the session's life.  The second is this file; the third is
;; cooked-scrollback.el.
;;
;; The unit worth reading whole is `cooked--apply', whose docstring already says
;; "the order below is the whole of it".  Everything else here either feeds it --
;; `cooked--on-wake' is the process filter's callback, `cooked--drain-and-apply'
;; the re-entrancy the filter cannot be trusted not to provoke -- or is one step
;; of it named so that the order stays legible: `cooked-viewport' and
;; `cooked--capture-viewport' for the view the render is about to invalidate,
;; `cooked--place-point' and `cooked--scroll-windows' for putting it back.
;; `cooked-refresh' is the way out when a step of that order signalled part-way.
;;
;; This file sits ABOVE cooked.el rather than beside it, and that was the one
;; decision the split turned on.  The pipeline is a pure consumer: it reads
;; `cooked--grid', the input region, the marks and the screen region, and calls
;; down into the renderers, the decorations, the links and the OSC handlers.
;; Nothing below it needs anything it defines.  Sitting below cooked.el would
;; have meant declaring most of that file's screen-region section; sitting here
;; means requiring it -- and requiring cooked-osc.el and cooked-mouse.el with it,
;; so the two OSC handlers and the mouse state that `cooked--handle-event'
;; dispatches to become ordinary calls.  Three of cooked.el's own
;; `declare-function's went away with the code that needed them.
;;
;; One back-edge downward survives, and it is the honest one: the wake pipe's
;; filter is installed by `cooked--start', in cooked.el, and its callback is
;; `cooked--on-wake' here.  cooked.el declares that pair and nothing else of this
;; file.  Upward, three things cooked-mode.el owns are declared below -- a
;; setting read, and two notifications that something changed, which is the one
;; shape a back-edge here is allowed to have; see cooked-mode-line.el's header
;; for the same arrangement stated at length.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'cooked)
(require 'cooked-util)
(require 'cooked-deco)
(require 'cooked-link)
(require 'cooked-mouse)
(require 'cooked-osc)
(require 'cooked-scrollback)

;; Defined by the native core at `module-load' time, so the byte-compiler cannot
;; see them; cooked.el and cooked-mode.el declare their own sets the same way.
(declare-function cooked--drain "ext:cooked-core")
(declare-function cooked--ready "ext:cooked-core")
(declare-function cooked--redraw "ext:cooked-core")

;; Owned by cooked-mode.el, which requires this file.  One setting the drain is
;; parameterised by, and two notifications -- the mode the child is in and the
;; exit it reported -- handed to the layer that owns what they mean.  Reads and
;; notifications only, never a question asked upward, which is what keeps the
;; list this short.
(defvar cooked-rejoin-wrapped-lines)
(declare-function cooked--set-mode "cooked-mode")
(declare-function cooked--on-exit "cooked-mode")

;;;; Draining

(defvar cooked--resyncing nil
  "Whether a resync is already under way, so a failing one cannot loop.
Bound for the dynamic extent of the repair rather than kept per buffer: it
answers \"am I inside one right now\", which is not something a buffer holds.")

(defvar-local cooked--draining nil
  "Whether a drain is already running in this buffer.
See `cooked--drain-and-apply', which is where re-entry is folded away.")

(defvar-local cooked--drain-pending nil
  "Whether a drain was asked for while one was already running.")

(defvar-local cooked--repaint-pending nil
  "Whether the next `cooked--apply\=' owes every window a real repaint.

`cooked--scroll-windows\=' only reaches the windows `cooked--capture-viewport\='
found still following the cursor -- a window showing this buffer but not
selected, and not following, is never told anything there.  Ordinarily that is
fine: an in-place row rewrite marks the buffer modified and Emacs' own
incremental redisplay picks it up in any window regardless of selection.  A
resize is the case that is not ordinary -- `cooked--sync-size\=' rewraps or
rescales every row at once -- and has been observed to leave exactly such a
window's glyph matrix stale, showing blank or stale content until something
else forces the window to be looked at again.

Set by `cooked--sync-size\=' rather than acted on there, so the repaint rides
`cooked--apply\='s own pacing instead of firing on the spot: a drag-resize can
call `cooked--sync-size\=' many times before the next drain actually runs, and
each call only flips this flag, cheaply and idempotently.  Whichever
`cooked--apply\=' runs next -- paced or, as a resize's own is, forced -- pays for
the one `force-window-update\=' that flag earned, not one per resize event.
See `cooked--flush-pending-repaint\='.")

(defun cooked--schedule-repaint ()
  "Ask the next `cooked--apply\=' to force every window on this buffer to redraw.
See `cooked--repaint-pending\='.  Cheap and idempotent, so a caller with no way
to know how many times it will run before the next drain -- `cooked--sync-size\='
mid-drag -- may call this on every one of them."
  (setq cooked--repaint-pending t))

(defun cooked--flush-pending-repaint ()
  "Force a real redisplay of every window on this buffer, if one is owed.

Called once from `cooked--apply\=', after `cooked--scroll-windows\=' has settled
where each window starts -- forcing a window before its start is right would
force it a second time when the start then moved.  See
`cooked--repaint-pending\='.

`force-window-update\=' rather than `redisplay\=': the former only marks the
window for redisplay's ordinary next pass, which happens whenever Emacs gets
back to its command loop, while the latter would run one synchronously right
here, inside a process filter -- as expensive as the render that just finished
and blocking on it for no reason a mid-drag `cooked--sync-size\=' would forgive."
  (when cooked--repaint-pending
    (setq cooked--repaint-pending nil)
    (cooked--dolist-windows w (get-buffer-window-list (current-buffer) nil t)
      (force-window-update w))))

(defvar cooked-last-failure nil
  "The last error to escape a drain, as a plist, for a report of it.
:time, :buffer, :error, :where -- the innermost functions it came out of,
innermost first -- and :backtrace.  See `cooked-show-last-failure'.")

(declare-function backtrace-get-frames "backtrace" (&optional base))
(declare-function backtrace-to-string "backtrace" (&optional frames))

(defun cooked--note-failure (err)
  "Keep ERR, signalled out of a drain, with where it came from.
A handler, called where it was signalled and before anything unwinds: by the
time `cooked--on-wake' reports it, the frames that would say which search was
given its bound on the wrong side of point are gone."
  (require 'backtrace)
  (let ((where nil))
    (mapbacktrace (lambda (evald fun _args _flags)
                    (when (and evald (symbolp fun) (< (length where) 6)
                               (not (memq fun '(cooked--note-failure signal error
                                                 user-error handler-bind-1))))
                      (push fun where)))
                  #'cooked--note-failure)
    (setq cooked-last-failure
          (list :time (current-time) :buffer (buffer-name) :error err
                :where (nreverse where)
                :backtrace (backtrace-to-string
                            (backtrace-get-frames #'cooked--note-failure))))))

(defmacro cooked--noting-failure (&rest body)
  "Run BODY, keeping any error that escapes it in `cooked-last-failure'.
Only where `handler-bind' exists (Emacs 30); otherwise just BODY."
  (declare (indent 0) (debug t))
  (if (fboundp 'handler-bind)
      `(handler-bind ((error #'cooked--note-failure)) ,@body)
    `(progn ,@body)))

(defun cooked-show-last-failure ()
  "Show the last error to escape a drain, with its backtrace."
  (interactive)
  (unless cooked-last-failure
    (user-error "No drain has failed%s"
                (if (fboundp 'handler-bind) "" " (or this Emacs cannot say: it needs 30)")))
  (with-current-buffer (get-buffer-create "*cooked failure*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "%s in %s\n%S\n\n"
                      (format-time-string "%F %T" (plist-get cooked-last-failure :time))
                      (plist-get cooked-last-failure :buffer)
                      (plist-get cooked-last-failure :error))
              (plist-get cooked-last-failure :backtrace))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer (current-buffer))))

(defun cooked--drain-and-apply ()
  "Apply whatever the native core has accumulated since the last drain.

Re-entrant calls are folded into the drain already under way rather than
nested inside it.  `cooked--apply' decides `follow', `wandered' and the
windows that count as following *before* it rewrites the screen, and then
calls three things that can refresh the keymap -- `cooked--set-alt',
`cooked--set-mode' and `cooked--handle-event' for an OSC 133 mark.  A
refresh that lifts a freeze asks for a catch-up drain, so nesting there would
leave the outer `cooked--apply' finishing against an update, and a set of
captured positions, two drains stale.

Nothing is dropped by refusing: the request is remembered and honoured once
the outer drain has returned, which is also the only point at which draining
again is safe."
  (if cooked--draining
      (setq cooked--drain-pending t)
    ;; `unwind-protect' and `setq' rather than `let': `cooked--apply' runs the
    ;; layers' own hooks, which may change the current buffer, and a `let' on a
    ;; buffer-local restores into whichever buffer is current when the binding
    ;; unwinds.
    ;;
    ;; The invariant the captured buffer keeps: *the flags are cleared in the
    ;; buffer they were set in, whatever the current buffer has become by then*.
    ;; A bare `setq' has the same defect as `let' from the other direction -- it
    ;; writes wherever the buffer pointer happens to point *now* -- so a callee
    ;; that switched buffers without restoring would clear the flag in the wrong
    ;; buffer and leave this one draining forever, folding every later wake into
    ;; a drain that has already returned.  That is a frozen terminal no refresh
    ;; can mend, since `cooked-refresh' drains too.  Callees are meant not to
    ;; wander (see `cooked--handle-osc'), but this is the drain's own guarantee
    ;; and does not depend on their good behaviour.
    (let ((buffer (current-buffer)))
      (unwind-protect
          (progn
            (setq cooked--draining t
                  cooked--drain-pending nil)
            (cooked--noting-failure
              (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines
                                           cooked-scrollback-lines))
              ;; Bounded in practice: the pending flag is set by a freeze lifting,
              ;; and a freeze that has lifted does not lift again.
              (while (and cooked--drain-pending cooked--session)
                (setq cooked--drain-pending nil)
                (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines
                                             cooked-scrollback-lines)))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq cooked--draining nil
                  cooked--drain-pending nil)
            ;; The far end of the core's backpressure: one wake byte is in flight
            ;; from the drain that brought us here until this says the buffer has
            ;; been drawn, so `cooked-min-redisplay-interval' paces rendering --
            ;; which is where the milliseconds are -- rather than the taking of a
            ;; delta, which costs nothing.  Once, at the very end: the loop above
            ;; may have drained several times, and it is the last render that the
            ;; interval is measured from.
            ;;
            ;; In the cleanup rather than the body, and for a stronger reason than
            ;; tidiness: an apply that signals must still re-arm, or the core waits
            ;; on a readiness that is never declared and the buffer stops repainting
            ;; until the reader thread's own tick notices -- and `cooked-refresh',
            ;; which is the way back from a half-drawn screen, drains too.  Inside
            ;; the `with-current-buffer' for the same reason as the flags: it is
            ;; this buffer's session that owes the answer, whatever buffer a callee
            ;; has left current.  Guarded because the session can be gone by now,
            ;; killed by something the apply ran.
            (when cooked--session
              (cooked--ready cooked--session))
            ;; Also in the cleanup, though `cooked--apply' ends with it: the drain
            ;; has assertions in it (`cooked--check-seam', `cooked--guard-row-width')
            ;; and a signal out of one leaves the screen half-rewritten with the
            ;; input line moved and the anchor still naming where it used to be.
            ;; Idempotent on the ordinary path, the anchor already matching by then
            ;; -- and inside the `with-current-buffer' for the same reason as the
            ;; flags: it is this buffer's anchor it exists to check.
            (cooked--check-undo-anchor)))))))

(defun cooked--on-wake (buffer)
  "Drain BUFFER's session and apply what changed.

An error here is otherwise invisible: Emacs swallows `process-filter' errors,
and
the symptom reaches the user as a buffer that stopped updating or a point that
jumped somewhere absurd.  Name it, then repair it — a drain that signalled
part-way through leaves the screen region disagreeing with the emulator's grid,
and no later delta mends that, because a delta only says what changed.

`cooked--resyncing' guards the repair rather than the failure: a resync that
itself fails must report and stop, not recurse a redisplay error into a loop of
them.  It is cleared once a resync completes, so this is once per failure and
not once per session.

Skipped entirely while `cooked--frozen-p': the native core keeps the
authoritative grid state regardless of whether Lisp ever asks for it, so
nothing is lost by deferring — `cooked--refresh-keymap' catches the buffer up
with one more call to `cooked--drain-and-apply' the moment the freeze lifts.
Note that `cooked--frozen-p' is false for a buffer whose window is not the
selected one, so leaving a frozen buffer resumes it rather than stranding it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and cooked--session (not (cooked--frozen-p)))
        (if cooked-debug
            (cooked--drain-and-apply)
          (condition-case err
              (cooked--drain-and-apply)
            (error
             (message "cooked: redisplay failed: %S%s (point %s, cursor %S, screen-start %s)%s"
                      err
                      (if-let* (((eq (plist-get cooked-last-failure :error) err))
                                (where (plist-get cooked-last-failure :where)))
                          (format " in %s; M-x cooked-show-last-failure"
                                  (mapconcat #'symbol-name where " < "))
                        "")
                      (point) cooked--cursor
                      (cooked--screen-start-position)
                      (if cooked--resyncing "" "; resyncing"))
             (unless cooked--resyncing
               (let ((cooked--resyncing t))
                 (condition-case again
                     (cooked-refresh)
                   (error (message "cooked: resync failed too: %S" again))))))))))))

;;;; Applying an update

(defcustom cooked-clear-selection-on-output t
  "Whether output that rewrites the selected text takes the selection with it.

A region is a claim about particular text, and the child rewriting that text
makes the claim into a lie -- an invisible one, because the highlight stays.
`cooked--render-rows\=' deletes and reinserts each damaged row whole, so a mark
inside one collapses to that row\='s start and the region visibly warps under
live output; the drain re-pins point (see `cooked--apply\='), and nothing ever
did the same for the mark.  Every xterm-family terminal drops a selection whose
cells are overwritten, for the reason this does.

Only a region whose text was actually rewritten.  Output elsewhere -- a
spinner, a status line, the next line of a log -- leaves a selection alone: the
selected text is compared across the redraw, and kept when it is still exactly
what was selected.  The scrollback is text the child has finished with and can
no longer reach, so a region up there always means what it did when it was
drawn.

nil keeps the mark wherever it is.  Defensible if you never select the live
screen; if you do, the region you are left holding is not the one you drew."
  :type 'boolean
  :group 'cooked)

(defconst cooked--stale-mark-compare-limit 200000
  "Largest selection, in characters, compared across a redraw.
A larger one is dropped whenever output arrives rather than copied every
drain; see `cooked-clear-selection-on-output'.")

(defun cooked--following-windows ()
  "Other windows on this buffer whose point should track the child's cursor.

The selected window's point *is* the buffer's point for as long as it stays
selected — Emacs keeps the two in sync on its own, which is what `follow' and
`wandered' below ride on.  No such thing happens for any other window
showing the same buffer: its `window-point' is a value Emacs stores and
redisplays from independently, touched only by `set-window-point', so a
second window on a busy cooked buffer would otherwise freeze wherever it
last happened to be pointed, deaf to every later drain.

A window's own point, not the buffer's, decides whether it is still
following, mirroring `follow' one level down: scrolling that window with the
wheel or a scrollbar does not move its point, so such a window is left alone
here for the same reason `follow' would leave the buffer's point alone for
the same case — it reads as the user choosing to look elsewhere, not as a
window that fell behind."
  (when-let* ((start (cooked--screen-start-position)))
    ;; Never a dock, which `cooked--after-scroll-hook' places itself, nor the
    ;; window above one: that window is docked because it was scrolled away
    ;; from the bottom, and following would be undoing exactly that.
    (seq-filter (lambda (w) (and (>= (window-point w) start)
                                 (not (cooked--dock-window-p w))
                                 (not (window-live-p
                                       (window-parameter w 'cooked-dock)))))
                (delq (selected-window) (get-buffer-window-list nil nil t)))))

(defun cooked--install-resources (update)
  "Record the images and links UPDATE's rows refer to by id.

Before any rendering: this is the drain's third category -- neither a level
redisplay reads nor an occurrence to react to, but a resource the rows depend
on.  Touches no buffer text, so it needs no `inhibit-read-only'."
  (cooked--install-images (plist-get update :images))
  (cooked--install-links (plist-get update :links)))

(cl-defstruct (cooked-viewport (:constructor cooked--viewport-make) (:copier nil))
  "What the view looked like before a drain rewrote the screen under it.

Every field has to be read before the render, because afterwards the thing it
describes is gone: the pending input has been lifted out, the rows point and the
mark named have been deleted and reinserted, and which windows counted as
following has already been decided by the deletion dragging their point along.

Restored by `cooked--place-point' and `cooked--scroll-windows', in that order
and both from `cooked--apply' -- point first, because where the windows are
scrolled to is decided against where point ended up.

Captured by one function and put back by two, which is the design rather than an
omission: the fields are read in a single pass because the render is about to
invalidate every one of them at once, while they are answered at different
points in `cooked--apply''s order, with the mark cleared and the alt-screen pin
applied in between.  So there is no one restore to pair with the capture, and
looking for one is looking for the wrong shape."
  (editing nil :documentation "\
Point's offset within the pending input, or nil if it was not in there.

An offset rather than a position: the input is taken out and put back verbatim
around the child's cursor on every drain, so a buffer position cannot survive
that but an offset into the text can.  Without it, anything that drains while
the user is editing mid-line -- a background job printing a line, a completion
reply -- yanks them to the end of what they were typing.")
  (follow nil :documentation "\
Whether to track the child's cursor, or leave point where the user put it.

Asked of the mode and of where point is, not by comparing point against the
cursor: output arriving in chunks lets the cursor overtake point for a single
drain, which strands point at column 0 for every drain after it.")
  (wandered nil :documentation "\
The screen cell point sat on, when it had wandered off the cursor.

A redraw deletes and reinserts whole rows, so a buffer position would be dragged
to the start of whatever was rebuilt under it.  The cell survives that.")
  (stale-mark nil :documentation "\
The selected text, when an active region reaches into the live screen.

Unlike point the mark cannot be re-found afterwards -- there is no cell to look
it up by, only a claim about text -- so the claim is written down while it
still has an answer, and checked after the render: a region still covering
exactly this text was not rewritten and stays; anything else is dropped.  t
for a region too large to compare, which is dropped whenever output arrives.
See `cooked-clear-selection-on-output'.")
  (others nil :documentation "\
The other windows on this buffer that were following the child's cursor.")
  (held nil :documentation "\
The windows that were not following, each with the screen cell its start was on.

A window left looking at the live screen -- one scrolled back a little, or the
window above a dock -- shows rows the drain is about to rewrite.  Its start is a
buffer position, and the row under it is deleted and reinserted, so the window
would show whatever text the redraw happened to leave there.  The cell is kept
instead and carried across the scroll; see `cooked--map-cell'."))

(defun cooked--capture-viewport ()
  "Snapshot the view, before the render invalidates every part of it."
  (cooked--viewport-make
   :editing (when-let* ((region (cooked--input-region))
                        ((<= (car region) (point) (cdr region))))
              (- (point) (car region)))
   :follow (and (cooked--follow-p)
                (>= (point) (cooked--screen-start-position)))
   :wandered (and cooked--wandered (cooked--screen-cell))
   :stale-mark (and cooked-clear-selection-on-output
                    mark-active (mark)
                    (>= (max (mark) (point)) (cooked--screen-start-position))
                    (let ((beg (min (mark) (point))) (end (max (mark) (point))))
                      (if (> (- end beg) cooked--stale-mark-compare-limit)
                          t
                        (buffer-substring-no-properties beg end))))
   :others (cooked--following-windows)
   :held (cooked--held-windows)))

(defun cooked--held-windows ()
  "The non-following windows on this buffer whose start is on the live screen.
Each as (WINDOW . CELL), for `cooked--viewport-held'."
  (when-let* ((screen (cooked--screen-start-position)))
    (let ((following (cooked--following-windows))
          (follow (and (cooked--follow-p) (>= (point) screen)))
          held)
      (dolist (w (get-buffer-window-list nil nil t) held)
        (unless (or (memq w following)
                    (and follow (eq w (selected-window)))
                    (cooked--dock-window-p w))
          (when-let* ((cell (and (>= (window-start w) screen)
                                 (cooked--screen-cell (window-start w)))))
            (push (cons w cell) held)))))))

(defun cooked--map-cell (cell spans batch-start)
  "Where the text that was at screen CELL before this drain is now.

SPANS is the drain's `:scrolled-spans', (START . CHARS) per row that left the
screen, oldest first; BATCH-START is where that scrollback text was inserted.
The screen moved up by one row for each of them, so a row still on it is that
many rows higher, and one that left is in the batch at its span.  With nothing
scrolled the cell itself is the answer."
  (let ((n (length spans))
        (row (car cell))
        (col (cdr cell)))
    (if (or (null batch-start) (>= row n))
        (save-excursion
          (cooked--goto-screen-cell (cons (- row (if batch-start n 0)) col))
          (point))
      (let ((span (nth row spans)))
        (min (point-max) (+ batch-start (car span) (min col (cdr span))))))))

(defun cooked--apply-levels (update)
  "Adopt UPDATE's levels: the state as of this drain, for redisplay to read."
  (setq cooked--cursor (cooked--cursor-decode (plist-get update :cursor))
        ;; Before `cooked--fit-screen', which is shaped by it.
        cooked--grid (cooked--grid-make :height (plist-get update :height)
                                        :used (plist-get update :used)
                                        :head (plist-get update :head))
        cooked--app-cursor (plist-get update :app-cursor)
        cooked--keys (plist-get update :keys)
        cooked--exit (plist-get update :exit))
  (cooked--set-alt (plist-get update :alt))
  (cooked--set-mode (plist-get update :mode)))

(defvar-local cooked--batch-start nil
  "Where this drain's scrollback was inserted, or nil if nothing scrolled.")

(defvar-local cooked--scrolled-spans nil
  "This drain's `:scrolled-spans'; see `cooked--map-cell'.")

(defun cooked--restore-held-windows (viewport)
  "Put each held window of VIEWPORT back on the text it was showing.
Its vertical scroll is kept: a pixel-scrolled window stays where it was to the
pixel, which is what keeps a scroll in progress from being fought."
  (pcase-dolist (`(,w . ,cell) (cooked-viewport-held viewport))
    (when (and (window-live-p w) (eq (window-buffer w) (current-buffer)))
      (let ((start (save-excursion
                     (goto-char (cooked--map-cell cell cooked--scrolled-spans
                                                  cooked--batch-start))
                     (line-beginning-position)))
            (vscroll (window-vscroll w t)))
        (unless (= start (window-start w))
          (set-window-start w start t)
          (unless (zerop vscroll) (set-window-vscroll w vscroll t)))))))

(defun cooked--place-point (viewport)
  "Put point where VIEWPORT says it belongs, now that the render is done.

`editing' outranks `follow' rather than sharing an arm with it: point inside the
pending input is a claim about the line being typed, and the end of that line is
only the right answer when point was there already.  Staying put outranks both
once the user has taken the keyboard back -- the child keeps redrawing under
them, and being yanked to its cursor mid-motion is what this exists to stop.
The ghost keeps the way back visible; `cooked--snap-to-cursor' takes it."
  (let ((editing (cooked-viewport-editing viewport)))
    (cond ((cooked-viewport-wandered viewport)
           ;; Carried across the scroll: the same text, not the same cell, which
           ;; after a scroll holds newer text -- a point parked on a main screen
           ;; that keeps scrolling otherwise walks down through the transcript.
           (goto-char (cooked--map-cell (cooked-viewport-wandered viewport)
                                        cooked--scrolled-spans
                                        cooked--batch-start)))
          ;; Clamped for the drain that ends the prompt, where
          ;; `cooked--restore-pending-input' declined and left no region for the
          ;; offset to be an offset into.
          (editing
           (goto-char (if-let* ((start (cooked--input-start-position)))
                          (min (+ start editing) (cooked--point-after-input))
                        (cooked--point-after-input))))
          ((cooked-viewport-follow viewport)
           (goto-char (cooked--point-after-input))))))

(defvar cooked--after-scroll-hook nil
  "Run in the buffer after each drain has scrolled its windows.
cooked-dock.el keeps its docks pinned from here.")

(defvar cooked-drain-functions nil
  "Abnormal hook run in the session's buffer once each drain is fully applied.

Called with no arguments, after the render, the events, point and the windows
have all settled -- so `cooked--cursor' and the buffer agree, and what an entry
sees is what the user is about to see.  For a layer that waits on the child's
answer to something it sent: cooked-program-line.el watches here for a program
to echo the keys it was given.

Run through `cooked--run-seam', so an entry that signals is reported and does
not take the drain with it.")

(defun cooked--restore-scroll-settings ()
  "Put back the scroll settings `cooked-mode' gave this buffer, if they moved.

The window is positioned by `cooked--pin-transcript-bottom', and redisplay only
leaves that alone while `scroll-conservatively' is above 100 and
`scroll-margin' is 0.  With anything less it recentres whenever output moves
the cursor further than that, and the prompt lurches to the middle of the
window.  Packages that tune scrolling change these globals for the duration of
a scroll and `setq' them back from a timer, in whatever buffer is current when
it fires -- ultra-scroll does exactly that -- which writes another buffer's
value over this buffer's own.  Checked once per drain, two comparisons."
  (unless (and (eql scroll-conservatively 101) (eql scroll-margin 0))
    (setq-local scroll-conservatively 101
                scroll-margin 0)))

(defun cooked--scroll-windows (viewport)
  "Scroll every window on this buffer to what VIEWPORT and the new grid want.

Explicit rather than left to redisplay, and the honest reason is narrower than
it used to be stated here.  `scroll-conservatively' *is* a guarantee for the
selected window whatever moved its point: `redisplay_window' compares the
window's start against its point and has no idea whether a command or a process
filter did the moving.  What redisplay will not do is move a *non-selected*
window, whose `window-point' nothing here has touched, and what it will not
decide is the policy question -- whether the last line belongs at the foot of
the window with nothing below it, which is what `comint-scroll-show-maximum-
output' gates comint's own recentring on.

The selected window belongs in none of these lists unless it is actually showing
this buffer: output can arrive while the user's focus is elsewhere, and
scrolling that window would be a bug rather than a courtesy."
  (cooked--restore-scroll-settings)
  (let ((here (and (eq (window-buffer (selected-window)) (current-buffer))
                   (list (selected-window))))
        (others (cooked-viewport-others viewport)))
    (if cooked--alt
        (cooked--pin-alt-screen (append here others))
      (cooked--scroll-transcript viewport here others)))
  (run-hooks 'cooked--after-scroll-hook))

(defun cooked--pin-alt-screen (windows)
  "Put the alternate screen back at the top of each of WINDOWS.

A resize reaches the buffer in two steps: the window changes height the instant
Emacs notices (`cooked--sync-size'), while the buffer is not re-fitted to match
until the next drain's `cooked--fit-screen'.  Ordinary redisplay fills that gap
by pushing `window-start' down to keep point on screen, and nothing corrected
that once the buffer caught up -- so the window kept a scroll a now-irrelevant
redisplay had chosen, clipping the top of the screen.

Unconditional, and the restriction `cooked--apply-alt-pin' re-applies is what
makes that safe: every window here shows the screen region and nothing else, so
the region's top is the only start any of them can hold.  NOFORCE stays, because
forcing would drag point along with it."
  (let ((top (cooked--screen-start-position)))
    (cooked--dolist-windows w windows
      (set-window-start w top t))))

(defun cooked--bottom-start (window &optional foot)
  "The start that puts FOOT, default the buffer's last row, on WINDOW's last row.

Every row ends in a newline, the last included, so `point-max' is the start of
an empty line below the last row rather than a place on it.  Measured from
there the window kept that empty line at its foot and paid for it with a row of
real text off the top."
  (let* ((foot (or foot (point-max)))
         (foot (if (and (= foot (point-max)) (> foot (point-min))
                        (eq (char-before foot) ?\n))
                   (1- foot)
                 foot))
         (body (window-body-height window t))
         (start (save-excursion
                  (goto-char foot)
                  (vertical-motion (- (1- (cooked--window-rows window))) window)
                  (point))))
    ;; Counted in rows, then checked in pixels: a row taller than the default
    ;; line -- a fallback font's glyph, an emoji, a picture -- pushes the foot
    ;; below the window by the difference, and the last row, which is the one
    ;; that matters, is the one cut off.  Each row given up at the top buys
    ;; that row's height back at the bottom.
    (while (and (< start foot)
                (> (cooked--rows-height window start foot body) body))
      (setq start (save-excursion (goto-char start)
                                  (vertical-motion 1 window)
                                  (point))))
    start))

(defun cooked--rows-height (window from to &optional limit)
  "The pixels WINDOW takes to show the rows from FROM's through TO's.

`window-text-pixel-size' gets the height of the first row wrong when it starts
measuring there -- by twelve pixels, under `line-spacing', for a row beside an
image -- so it is asked from the row above FROM, twice, and the error cancels:
the rows wanted are the difference between the two.

With LIMIT, a number of pixels, the rows are not measured at all when they
plainly take more than that, and the answer is then only some height above
LIMIT.  Every caller asking whether rows fit a window wants that and no more --
and without it, a window scrolled up into a long history measured all of it, to
its end, after every command anywhere in the frame: a wheel turning in the
buffer beside a terminal allocated hundreds of megabytes doing so, and every
garbage collection that bought was a hitch in the scroll.

Plainly is in rows, found with `vertical-motion': rows past LIMIT\='s worth of
default-height lines, and two more, cannot fit, since no row of a terminal is
shorter than the default line.  It is not `window-text-pixel-size\=''s own
Y-LIMIT, which stops at the last whole line above the limit and so answers
with a height *under* it for rows that do not fit: every window scrolled up
looked as if it still showed its bottom, and none was ever docked."
  (save-excursion
    (goto-char to)
    (let ((end (line-end-position)))
      (goto-char from)
      (if (and limit
               (< (save-excursion
                    (vertical-motion
                     (+ 2 (ceiling limit (window-default-line-height window)))
                     window)
                    (point))
                  end))
          (1+ limit)
        (if (zerop (vertical-motion -1 window))
            (cdr (window-text-pixel-size window from end))
          (let ((anchor (point)))
            (- (cdr (window-text-pixel-size window anchor end))
               (cdr (window-text-pixel-size window anchor (1- from))))))))))

(defun cooked--clamp-overscroll ()
  "Undo a scroll past the bottom of a window that is following the output.

A terminal's last row is as far down as there is to go, but Emacs lets a window
scroll on until only its last line is left at the top.  While the view follows
the child, the next drain pins the bottom back -- so each wheel notch past the
end scrolled down a line and the next frame scrolled it back up, and the window
jittered for as long as the wheel turned.  Clamped here, from
`post-command-hook', the overshoot is undone before redisplay ever shows it.
The pixel vscroll goes too: a precision scroll leaves a remainder that
survives being told where the window starts.

Only while following, and only downward: a window being read is the user's to
scroll, and scrolling it down to the input is how reading ends.

A pixel scroll -- ultra-scroll, `pixel-scroll-precision-mode' -- moves the
vertical scroll first and the start only once a whole row has gone by, so at
the pinned start any vertical scroll at all is already past the bottom.
Clamping only a start beyond the pin let each notch slide the text up by a few
pixels and the row after snap it back: a sawtooth as fast as the wheel turned."
  (when (and cooked--session (not cooked--alt) (cooked--follow-p))
    (let ((window (selected-window)))
      (when (eq (window-buffer window) (current-buffer))
        (let ((top (if cooked--pin-screen-top
                       ;; A cleared display is shown from its top, below the
                       ;; transcript it archived -- further down than the bottom
                       ;; pin, and on purpose; see `cooked--scroll-transcript'.
                       (max (cooked--bottom-start window)
                            (cooked--screen-start-position))
                     (cooked--bottom-start window)))
              (start (window-start window)))
          (when (or (> start top)
                    (and (= start top) (> (window-vscroll window t) 0)))
            (set-window-vscroll window 0 t)
            (set-window-start window top t)))))))

(defun cooked--pin-transcript-bottom (windows &optional pos bottom)
  "Follow POS, defaulting to `point-max\=', with the bottom row of each of WINDOWS.

BOTTOM, defaulting to POS, is what the bottom row is computed against: the
child's cursor can sit above text it has already printed -- a couple of
trailing lines below where the cursor ultimately rests is an ordinary shape
for a non-TUI program that prints and then repositions -- and it is that
trailing text, not the cursor, that must not be scrolled out of view.  POS
still decides window-point, so editing and the caret stay at the cursor.

Factored out of `cooked--scroll-transcript\=' because a drain is not the only
thing that can grow the buffer\='s true end.  `cooked--on-exit\=' does too,
appending the \"[exited N]\=\" line from outside `cooked--scroll-windows\='
entirely, and it needs exactly this rather than a second copy of it.

Computed and NOFORCE, rather than the `recenter\=' this used to be.
`recenter\=' sets a forced start that redisplay then overrules through
`make-cursor-line-fully-visible\=', so the window landed where neither of them
had chosen; and it counts every screen line as the default font\='s height, so a
row taller than that -- an image slice, a Nerd Font prompt separator -- had to
be paid back afterwards in whole lines of scroll.  A NOFORCE start is a
suggestion redisplay may settle against instead, and the pixels are
`make-cursor-line-fully-visible\='s business, which is where they were always
handled correctly.  No `with-selected-window\=' either: nothing here needs the
window selected, and `select-window\=' is advised -- by `evil\=', to refresh its
cursor -- so a pair of them per window per drain was arbitrary code running in
the middle of a render.

Monotone, which is what stops this jittering.  The follow direction is taken
whenever the tail has grown, and the equality is the common case: a steady
stream whose tail is the same length leaves TOP exactly where it already is and
this writes nothing at all, at a drain rate whose floor is
`cooked-min-redisplay-interval\='.  The shrink direction is the one thing the
two-way pin was buying -- `comint-scroll-show-maximum-output\='s actual
semantics, no blank space below the last line -- and is taken only when the
*last* redisplay had the buffer\='s end on screen, so it fires when the grid
really has fewer used rows than before rather than every time
`vertical-motion\='s whole-line count disagrees with what redisplay laid out in
pixels.  That disagreement is permanent on a window whose rows differ in height,
and correcting for it once per drain is the oscillation itself."
  (let* ((target (or pos (point-max)))
         (foot (or bottom target)))
    (cooked--dolist-windows w windows
      (set-window-point w target)
      (let ((top (cooked--bottom-start w foot)))
        (when (or (> top (window-start w))
                  (and (< top (window-start w))
                       (let ((end (window-end w)))
                         (and end (>= end (point-max))))))
          (set-window-start w top t))
        ;; A window that follows has its last row on its last line, to the
        ;; pixel: a vertical scroll left over from a pixel scroll would hold
        ;; the bottom row part-way out of view for as long as the output ran.
        (unless (zerop (window-vscroll w t))
          (set-window-vscroll w 0 t))))))

(defun cooked--scroll-transcript (viewport here others)
  "Scroll the transcript in HERE and OTHERS as VIEWPORT asks."
  (let* ((target (cooked--point-after-input)))
    ;; Only while the view is following at all: suspending exists to stop the
    ;; child's output moving what is being read, and a second window on the same
    ;; buffer is being read on the same terms.
    (when (cooked--follow-p)
      (cooked--dolist-windows w others
        (set-window-point w target)))
    (cond
     ;; The child cleared the display.  Its rows were archived rather than
     ;; dropped, so nothing scrolls out of view on its own, and recentring on the
     ;; cursor would leave the transcript filling the window above a blank screen
     ;; -- which is `clear' looking like it did nothing.
     ((and (cooked-viewport-follow viewport) cooked--pin-screen-top)
      (let ((top (cooked--screen-start-position)))
        (cooked--dolist-windows w (append here others)
          (set-window-start w top t))))
     ;; The pin's own foot is `point-max', not TARGET: a non-TUI child can print
     ;; a few trailing lines below where its cursor ultimately rests -- printing
     ;; output and then repositioning is ordinary -- and it is that trailing
     ;; text, not the cursor, whose bottom edge decides the window's scroll.
     ((cooked-viewport-follow viewport)
      (cooked--pin-transcript-bottom (append here others) target (point-max))))))

(defun cooked--apply (update)
  "Apply UPDATE, the plist returned by `cooked--drain'.

The order below is the whole of it, and every step depends on the one above:
resources before the rows that name them, the viewport before the render that
invalidates it, the render before the marks resolved against the text it wrote,
and the region shaped before anything measures it."
  (cooked--install-resources update)
  ;; Between frames, never inside one: a face handed out earlier in this drain is
  ;; already on text, and the table it came from can go without it noticing.
  (cooked--trim-face-cache)
  ;; `let*', emphatically: these initialisers delete and insert, and under plain
  ;; `let' they would run before the two bindings above them took effect -- so a
  ;; protected buffer would abort the redisplay half-done from inside the process
  ;; filter, and lifting the pending input would land in the undo history.  They
  ;; are the pair `cooked--with-child-edit' binds, spelled out because a body this
  ;; long is not worth nesting one level deeper.
  (let* ((inhibit-read-only t)
         (buffer-undo-list t)
         (viewport (cooked--capture-viewport))
         (pending (cooked--take-pending-input))
         ;; Where this drain's scrollback landed, for resolving a `scrolled'
         ;; anchor against.  nil when the drain evicted nothing.
         (batch-start (when-let* ((scrolled (plist-get update :scrolled)))
                        (cooked--render-scrolled scrolled)))
         (rendered (cooked--render-rows (plist-get update :rows)
                                        (plist-get update :alt))))
    (setq cooked--batch-start batch-start
          cooked--scrolled-spans (plist-get update :scrolled-spans))
    (cooked--apply-levels update)
    ;; Cleared before the events, so a drain that both scrolls and then clears
    ;; stays pinned.
    (when batch-start (setq cooked--pin-screen-top nil))
    ;; After both render passes and before the events: a mark's anchor is
    ;; resolved against text that has to be in the buffer before it can be
    ;; pointed at, and a drain that both resizes and carries a fresh mark should
    ;; end with the fresh mark's own anchor.
    (cooked--relocate-marks (plist-get update :marks) batch-start)
    (dolist (event (plist-get update :events))
      (cooked--handle-event event batch-start))
    ;; Rows the core dropped instead of sending, as the scrollback cap would have
    ;; trimmed them: tidy up after them the way `cooked--discard-scrollback' tidies
    ;; up after a trim.  After the events, which is where their marks landed.
    (when (and batch-start (> (or (plist-get update :dropped) 0) 0))
      (cooked--forget-dropped batch-start (plist-get update :dropped-images)))
    ;; After both, which is the ordering `cooked-row-rendered-functions' is
    ;; documented against.
    (cooked--notify-rows-rendered rendered)
    (cooked--fit-screen)
    (cooked--pad-to-cursor)
    ;; Immediately before the assertion, which is the whole reason it is here
    ;; rather than riding `cooked--trim-scrollback' at the foot of the drain.
    ;; The two are one subject -- the seam the emulator and the buffer co-own --
    ;; and a drain that evicts a wrapped row with `cooked-rejoin-wrapped-lines'
    ;; off remakes the emulator's claim about a continuation the buffer never
    ;; took.  Reset after the assertion had already looked, the claim was still
    ;; standing when it looked, which is why the assertion had to exclude this
    ;; mode instead of covering it.  See `cooked--split-seam'.
    (cooked--split-seam)
    (when cooked-debug (cooked--check-seam))
    (cooked--restore-pending-input pending)
    (cooked--protect (or (and (cooked--input-state-p) (cooked--input-start-position))
                         (point-max)))
    (cooked--apply-alt-pin)
    ;; Before the point block, not after it: under evil this leaves visual state,
    ;; and evil adjusts point on the way into normal state -- so cooked's own pin
    ;; has to be the last thing to speak about where point ends up.
    (when-let* ((selected (cooked-viewport-stale-mark viewport)))
      (unless (and (stringp selected) mark-active (mark)
                   (equal selected (buffer-substring-no-properties
                                    (min (mark) (point)) (max (mark) (point)))))
        (cooked--deactivate-mark)))
    (cooked--place-point viewport)
    (cooked--restore-held-windows viewport)
    ;; Recorded, not merely left in the buffer: a window not showing this buffer
    ;; has a stale point marker Emacs will restore on the way back, over the top
    ;; of this.  See `cooked--point'.
    (setq cooked--point (point))
    (cooked--scroll-windows viewport)
    ;; After `cooked--scroll-windows', which is what decides where each window's
    ;; start belongs: forcing a window before that would force it a second time
    ;; once the start then moved.  See `cooked--repaint-pending'.
    (cooked--flush-pending-repaint)
    ;; After the window block, not before it: see `cooked--sync-cursor-type'.
    (cooked--sync-cursor-type)
    (cooked--update-ghost-cursor)
    ;; Last before an exit is handled: everything above has settled, so a
    ;; function here sees the buffer, the cursor and point as this drain left
    ;; them.
    (cooked--run-seam 'cooked-drain-functions)
    (when cooked--exit (cooked--on-exit cooked--exit)))
  ;; Both outside the `let*', and in this order.  The binding above is what kept
  ;; this drain out of the undo history, and a discard has to reach the buffer's
  ;; own list rather than that binding -- which is also why the trim cannot run
  ;; inside: it moves the input line, and the `cooked--check-undo-anchor' it does
  ;; for itself would then update the anchor against a discard that was thrown
  ;; away with the binding, leaving the history vouched for by an anchor nothing
  ;; ever cleared.  See `cooked--with-child-edit'.
  (cooked--trim-scrollback)
  (cooked--check-undo-anchor))

(defconst cooked--replay-osc-codes '(0 1 2 7)
  "OSC codes still honoured while a replay is in progress.

The title and the working directory: what they set is state a later drain
depends on, and setting it twice does nothing the first time did not.  Every
other code either asks a question, whose answer would be typed at a child that
stopped waiting for it long ago, or asks for an effect.")

(defun cooked--replay-osc-p (code parts)
  "Whether the OSC with CODE and PARTS is honoured while a replay is in progress.

`cooked--replay-osc-codes', and one more: the shell's announcement of its
completion channel, `OSC 51;CH'.  It is of a kind with the title and the
directory -- a `setq' of inert, validated data that says what the prompt on
screen can do, cleared again by the marks that follow it -- and without it a
shell that is attached to at its prompt would not be known to complete until
the next one.  The rest of OSC 51 asks for things, and stays out."
  (or (memq code cooked--replay-osc-codes)
      (and (eql code 51)
           (stringp (car parts))
           (string-prefix-p "CH" (car parts)))))

(defvar cooked-replay-end-functions nil
  "Abnormal hook run in a session buffer when a replay has finished.

Each function is called with one argument, non-nil if the replay started
part-way through the session rather than at its beginning -- in which case the
screen is what the recent output happened to leave on it, and a full-screen
program has to be asked to draw itself again.")

(defun cooked--handle-event (event batch-start)
  "Dispatch a single EVENT from the emulator.

BATCH-START is where this drain's scrollback was inserted, which the semantic
marks need to place their anchors; see `cooked--anchor-position'.

Events are occurrences only.  State the redisplay depends on rides the drain's
own fields instead — `:alt' and the rest — so that nothing arrives twice with
two chances to disagree."
  (pcase event
    ;; The three that act rather than record, and so the three a replay must not
    ;; repeat; see `cooked--replaying'.  An OSC is let through only where it says
    ;; what state the terminal is in -- its title, its directory -- and never
    ;; where it asks for something to be done.
    (`(bell) (unless cooked--replaying (ding)))
    (`(osc ,code ,bell . ,parts)
     (when (or (not cooked--replaying) (cooked--replay-osc-p code parts))
       (cooked--handle-osc code bell parts)))
    (`(reply . ,bytes) (unless cooked--replaying (cooked--send-if-live bytes)))
    (`(replay-end ,truncated)
     (setq cooked--replaying nil)
     (run-hook-with-args 'cooked-replay-end-functions truncated))
    (`(title-stack ,push) (cooked--handle-title-stack push))
    ;; `CSI 3 J', the tail of what `clear' sends.  Honoured unconditionally: it is
    ;; only reachable by something already holding the terminal, every other terminal
    ;; honours it, and it is precisely what the user typed `clear' to get.  The
    ;; command history is not lost with it: that lives in comint's ring, not here.
    (`(erase-scrollback)
     (cooked--discard-scrollback (cooked--screen-start-position)))
    (`(display-cleared) (setq cooked--pin-screen-top t))
    ;; Decoded into a record at the boundary, like the cursor and the grid; see
    ;; `cooked-mouse-state'.  cooked-mouse.el owns it because it is the only
    ;; reader, and re-gates its own keymap on the way through.
    (`(mouse ,enabled ,sgr ,drag ,motion)
     (cooked--set-mouse-state enabled sgr drag motion))
    ((or `(prompt-start ,_ . ,_) `(prompt-continuation ,_ . ,_)
         `(prompt-end ,_ . ,_)
         `(command-start ,_ ,_ . ,_) `(command-end ,_ ,_ . ,_))
     (cooked--handle-semantic event batch-start))
    (_ nil)))

;;;; Starting over

(defun cooked-refresh ()
  "Rebuild the live screen from the emulator.

The way back from a redisplay that failed part-way.  An ordinary drain only
reports what changed since the last one, so it cannot repair a buffer holding
some rows of a drain that signalled halfway through applying them — the screen
region and the emulator's grid simply stay out of step, and every later delta is
applied on top of the disagreement.  This throws the screen region away and asks
the native core to re-send all of it.

The scrollback above is untouched, and so is the emulator's carry count with it:
only the region below `cooked--screen-start' is rebuilt."
  (interactive)
  (when cooked--session
    (save-restriction
      (widen)
      (cooked--with-child-edit
        (cooked--release-alt-pin)
        (delete-region (cooked--screen-start-position) (point-max))
        ;; They pointed into the text just deleted; `cooked--restore-pending-input'
        ;; puts them back at the cursor on the drain below.
        (cooked--clear-input-region)))
    ;; Here rather than left to the drain below, which would see the rebuilt
    ;; input line start where the old one did and conclude that nothing moved --
    ;; while every entry in the history was recorded against text this has just
    ;; deleted and the child is about to re-send.  Outside the macro, for the
    ;; reason given there.
    (cooked--check-undo-anchor)
    (cooked--redraw cooked--session)
    (cooked--drain-and-apply)))

(provide 'cooked-render)
;;; cooked-render.el ends here
