;;; org-typora-math.el --- Live Org math previews while editing -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: outlines, tex, multimedia
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Show editable formula source together with an asynchronous SVG preview.
;; Inline formulas use a child frame; display formulas use an overlay panel.
;; Outside the active formula, an image replaces the source visually.
;; Enable `org-typora-math-mode' in an Org buffer.  LaTeX and dvisvgm are
;; required.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'ox-latex)
(require 'color)

(defgroup org-typora-math nil
  "Live, asynchronous math previews in Org."
  :group 'org-latex)

(defcustom org-typora-math-idle-delay 0.6
  "Seconds without buffer edits before updating previews."
  :type 'number)

(defcustom org-typora-math-scale 2.0
  "Scale of the generated SVG images."
  :type 'number)

(defcustom org-typora-math-display-center 'window
  "Horizontal position of the center of display formula previews.
`window'      the center of the window text area.
`fill-column' column `fill-column'/2, the center of filled text.
An integer N  column N.
A float F     the fraction F of the text area width, from its left edge.
Columns use the width of the default font.  The setting applies the
next time a formula is redrawn."
  :type '(choice (const :tag "Window center" window)
                 (const :tag "Half of fill-column" fill-column)
                 (integer :tag "Column")
                 (float :tag "Fraction of window width")))

(defcustom org-typora-math-inline-popup t
  "Use a child frame for the active inline formula on graphical displays.
When nil, display its preview on a separate overlay line instead."
  :type 'boolean)

(defcustom org-typora-math-latex-program "latex"
  "LaTeX executable producing preview.dvi."
  :type 'string)

(defcustom org-typora-math-dvisvgm-program "dvisvgm"
  "Executable converting DVI to SVG."
  :type 'string)

(defcustom org-typora-math-process-timeout 15
  "Maximum seconds allowed for each external compilation stage."
  :type 'number)

(defcustom org-typora-math-cache-directory
  (locate-user-emacs-file "org-typora-math/")
  "Directory where rendered SVG images are kept between sessions.
Each file is named after a hash of the complete TeX document.
When nil, images are cached in memory only."
  :type '(choice (const :tag "Memory only" nil) directory))

(defconst org-typora-math--cache-version "1"
  "Version of the cache key.  Change it when the output format changes.")

(defconst org-typora-math--latex-arguments
  '("-interaction=nonstopmode" "-halt-on-error" "-no-shell-escape" "preview.tex")
  "Arguments of the LaTeX program.")

(defconst org-typora-math--dvisvgm-arguments
  '("--no-fonts" "--exact-bbox" "--bbox=min" "--output=preview.svg" "preview.dvi")
  "Arguments of the dvisvgm program.")

(defface org-typora-math-source
  '((((class color) (background light)) :background "#f5f6f7" :extend t)
    (((class color) (background dark)) :background "#252a31" :extend t))
  "Face for the source of the formula being edited.")

(cl-defstruct (org-typora-math--item (:constructor org-typora-math--item-create))
  overlay source block key svg attempted error
  image width image-svg image-scale)

(defvar org-typora-math-mode nil)
(defvar-local org-typora-math--items nil)
(defvar-local org-typora-math--active nil)
(defvar-local org-typora-math--timer nil)
(defvar-local org-typora-math--timeout nil)
(defvar-local org-typora-math--process nil)
(defvar-local org-typora-math--directory nil)
(defvar-local org-typora-math--queue nil)
(defvar-local org-typora-math--generation 0)
(defvar-local org-typora-math--cache nil)
(defvar-local org-typora-math--frame nil)
(defvar-local org-typora-math--popup-buffer nil)
(defvar-local org-typora-math--restore-fragtog nil)
(defvar-local org-typora-math--log nil)
(defvar-local org-typora-math--preamble nil
  "Cons of the inputs and the text of the latest snippet preamble.")
(defvar-local org-typora-math--pending nil
  "Non-nil when a refresh was skipped because the buffer was not on screen.")

(defun org-typora-math--visible-p ()
  "Return non-nil when a window on any frame shows the current buffer."
  (and (get-buffer-window (current-buffer) t) t))

(defun org-typora-math--cancel-timer (symbol)
  "Cancel the buffer-local timer stored in SYMBOL."
  (when (timerp (symbol-value symbol))
    (cancel-timer (symbol-value symbol)))
  (set symbol nil))

(defun org-typora-math--cancel-job ()
  "Cancel the running job and discard queued work."
  (cl-incf org-typora-math--generation)
  (setq org-typora-math--queue nil)
  (org-typora-math--cancel-timer 'org-typora-math--timeout)
  (when (processp org-typora-math--process)
    (set-process-sentinel org-typora-math--process #'ignore)
    (when (process-live-p org-typora-math--process)
      (delete-process org-typora-math--process)))
  (setq org-typora-math--process nil)
  (when org-typora-math--directory
    (delete-directory org-typora-math--directory t)
    (setq org-typora-math--directory nil)))

(defun org-typora-math--hide-popup ()
  "Hide the inline child frame."
  (when (frame-live-p org-typora-math--frame)
    (make-frame-invisible org-typora-math--frame)))

(defun org-typora-math--at-point ()
  "Return the tracked formula containing point, excluding its end."
  (cl-find-if
   (lambda (item)
     (let ((ov (org-typora-math--item-overlay item)))
       (and (overlay-buffer ov)
            (<= (overlay-start ov) (point))
            (< (point) (overlay-end ov)))))
   org-typora-math--items))

(defun org-typora-math--image-of (item)
  "Return the image descriptor of ITEM's last successful rendering.
Reuse the stored descriptor until the SVG or `org-typora-math-scale' changes."
  (when-let* ((svg (org-typora-math--item-svg item)))
    (unless (and (org-typora-math--item-image item)
                 (eq svg (org-typora-math--item-image-svg item))
                 (eql org-typora-math-scale (org-typora-math--item-image-scale item)))
      (setf (org-typora-math--item-image item)
            (create-image svg 'svg t :ascent 'center :scale org-typora-math-scale)
            (org-typora-math--item-width item) nil
            (org-typora-math--item-image-svg item) svg
            (org-typora-math--item-image-scale item) org-typora-math-scale))
    (org-typora-math--item-image item)))

(defun org-typora-math--width (item image)
  "Return the pixel width of IMAGE, stored in ITEM after the first call."
  (or (org-typora-math--item-width item)
      (setf (org-typora-math--item-width item) (car (image-size image t)))))

(defun org-typora-math--align (width)
  "Return a display spec that puts an image of WIDTH pixels at the center.
The center follows `org-typora-math-display-center'."
  (let ((center (pcase org-typora-math-display-center
                  ('fill-column (/ (current-fill-column) 2.0))
                  ((pred integerp) org-typora-math-display-center)
                  ((pred floatp) (cons org-typora-math-display-center 'text))
                  (_ 'center))))
    `(space :align-to (- ,center (,(round (/ width 2)))))))

(defun org-typora-math--panel (item image)
  "Return a centered overlay line displaying IMAGE of ITEM."
  (let ((width (org-typora-math--width item image)))
    (concat "\n"
            (propertize " " 'display (org-typora-math--align width))
            (propertize " " 'display image)
            "\n")))

(defun org-typora-math--popup (image position)
  "Display IMAGE in a child frame near POSITION.
Return non-nil when a popup was shown."
  (when (and org-typora-math-inline-popup (display-graphic-p)
             (eq (window-buffer (selected-window)) (current-buffer)))
    (when-let* ((pos (posn-at-point position))
                (xy (posn-x-y pos)))
      (condition-case nil
          (let* ((after-make-frame-functions nil)
                 (frame-resize-pixelwise t)
                 (parent (selected-frame))
                 (edges (window-inside-pixel-edges))
                 (size (image-size image t))
                 ;; Without fringes, Emacs keeps the last column of the
                 ;; popup window free for the truncation glyph.  Pad
                 ;; both sides by one column so the image is not cut.
                 (pad (frame-char-width parent))
                 (width (+ (* 2 pad) 2 (ceiling (car size))))
                 (height (+ 20 (ceiling (cdr size))))
                 (left (max 0 (min (+ (car edges) (car xy))
                                   (- (frame-pixel-width parent) width 4))))
                 (below (+ (nth 1 edges) (cdr xy) (line-pixel-height) 4))
                 (top (if (> (+ below height) (frame-pixel-height parent))
                          (max 0 (- (+ (nth 1 edges) (cdr xy)) height 4))
                        below)))
            (unless (buffer-live-p org-typora-math--popup-buffer)
              (setq org-typora-math--popup-buffer
                    (generate-new-buffer " *org-typora-math-popup*")))
            (with-current-buffer org-typora-math--popup-buffer
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert (propertize " " 'display `(space :width (,pad)))
                        (propertize
                         " " 'display
                         (cons 'image (plist-put (copy-sequence (cdr image))
                                                 :margin '(0 . 8)))))
                (goto-char (point-min))
                (setq-local cursor-type nil
                            mode-line-format nil
                            header-line-format nil
                            tab-line-format nil
                            display-line-numbers nil
                            left-margin-width nil
                            right-margin-width nil
                            truncate-lines t)))
            (when (and (frame-live-p org-typora-math--frame)
                       (not (eq (frame-parent org-typora-math--frame) parent)))
              (delete-frame org-typora-math--frame)
              (setq org-typora-math--frame nil))
            (unless (frame-live-p org-typora-math--frame)
              (setq org-typora-math--frame
                    (make-frame
                     `((parent-frame . ,parent) (minibuffer . nil)
                       (visibility . nil) (no-accept-focus . t)
                       (no-focus-on-map . t) (undecorated . t)
                       (desktop-dont-save . t) (skip-taskbar . t)
                       (no-other-frame . t) (fullscreen . nil)
                       (child-frame-border-width . 1) (internal-border-width . 0)
                       (left-fringe . 0) (right-fringe . 0)
                       (menu-bar-lines . 0) (tool-bar-lines . 0)
                       (tab-bar-lines . 0) (vertical-scroll-bars . nil)
                       (horizontal-scroll-bars . nil)
                       (width . 1) (height . 1)
                       (min-width . 0) (min-height . 0)
                       (background-color . ,(face-background 'default nil t))
                       (foreground-color . ,(face-foreground 'default nil t)))))
              (set-window-buffer (frame-root-window org-typora-math--frame)
                                 org-typora-math--popup-buffer))
            (set-frame-size org-typora-math--frame width height t)
            (set-frame-position org-typora-math--frame left top)
            (make-frame-visible org-typora-math--frame)
            t)
        (error (org-typora-math--hide-popup) nil)))))

(defun org-typora-math--paint-item (item)
  "Set the overlay properties of ITEM.
The popup of the active inline formula is handled by
`org-typora-math--update-popup'."
  (let ((ov (org-typora-math--item-overlay item)))
    (when (overlay-buffer ov)
      (let* ((active (eq item org-typora-math--active))
             (block (org-typora-math--item-block item))
             (image (org-typora-math--image-of item)))
        (overlay-put ov 'display nil)
        (overlay-put ov 'before-string nil)
        (overlay-put ov 'after-string nil)
        (overlay-put ov 'face
                     (and active (if block 'org-typora-math-source
                                   '(:inherit org-typora-math-source :extend nil))))
        (overlay-put ov 'help-echo (org-typora-math--item-error item))
        (when image
          (cond
           ((and active block)
            (overlay-put ov 'after-string (org-typora-math--panel item image)))
           (active)
           (block
            ;; Emacs does not recursively interpret image display properties
            ;; inside a replacement display string.  Keep the image directly
            ;; on the overlay and the alignment in a separate before-string.
            (overlay-put ov 'before-string
                         (propertize " " 'display
                                     (org-typora-math--align
                                      (org-typora-math--width item image))))
            (overlay-put ov 'display image))
           (t (overlay-put ov 'display image))))))))

(defun org-typora-math--update-popup ()
  "Move or hide the popup of the active inline formula.
When no popup can be shown, fall back to an overlay line below the formula."
  (let* ((item org-typora-math--active)
         (image (and item (not (org-typora-math--item-block item))
                     (org-typora-math--image-of item)))
         (ov (and image (org-typora-math--item-overlay item)))
         (shown (and image (overlay-buffer ov)
                     (org-typora-math--popup image (overlay-start ov)))))
    (when (and image (overlay-buffer ov))
      (if shown
          (when (overlay-get ov 'after-string)
            (overlay-put ov 'after-string nil))
        (unless (overlay-get ov 'after-string)
          (overlay-put ov 'after-string (org-typora-math--panel item image)))))
    (unless shown (org-typora-math--hide-popup))))

(defun org-typora-math--paint ()
  "Update all overlays and the popup without modifying the buffer."
  (mapc #'org-typora-math--paint-item org-typora-math--items)
  (org-typora-math--update-popup))

(defun org-typora-math--repaint-item (item)
  "Repaint ITEM, and the popup when ITEM is the active formula."
  (org-typora-math--paint-item item)
  (when (eq item org-typora-math--active)
    (org-typora-math--update-popup)))

(defun org-typora-math--post-command ()
  "Reveal the formula entered by the cursor and conceal the previous one."
  (when org-typora-math-mode
    (let ((active (org-typora-math--at-point))
          (previous org-typora-math--active))
      (unless (eq active previous)
        (setq org-typora-math--active active)
        (when previous (org-typora-math--paint-item previous))
        (when active (org-typora-math--paint-item active))
        (org-typora-math--update-popup)))))

(defun org-typora-math--window-change (&rest _)
  "Reposition the popup after scrolling or changing windows.
Also start a refresh that was postponed while the buffer was hidden."
  (when org-typora-math-mode
    (when (and org-typora-math--pending (org-typora-math--visible-p))
      (setq org-typora-math--pending nil)
      (org-typora-math--schedule))
    (if (eq (window-buffer (selected-window)) (current-buffer))
        (org-typora-math--update-popup)
      (org-typora-math--hide-popup))))

(defun org-typora-math--schedule ()
  "Debounce preview work using a buffer-local timer."
  (org-typora-math--cancel-timer 'org-typora-math--timer)
  (setq org-typora-math--timer
        (run-at-time
         org-typora-math-idle-delay nil
         (lambda (buffer)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq org-typora-math--timer nil)
               (when org-typora-math-mode
                 (if (org-typora-math--visible-p)
                     (org-typora-math--refresh)
                   (setq org-typora-math--pending t))))))
         (current-buffer))))

(defun org-typora-math--after-change (begin end _old-length)
  "Invalidate compilation after a change between BEGIN and END."
  (when org-typora-math-mode
    (org-typora-math--cancel-job)
    (dolist (item org-typora-math--items)
      (let ((ov (org-typora-math--item-overlay item)))
        (when (and (<= begin (overlay-end ov)) (>= end (overlay-start ov)))
          (setf (org-typora-math--item-key item) nil
                (org-typora-math--item-attempted item) nil)
          (overlay-put ov 'display nil))))
    (org-typora-math--schedule)))

(defconst org-typora-math--math-regexp
  "\\$\\|\\\\[([]\\|^[ \t]*\\\\begin{[A-Za-z0-9*]+}"
  "Regexp matching the possible starts of a LaTeX fragment or environment.
This is the regexp used by `org-format-latex'.")

(defconst org-typora-math--opaque-elements
  '(src-block example-block export-block comment-block fixed-width comment)
  "Element types that cannot contain LaTeX fragments.")

(defun org-typora-math--scan ()
  "Return the math elements in the buffer as (BEGIN SOURCE BLOCK) lists.
Search like `org-format-latex' does, so that Org's element cache parses
only the matched places."
  (let (found)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward org-typora-math--math-regexp nil t)
          (let* ((context (save-excursion
                            (goto-char (match-beginning 0))
                            (org-element-context)))
                 (type (org-element-type context)))
            (cond
             ((memq type '(latex-fragment latex-environment))
              (let* ((environment (eq type 'latex-environment))
                     (source (string-trim-right
                              (org-element-property :value context)))
                     ;; Affiliated keywords such as #+NAME: precede the
                     ;; environment.
                     (begin (org-element-property
                             (if environment :post-affiliated :begin) context)))
                ;; Org also parses commands such as \ref{x} as LaTeX
                ;; fragments.  Preview only math, like `org-latex-preview'.
                (when (or environment
                          (string-match-p "\\`\\(?:\\$\\|\\\\[[(]\\)" source))
                  (push (list begin source
                              (or environment
                                  (string-prefix-p "\\[" source)
                                  (string-prefix-p "$$" source)))
                        found)))
              (goto-char (max (point) (org-element-property :end context))))
             ((memq type org-typora-math--opaque-elements)
              (goto-char (max (point) (org-element-property :end context)))))))))
    (nreverse found)))

(defun org-typora-math--collect ()
  "Reconcile tracked formulas with Org's syntax tree.
Reuse overlays at the same start position, preserving the last good image."
  (let ((old org-typora-math--items) items)
    (pcase-dolist (`(,begin ,source ,block) (org-typora-math--scan))
      (let ((item (cl-find-if
                   (lambda (it)
                     (= begin (overlay-start (org-typora-math--item-overlay it))))
                   old))
            (end (+ begin (length source))))
        (unless item
          (setq item (org-typora-math--item-create
                      :overlay (make-overlay begin end nil nil t))))
        (setq old (delq item old))
        (move-overlay (org-typora-math--item-overlay item) begin end)
        (overlay-put (org-typora-math--item-overlay item) 'priority 20)
        (setf (org-typora-math--item-source item) source
              (org-typora-math--item-block item) block)
        (push item items)))
    (dolist (item old) (delete-overlay (org-typora-math--item-overlay item)))
    (setq org-typora-math--items (nreverse items)
          org-typora-math--active (org-typora-math--at-point))))

(defun org-typora-math--preamble-key ()
  "Return a value that changes when the snippet preamble may change."
  (let (lines)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((case-fold-search t))
          (while (re-search-forward
                  "^[ \t]*#\\+\\(?:latex_header\\(?:_extra\\)?\\|setupfile\\|latex_class\\(?:_options\\)?\\):.*$"
                  nil t)
            (push (match-string-no-properties 0) lines)))))
    (list lines org-format-latex-header
          org-latex-default-packages-alist org-latex-packages-alist
          org-latex-classes org-latex-default-class
          (plist-get (cdr (assq 'dvisvgm org-preview-latex-process-alist))
                     :latex-header))))

(defun org-typora-math--preamble ()
  "Build the same snippet preamble as Org's LaTeX preview.
Keep only the latest preamble and rebuild it when its inputs change.
The contents of a `#+SETUPFILE' are not watched; run
`org-typora-math-refresh' after editing one."
  (let ((key (org-typora-math--preamble-key)))
    (unless (equal key (car org-typora-math--preamble))
      (setq org-typora-math--preamble
            (cons key
                  (or (plist-get (cdr (assq 'dvisvgm org-preview-latex-process-alist))
                                 :latex-header)
                      (org-latex-make-preamble
                       (org-export-get-environment (org-export-get-backend 'latex))
                       org-format-latex-header 'snippet)))))
    (cdr org-typora-math--preamble)))

(defun org-typora-math--color ()
  "Return the default foreground color as a comma-separated RGB string."
  (let* ((name (face-foreground 'default nil t))
         (rgb (or (and name (color-name-to-rgb name)) '(0 0 0))))
    (mapconcat (lambda (v) (format "%.5f" v)) rgb ",")))

(defun org-typora-math--document (item preamble color)
  "Build a TeX document for ITEM using PREAMBLE and the text COLOR."
  (concat preamble "\n\\usepackage{color}\n\\begin{document}\n"
          "\\definecolor{previewfg}{rgb}{" color "}\n\\color{previewfg}\n"
          (org-typora-math--item-source item)
          "%\n\\end{document}\n"))

(defun org-typora-math--order-jobs (jobs)
  "Sort JOBS: the active formula, then formulas in the window, then the rest."
  (let* ((window (get-buffer-window (current-buffer) t))
         (start (and window (window-start window)))
         (end (and window (window-end window t))))
    (cl-flet ((rank (job)
                (let ((item (car job)))
                  (cond
                   ((eq item org-typora-math--active) 0)
                   ((and window
                         (let ((ov (org-typora-math--item-overlay item)))
                           (and (overlay-buffer ov)
                                (< (overlay-start ov) end)
                                (> (overlay-end ov) start))))
                    1)
                   (t 2)))))
      (let ((ranked (mapcar (lambda (job) (cons (rank job) job)) jobs)))
        (mapcar #'cdr (sort ranked (lambda (a b) (< (car a) (car b)))))))))

(defun org-typora-math--cache-file (key)
  "Return the disk cache file of KEY, or nil when the disk cache is off."
  (when org-typora-math-cache-directory
    (expand-file-name (concat (substring key 0 2) "/" key ".svg")
                      org-typora-math-cache-directory)))

(defun org-typora-math--cache-delete (key)
  "Delete the disk cache file of KEY, ignoring errors."
  (when-let* ((file (org-typora-math--cache-file key)))
    (ignore-errors (delete-file file))))

(defun org-typora-math--cache-get (key)
  "Return the SVG for KEY from memory or disk, or nil.
Store a disk hit in memory.  Delete a disk file that is not valid SVG."
  (or (gethash key org-typora-math--cache)
      (when-let* ((file (org-typora-math--cache-file key))
                  ((file-regular-p file)))
        (let ((svg (ignore-errors
                     (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string)))))
          (if (and svg (string-search "<svg" svg))
              (puthash key svg org-typora-math--cache)
            (ignore-errors (delete-file file))
            nil)))))

(defun org-typora-math--cache-put (key svg)
  "Store SVG for KEY in memory and, atomically, on disk.
A write error goes to the log and does not affect the preview."
  (puthash key svg org-typora-math--cache)
  (when-let* ((file (org-typora-math--cache-file key)))
    (let (temporary)
      (condition-case err
          (progn
            (make-directory (file-name-directory file) t)
            (setq temporary (make-temp-file
                             (expand-file-name ".tmp-" (file-name-directory file))))
            (let ((coding-system-for-write 'utf-8-unix))
              (with-temp-file temporary (insert svg)))
            (rename-file temporary file t)
            (setq temporary nil))
        (error
         (with-current-buffer (org-typora-math--log-buffer)
           (goto-char (point-max))
           (insert "\nCannot write cache file " file ": "
                   (error-message-string err) "\n"))))
      (when temporary (ignore-errors (delete-file temporary))))))

(defun org-typora-math--build-jobs (&optional force)
  "Set each item's key, use cached images, and return jobs for the rest.
With FORCE, delete the disk files of the current keys first."
  (let ((preamble (org-typora-math--preamble))
        (color (org-typora-math--color))
        jobs)
    (dolist (item org-typora-math--items)
      (let* ((document (org-typora-math--document item preamble color))
             (key (secure-hash 'sha256
                               (mapconcat
                                #'identity
                                (append (list org-typora-math--cache-version
                                              org-typora-math-latex-program)
                                        org-typora-math--latex-arguments
                                        (list org-typora-math-dvisvgm-program)
                                        org-typora-math--dvisvgm-arguments
                                        (list document))
                                "\0")))
             (cached (progn (when force (org-typora-math--cache-delete key))
                            (org-typora-math--cache-get key))))
        (setf (org-typora-math--item-key item) key)
        (cond
         (cached (setf (org-typora-math--item-svg item) cached
                       (org-typora-math--item-error item) nil))
         ((not (equal key (org-typora-math--item-attempted item)))
          (push (list item key document) jobs)))))
    (nreverse jobs)))

(defun org-typora-math--refresh (&optional force)
  "Collect formulas and enqueue asynchronous compilations.
With FORCE, ignore disk cache files of the current formulas."
  (condition-case err
      (progn
        (org-typora-math--collect)
        (setq org-typora-math--queue
              (org-typora-math--order-jobs (org-typora-math--build-jobs force)))
        (org-typora-math--paint)
        (org-typora-math--next))
    (error (message "Org Typora math: %s" (error-message-string err)))))

(defun org-typora-math--valid-job-p (generation item key)
  "Check that GENERATION, ITEM and KEY still describe current work."
  (and org-typora-math-mode
       (= generation org-typora-math--generation)
       (memq item org-typora-math--items)
       (equal key (org-typora-math--item-key item))))

(defun org-typora-math--log-buffer ()
  "Return the compilation log buffer, creating it again if it was killed."
  (unless (buffer-live-p org-typora-math--log)
    (setq org-typora-math--log (generate-new-buffer " *org-typora-math-log*")))
  org-typora-math--log)

(defun org-typora-math--finish (item key &optional error-message)
  "Finish ITEM with KEY, optionally recording ERROR-MESSAGE.
Then start the next queued job."
  (org-typora-math--complete item key error-message)
  (org-typora-math--next))

(defun org-typora-math--complete (item key &optional error-message)
  "Record the result of ITEM with KEY, optionally ERROR-MESSAGE, and clean up."
  (org-typora-math--cancel-timer 'org-typora-math--timeout)
  (setq org-typora-math--process nil)
  (if error-message
      (progn
        (setf (org-typora-math--item-attempted item) key
              (org-typora-math--item-error item) error-message)
        (message "Org Typora math: %s (M-x org-typora-math-show-log)" error-message))
    (let* ((file (expand-file-name "preview.svg" org-typora-math--directory))
           (svg (with-temp-buffer
                  (insert-file-contents file)
                  (buffer-string))))
      (org-typora-math--cache-put key svg)
      (setf (org-typora-math--item-svg item) svg
            (org-typora-math--item-attempted item) key
            (org-typora-math--item-error item) nil)))
  (delete-directory org-typora-math--directory t)
  (setq org-typora-math--directory nil)
  (org-typora-math--repaint-item item))

(defun org-typora-math--start-stage (item key command output next)
  "Run COMMAND for ITEM and KEY, requiring OUTPUT before calling NEXT.
NEXT returns non-nil when it started or finished work that continues the queue.
Return non-nil when the process started.  On a synchronous failure, record
the error and return nil without starting the next job, so that
`org-typora-math--next' can continue in its loop."
  (let ((owner (current-buffer))
        (generation org-typora-math--generation)
        (default-directory org-typora-math--directory)
        (log (org-typora-math--log-buffer)))
    (condition-case err
        (progn
          (with-current-buffer log
            (goto-char (point-max))
            (insert "\n$ " (mapconcat #'identity command " ") "\n"))
          (setq org-typora-math--process
                (make-process
                 :name "org-typora-math" :buffer log
                 :command command :connection-type 'pipe :noquery t
                 :sentinel
                 (lambda (process _event)
                   (when (and (memq (process-status process) '(exit signal))
                              (buffer-live-p owner))
                     (with-current-buffer owner
                       (when (and (eq process org-typora-math--process)
                                  (org-typora-math--valid-job-p generation item key))
                         (org-typora-math--cancel-timer 'org-typora-math--timeout)
                         (if (and (zerop (process-exit-status process))
                                  (file-exists-p
                                   (expand-file-name output org-typora-math--directory)))
                             (unless (funcall next) (org-typora-math--next))
                           (org-typora-math--finish item key
                                                    (format "%s failed" (car command))))))))))
          (setq org-typora-math--timeout
                (run-at-time
                 org-typora-math-process-timeout nil
                 (lambda ()
                   (when (buffer-live-p owner)
                     (with-current-buffer owner
                       (when (org-typora-math--valid-job-p generation item key)
                         (set-process-sentinel org-typora-math--process #'ignore)
                         (delete-process org-typora-math--process)
                         (org-typora-math--finish item key "Compilation timed out")))))))
          t)
      (error (org-typora-math--complete item key (error-message-string err))
             nil))))

(defun org-typora-math--next ()
  "Start the next queued formula, with at most one process per buffer.
Process cached and synchronously failed jobs in a loop, not by recursion."
  (let (started)
    (while (and (not started) org-typora-math-mode
                (not org-typora-math--process) org-typora-math--queue)
      (pcase-let ((`(,item ,key ,document) (pop org-typora-math--queue)))
        (if-let* ((cached (org-typora-math--cache-get key)))
            (progn
              (setf (org-typora-math--item-svg item) cached
                    (org-typora-math--item-attempted item) key
                    (org-typora-math--item-error item) nil)
              (org-typora-math--repaint-item item))
          (setq org-typora-math--directory (make-temp-file "org-typora-math-" t))
          (with-temp-file (expand-file-name "preview.tex" org-typora-math--directory)
            (insert document))
          (setq started
                (org-typora-math--start-stage
                 item key
                 (cons org-typora-math-latex-program
                       org-typora-math--latex-arguments)
                 "preview.dvi"
                 (lambda ()
                   (org-typora-math--start-stage
                    item key
                    (cons org-typora-math-dvisvgm-program
                          org-typora-math--dvisvgm-arguments)
                    "preview.svg"
                    (lambda () (org-typora-math--finish item key) t))))))))))

;;;###autoload
(defun org-typora-math-refresh ()
  "Rebuild all previews, retrying failures and ignoring cached images.
Also needed after changes the cache key does not see, such as the contents
of a `#+SETUPFILE' or an `\\input' file."
  (interactive)
  (unless org-typora-math-mode (user-error "Enable org-typora-math-mode first"))
  (org-typora-math--cancel-timer 'org-typora-math--timer)
  (org-typora-math--cancel-job)
  (clrhash org-typora-math--cache)
  (setq org-typora-math--preamble nil)
  (dolist (item org-typora-math--items)
    (setf (org-typora-math--item-attempted item) nil))
  (org-typora-math--refresh t))

;;;###autoload
(defun org-typora-math-clear-cache ()
  "Delete the disk cache directory after confirmation."
  (interactive)
  (let ((directory org-typora-math-cache-directory))
    (unless (and directory (file-directory-p directory))
      (user-error "No disk cache to clear"))
    (let* ((files (directory-files-recursively directory ""))
           (bytes (apply #'+ (mapcar (lambda (file)
                                       (or (file-attribute-size (file-attributes file)) 0))
                                     files))))
      (when (yes-or-no-p (format "Delete %s (%d files, %s)? "
                                 directory (length files)
                                 (file-size-human-readable bytes)))
        (delete-directory directory t)
        (when org-typora-math--cache (clrhash org-typora-math--cache))
        (message "Org Typora math: cache cleared")))))

(defun org-typora-math-show-log ()
  "Show compiler output for the current buffer."
  (interactive)
  (if (buffer-live-p org-typora-math--log)
      (display-buffer org-typora-math--log)
    (user-error "No compilation log in this buffer")))

(defun org-typora-math--cleanup ()
  "Remove timers, processes, frames and overlays owned by this buffer."
  (org-typora-math--cancel-timer 'org-typora-math--timer)
  (org-typora-math--cancel-job)
  (dolist (item org-typora-math--items)
    (delete-overlay (org-typora-math--item-overlay item)))
  (setq org-typora-math--items nil org-typora-math--active nil
        org-typora-math--cache nil org-typora-math--preamble nil)
  (when (frame-live-p org-typora-math--frame)
    (delete-frame org-typora-math--frame))
  (setq org-typora-math--frame nil)
  (dolist (buffer (list org-typora-math--popup-buffer org-typora-math--log))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (setq org-typora-math--popup-buffer nil org-typora-math--log nil))

;;;###autoload
(define-minor-mode org-typora-math-mode
  "Preview Org math while editing, using debounced asynchronous LaTeX jobs."
  :lighter " TMath"
  (cond
   ;; Org creates internal buffers named with a leading space, for example
   ;; during export.  Never preview in those.
   ((and org-typora-math-mode (string-prefix-p " " (buffer-name)))
    (setq org-typora-math-mode nil))
   (org-typora-math-mode
      (progn
        (when org-typora-math--cache
          (org-typora-math-mode -1)
          (setq org-typora-math-mode t))
        (unless (and (derived-mode-p 'org-mode) (image-type-available-p 'svg))
          (setq org-typora-math-mode nil)
          (user-error "Org mode and SVG image support are required"))
        (dolist (program (list org-typora-math-latex-program
                               org-typora-math-dvisvgm-program))
          (unless (executable-find program)
            (setq org-typora-math-mode nil)
            (user-error "Cannot find %s" program)))
        (setq org-typora-math--cache (make-hash-table :test #'equal))
        (setq org-typora-math--restore-fragtog (bound-and-true-p org-fragtog-mode))
        (when (and org-typora-math--restore-fragtog (fboundp 'org-fragtog-mode))
          (org-fragtog-mode -1))
        (save-restriction (widen) (org-clear-latex-preview))
        (add-hook 'after-change-functions #'org-typora-math--after-change nil t)
        (add-hook 'post-command-hook #'org-typora-math--post-command nil t)
        (add-hook 'window-scroll-functions #'org-typora-math--window-change nil t)
        (add-hook 'window-buffer-change-functions #'org-typora-math--window-change nil t)
        (add-hook 'window-selection-change-functions #'org-typora-math--window-change nil t)
        (add-hook 'window-size-change-functions #'org-typora-math--window-change nil t)
        (add-hook 'kill-buffer-hook #'org-typora-math--cleanup nil t)
        (add-hook 'change-major-mode-hook #'org-typora-math--cleanup nil t)
        (org-typora-math--schedule)))
   (t
    (remove-hook 'after-change-functions #'org-typora-math--after-change t)
    (remove-hook 'post-command-hook #'org-typora-math--post-command t)
    (remove-hook 'window-scroll-functions #'org-typora-math--window-change t)
    (remove-hook 'window-buffer-change-functions #'org-typora-math--window-change t)
    (remove-hook 'window-selection-change-functions #'org-typora-math--window-change t)
    (remove-hook 'window-size-change-functions #'org-typora-math--window-change t)
    (remove-hook 'kill-buffer-hook #'org-typora-math--cleanup t)
    (remove-hook 'change-major-mode-hook #'org-typora-math--cleanup t)
    (org-typora-math--cleanup)
    (when (and org-typora-math--restore-fragtog (fboundp 'org-fragtog-mode))
      (org-fragtog-mode 1))
    (setq org-typora-math--restore-fragtog nil))))

(provide 'org-typora-math)
;;; org-typora-math.el ends here
