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

(defface org-typora-math-source
  '((((class color) (background light)) :background "#f5f6f7" :extend t)
    (((class color) (background dark)) :background "#252a31" :extend t))
  "Face for the source of the formula being edited.")

(cl-defstruct (org-typora-math--item (:constructor org-typora-math--item-create))
  overlay source block key svg attempted error)

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

(defun org-typora-math--image (item)
  "Create an image descriptor for ITEM's last successful rendering."
  (when-let* ((svg (org-typora-math--item-svg item)))
    (create-image svg 'svg t :ascent 'center
                  :scale org-typora-math-scale)))

(defun org-typora-math--panel (image)
  "Return a centered overlay line displaying IMAGE."
  (let ((width (car (image-size image t))))
    (concat "\n"
            (propertize " " 'display
                        `(space :align-to (- center (,(round (/ width 2))))))
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
                 (width (+ 20 (ceiling (car size))))
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
                (insert (propertize
                         " " 'display
                         (cons 'image (plist-put (copy-sequence (cdr image))
                                                 :margin '(8 . 8)))))
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

(defun org-typora-math--paint ()
  "Update overlays and the popup without modifying the buffer."
  (let (popup-shown)
   (dolist (item org-typora-math--items)
    (let* ((ov (org-typora-math--item-overlay item))
           (active (eq item org-typora-math--active))
           (block (org-typora-math--item-block item))
           (image (org-typora-math--image item)))
      (overlay-put ov 'display nil)
      (overlay-put ov 'before-string nil)
      (overlay-put ov 'after-string nil)
      (overlay-put ov 'face
                   (and active (if block 'org-typora-math-source
                                 '(:inherit org-typora-math-source :extend nil))))
      (overlay-put ov 'help-echo (org-typora-math--item-error item))
      (when image
        (cond
         (active
          (unless (setq popup-shown
                        (and (not block)
                             (org-typora-math--popup image (overlay-start ov))))
            (overlay-put ov 'after-string (org-typora-math--panel image))))
         (block
          ;; Emacs does not recursively interpret image display properties
          ;; inside a replacement display string.  Keep the image directly
          ;; on the overlay and the alignment in a separate before-string.
          (overlay-put ov 'before-string
                       (propertize " " 'display
                                   `(space :align-to
                                           (- center (,(round (/ (car (image-size image t)) 2)))))))
          (overlay-put ov 'display image))
         (t (overlay-put ov 'display image))))))
   (unless popup-shown (org-typora-math--hide-popup))))

(defun org-typora-math--post-command ()
  "Reveal the formula entered by the cursor and conceal the previous one."
  (when org-typora-math-mode
    (let ((active (org-typora-math--at-point)))
      (unless (eq active org-typora-math--active)
        (setq org-typora-math--active active)
        (org-typora-math--paint)))))

(defun org-typora-math--window-change (&rest _)
  "Reposition the popup after scrolling or changing windows."
  (when org-typora-math-mode
    (if (eq (window-buffer (selected-window)) (current-buffer))
        (org-typora-math--paint)
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
                 (org-typora-math--refresh)))))
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

(defun org-typora-math--collect ()
  "Reconcile tracked formulas with Org's syntax tree.
Reuse overlays at the same start position, preserving the last good image."
  (let ((old org-typora-math--items) items)
    (save-restriction
      (widen)
      (org-element-map (org-element-parse-buffer) '(latex-fragment latex-environment)
        (lambda (element)
          (let* ((source (string-trim-right (org-element-property :value element)))
                 (begin (org-element-property :begin element))
                 (end (+ begin (length source)))
                 (block (or (eq (org-element-type element) 'latex-environment)
                            (string-prefix-p "\\[" source)
                            (string-prefix-p "$$" source)))
                 (item (cl-find-if
                        (lambda (it)
                          (= begin (overlay-start (org-typora-math--item-overlay it))))
                        old)))
            (unless item
              (setq item (org-typora-math--item-create
                          :overlay (make-overlay begin end nil nil t))))
            (setq old (delq item old))
            (move-overlay (org-typora-math--item-overlay item) begin end)
            (overlay-put (org-typora-math--item-overlay item) 'priority 20)
            (setf (org-typora-math--item-source item) source
                  (org-typora-math--item-block item) block)
            (push item items)))))
    (dolist (item old) (delete-overlay (org-typora-math--item-overlay item)))
    (setq org-typora-math--items (nreverse items)
          org-typora-math--active (org-typora-math--at-point))))

(defun org-typora-math--preamble ()
  "Build the same snippet preamble as Org's LaTeX preview."
  (or (plist-get (cdr (assq 'dvisvgm org-preview-latex-process-alist)) :latex-header)
      (org-latex-make-preamble
       (org-export-get-environment (org-export-get-backend 'latex))
       org-format-latex-header 'snippet)))

(defun org-typora-math--document (item preamble)
  "Build a TeX document for ITEM using PREAMBLE and the current text color."
  (let* ((name (face-foreground 'default nil t))
         (rgb (or (and name (color-name-to-rgb name)) '(0 0 0))))
    (concat preamble "\n\\usepackage{color}\n\\begin{document}\n"
            "\\definecolor{previewfg}{rgb}{"
            (mapconcat (lambda (v) (format "%.5f" v)) rgb ",")
            "}\n\\color{previewfg}\n"
            (org-typora-math--item-source item)
            "%\n\\end{document}\n")))

(defun org-typora-math--refresh ()
  "Collect formulas and enqueue asynchronous compilations."
  (condition-case err
      (progn
        (org-typora-math--collect)
        (let ((preamble (org-typora-math--preamble)) jobs)
          (dolist (item org-typora-math--items)
            (let* ((document (org-typora-math--document item preamble))
                   (key (secure-hash 'sha256
                                     (concat org-typora-math-latex-program "\0"
                                             org-typora-math-dvisvgm-program "\0"
                                             document)))
                   (cached (gethash key org-typora-math--cache)))
              (setf (org-typora-math--item-key item) key)
              (cond
               (cached (setf (org-typora-math--item-svg item) cached
                             (org-typora-math--item-error item) nil))
               ((not (equal key (org-typora-math--item-attempted item)))
                (push (list item key document) jobs)))))
          (setq org-typora-math--queue
                (sort (nreverse jobs)
                      (lambda (a b)
                        (and (eq (car a) org-typora-math--active)
                             (not (eq (car b) org-typora-math--active)))))))
        (org-typora-math--paint)
        (org-typora-math--next))
    (error (message "Org Typora math: %s" (error-message-string err)))))

(defun org-typora-math--valid-job-p (generation item key)
  "Check that GENERATION, ITEM and KEY still describe current work."
  (and org-typora-math-mode
       (= generation org-typora-math--generation)
       (memq item org-typora-math--items)
       (equal key (org-typora-math--item-key item))))

(defun org-typora-math--finish (item key &optional error-message)
  "Finish ITEM with KEY, optionally recording ERROR-MESSAGE."
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
      (puthash key svg org-typora-math--cache)
      (setf (org-typora-math--item-svg item) svg
            (org-typora-math--item-attempted item) key
            (org-typora-math--item-error item) nil)))
  (delete-directory org-typora-math--directory t)
  (setq org-typora-math--directory nil)
  (org-typora-math--paint)
  (org-typora-math--next))

(defun org-typora-math--start-stage (item key command output next)
  "Run COMMAND for ITEM and KEY, requiring OUTPUT before calling NEXT."
  (let ((owner (current-buffer))
        (generation org-typora-math--generation)
        (default-directory org-typora-math--directory))
    (condition-case err
        (progn
          (with-current-buffer org-typora-math--log
            (goto-char (point-max))
            (insert "\n$ " (mapconcat #'identity command " ") "\n"))
          (setq org-typora-math--process
                (make-process
                 :name "org-typora-math" :buffer org-typora-math--log
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
                             (funcall next)
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
                         (org-typora-math--finish item key "Compilation timed out"))))))))
      (error (org-typora-math--finish item key (error-message-string err))))))

(defun org-typora-math--next ()
  "Start the next queued formula, with at most one process per buffer."
  (when (and org-typora-math-mode (not org-typora-math--process)
             org-typora-math--queue)
    (pcase-let ((`(,item ,key ,document) (pop org-typora-math--queue)))
      (if-let* ((cached (gethash key org-typora-math--cache)))
          (progn
            (setf (org-typora-math--item-svg item) cached)
            (org-typora-math--paint)
            (org-typora-math--next))
        (setq org-typora-math--directory (make-temp-file "org-typora-math-" t))
        (with-temp-file (expand-file-name "preview.tex" org-typora-math--directory)
          (insert document))
        (org-typora-math--start-stage
         item key
         (list org-typora-math-latex-program "-interaction=nonstopmode"
               "-halt-on-error" "-no-shell-escape" "preview.tex")
         "preview.dvi"
         (lambda ()
           (org-typora-math--start-stage
            item key
            (list org-typora-math-dvisvgm-program "--no-fonts" "--exact-bbox"
                  "--bbox=min" "--output=preview.svg" "preview.dvi")
            "preview.svg"
            (lambda () (org-typora-math--finish item key)))))))))

;;;###autoload
(defun org-typora-math-refresh ()
  "Rebuild all previews, retrying failures and clearing the memory cache."
  (interactive)
  (unless org-typora-math-mode (user-error "Enable org-typora-math-mode first"))
  (org-typora-math--cancel-timer 'org-typora-math--timer)
  (org-typora-math--cancel-job)
  (clrhash org-typora-math--cache)
  (dolist (item org-typora-math--items)
    (setf (org-typora-math--item-attempted item) nil))
  (org-typora-math--refresh))

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
        org-typora-math--cache nil)
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
  (if org-typora-math-mode
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
        (setq org-typora-math--cache (make-hash-table :test #'equal)
              org-typora-math--log (generate-new-buffer " *org-typora-math-log*"))
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
        (org-typora-math--schedule))
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
    (setq org-typora-math--restore-fragtog nil)))

(provide 'org-typora-math)
;;; org-typora-math.el ends here
