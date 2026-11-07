;;; org-typora-math-test.el --- Tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-typora-math)

;; Tests must not touch the user's cache.  Disk cache tests bind it again.
(setq org-typora-math-cache-directory nil)

;; Painting is stubbed unless a test binds this variable to non-nil.
(defvar org-typora-math-test--real-paint nil)
(defconst org-typora-math-test--paint-functions
  (mapcar (lambda (name) (cons name (symbol-function name)))
          '(org-typora-math--paint org-typora-math--paint-item
            org-typora-math--update-popup)))

(defun org-typora-math-test--stub (name)
  "Return a replacement for NAME that paints only in painting tests."
  (let ((original (cdr (assq name org-typora-math-test--paint-functions))))
    (lambda (&rest args)
      (when org-typora-math-test--real-paint (apply original args)))))

(defmacro org-typora-math-test--buffer (text &rest body)
  "Evaluate BODY in an Org buffer containing TEXT, without GUI painting."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "org-typora-math-test")))
     (unwind-protect
         (with-current-buffer buffer
           (org-mode)
           (insert ,text)
           (goto-char (point-min))
           (cl-letf (((symbol-function 'org-typora-math--paint)
                      (org-typora-math-test--stub 'org-typora-math--paint))
                     ((symbol-function 'org-typora-math--paint-item)
                      (org-typora-math-test--stub 'org-typora-math--paint-item))
                     ((symbol-function 'org-typora-math--update-popup)
                      (org-typora-math-test--stub 'org-typora-math--update-popup)))
             (unwind-protect
                 (progn (org-typora-math-mode 1)
                        (org-typora-math--cancel-timer 'org-typora-math--timer)
                        ,@body)
               (org-typora-math-mode -1))))
       (kill-buffer buffer))))

(defun org-typora-math-test--wait ()
  "Wait for pending processes, failing if they do not finish in 20 seconds."
  (let ((deadline (+ (float-time) 20)))
    (while (and org-typora-math--process (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should-not org-typora-math--process)))

(ert-deftest org-typora-math-detects-org-formulas ()
  (org-typora-math-test--buffer
      "Inline $a$ and \\(b\\).\n\n\\[c\\]\n\n\\begin{equation}\nd\n\\end{equation}\n\n#+begin_src latex\n$x$\n#+end_src\n"
    (org-typora-math--collect)
    (should (= 4 (length org-typora-math--items)))
    (should (equal '(nil nil t t)
                   (mapcar (lambda (item) (and (org-typora-math--item-block item) t))
                           org-typora-math--items)))
    (dolist (item org-typora-math--items)
      (let ((ov (org-typora-math--item-overlay item)))
        (should (equal (org-typora-math--item-source item)
                       (buffer-substring-no-properties (overlay-start ov) (overlay-end ov))))))))

(ert-deftest org-typora-math-skips-affiliated-keywords ()
  (org-typora-math-test--buffer
      "#+name: eq:1\n\\begin{equation}\nE=mc^2\n\\end{equation}\n"
    (org-typora-math--collect)
    (let ((ov (org-typora-math--item-overlay (car org-typora-math--items))))
      (should (equal "\\begin{equation}\nE=mc^2\n\\end{equation}"
                     (buffer-substring-no-properties
                      (overlay-start ov) (overlay-end ov)))))))

(ert-deftest org-typora-math-ignores-non-math-fragments ()
  (org-typora-math-test--buffer "See \\cite{key}, \\ref{fig:1} and \\textbf{x}, $a$.\n"
    (org-typora-math--collect)
    (should (equal '("$a$")
                   (mapcar #'org-typora-math--item-source org-typora-math--items)))))

(ert-deftest org-typora-math-recreates-killed-log ()
  (org-typora-math-test--buffer "$a$"
    (kill-buffer (org-typora-math--log-buffer))
    (org-typora-math--refresh)
    (org-typora-math-test--wait)
    (should-not (org-typora-math--item-error (car org-typora-math--items)))
    (should (buffer-live-p org-typora-math--log))))

(ert-deftest org-typora-math-many-start-failures-do-not-recurse ()
  (org-typora-math-test--buffer
      (mapconcat (lambda (i) (format "$x_{%d}$\n\n" i)) (number-sequence 1 1000) "")
    (let ((org-typora-math-latex-program "/nonexistent/latex")
          (inhibit-message t))
      (org-typora-math--refresh))
    (should-not org-typora-math--queue)
    (should-not org-typora-math--directory)
    (should (cl-every #'org-typora-math--item-error org-typora-math--items))))

(ert-deftest org-typora-math-reuses-last-good-image ()
  (org-typora-math-test--buffer "$a$\n"
    (org-typora-math--collect)
    (let ((item (car org-typora-math--items)))
      (setf (org-typora-math--item-svg item) "last good")
      (goto-char 3)
      (insert "+b")
      (org-typora-math--collect)
      (should (eq item (car org-typora-math--items)))
      (should (equal "last good" (org-typora-math--item-svg item)))
      (should (equal "$a+b$" (org-typora-math--item-source item))))))

(ert-deftest org-typora-math-leaving-reveals-and-conceals ()
  (org-typora-math-test--buffer "$a$ outside"
    (org-typora-math--collect)
    (goto-char 2)
    (org-typora-math--post-command)
    (should org-typora-math--active)
    (goto-char 4)
    (org-typora-math--post-command)
    (should-not org-typora-math--active)))

(ert-deftest org-typora-math-debounces-edits ()
  (org-typora-math-test--buffer "$a$"
    (goto-char 2)
    (insert "b")
    (let ((first org-typora-math--timer))
      (should (timerp first))
      (insert "c")
      (should-not (eq first org-typora-math--timer))
      (should-not (memq first timer-list)))))

(ert-deftest org-typora-math-rejects-obsolete-result ()
  (org-typora-math-test--buffer "$a$"
    (org-typora-math--collect)
    (let* ((item (car org-typora-math--items))
           (generation org-typora-math--generation))
      (setf (org-typora-math--item-key item) "key")
      (should (org-typora-math--valid-job-p generation item "key"))
      (goto-char 2)
      (insert "b")
      (should-not (org-typora-math--valid-job-p generation item "key")))))

(ert-deftest org-typora-math-keeps-buffer-text-and-undo ()
  (org-typora-math-test--buffer "$a$\n\n\\[b\\]\n"
    (buffer-enable-undo)
    (set-buffer-modified-p nil)
    (let ((text (buffer-string)) (undo buffer-undo-list))
      (org-typora-math--refresh)
      (org-typora-math-test--wait)
      (should (equal text (buffer-string)))
      (should-not (buffer-modified-p))
      (should (equal undo buffer-undo-list)))))

(ert-deftest org-typora-math-real-async-compile-and-cache ()
  (org-typora-math-test--buffer "#+LATEX_HEADER: \\newcommand{\\mytest}{x^2}\n\n$\\mytest$\n"
    (org-typora-math--refresh)
    (should (processp org-typora-math--process))
    (org-typora-math-test--wait)
    (let ((item (car org-typora-math--items)))
      (should (string-match-p "<svg" (or (org-typora-math--item-svg item) "")))
      (should-not (org-typora-math--item-error item))
      (should-not org-typora-math--directory)
      (should (= 1 (hash-table-count org-typora-math--cache)))
      (org-typora-math--refresh)
      (should-not org-typora-math--process))))

(ert-deftest org-typora-math-failure-preserves-preview ()
  (org-typora-math-test--buffer "$a$"
    (org-typora-math--refresh)
    (org-typora-math-test--wait)
    (let* ((item (car org-typora-math--items))
           (svg (org-typora-math--item-svg item)))
      (should svg)
      (goto-char 2)
      (insert "\\undefinedTestMacro")
      (org-typora-math--refresh)
      (org-typora-math-test--wait)
      (should (org-typora-math--item-error item))
      (should (equal svg (org-typora-math--item-svg item)))
      (org-typora-math--refresh)
      (should-not org-typora-math--process))))

(ert-deftest org-typora-math-cancellation-cleans-temp-directory ()
  (org-typora-math-test--buffer "$a$"
    (org-typora-math--refresh)
    (let ((process org-typora-math--process)
          (directory org-typora-math--directory))
      (should (processp process))
      (goto-char 2)
      (insert "b")
      (should-not (process-live-p process))
      (should-not (file-exists-p directory))
      (should-not org-typora-math--process))))

(ert-deftest org-typora-math-disable-cleans-resources ()
  (org-typora-math-test--buffer "$a$"
    (org-typora-math--refresh)
    (let ((log org-typora-math--log)
          (overlays (mapcar #'org-typora-math--item-overlay org-typora-math--items)))
      (org-typora-math-mode -1)
      (should-not org-typora-math--timer)
      (should-not org-typora-math--process)
      (should-not (buffer-live-p log))
      (should-not (cl-some #'overlay-buffer overlays)))))

(ert-deftest org-typora-math-timeout-cleans-process ()
  (org-typora-math-test--buffer "$a$"
    (org-typora-math--collect)
    (let* ((item (car org-typora-math--items))
           (org-typora-math-process-timeout 0.05)
           (directory (make-temp-file "org-typora-math-test-" t)))
      (setq org-typora-math--directory directory)
      (setf (org-typora-math--item-key item) "timeout")
      (org-typora-math--start-stage
       item "timeout" '("sleep" "5") "never.svg" #'ignore)
      (let ((process org-typora-math--process))
        (org-typora-math-test--wait)
        (should-not (process-live-p process)))
      (should (equal "Compilation timed out" (org-typora-math--item-error item)))
      (should-not (file-exists-p directory)))))

(ert-deftest org-typora-math-reenable-does-not-leak ()
  (org-typora-math-test--buffer "$a$"
    (org-typora-math--refresh)
    (let ((process org-typora-math--process)
          (directory org-typora-math--directory)
          (log org-typora-math--log))
      (org-typora-math-mode 1)
      (should org-typora-math-mode)
      (should-not (process-live-p process))
      (should-not (file-exists-p directory))
      (should-not (buffer-live-p log)))))

(ert-deftest org-typora-math-hidden-buffer-defers-compilation ()
  (org-typora-math-test--buffer "$a$"
    (should-not (org-typora-math--visible-p))
    (should-not org-typora-math--log)
    (let ((org-typora-math-idle-delay 0.01))
      (org-typora-math--schedule)
      (accept-process-output nil 0.2))
    (should-not org-typora-math--process)
    (should-not org-typora-math--items)
    (should org-typora-math--pending)))

(ert-deftest org-typora-math-showing-buffer-starts-compilation ()
  (org-typora-math-test--buffer "$a$"
    (let ((org-typora-math-idle-delay 0.01)
          (previous (window-buffer (selected-window))))
      (org-typora-math--schedule)
      (accept-process-output nil 0.2)
      (should org-typora-math--pending)
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (org-typora-math--window-change)
            (should-not org-typora-math--pending)
            (accept-process-output nil 0.2)
            (should (processp org-typora-math--process))
            (org-typora-math-test--wait))
        (set-window-buffer (selected-window) previous))
      (should (org-typora-math--item-svg (car org-typora-math--items))))))

(ert-deftest org-typora-math-orders-queue-by-visibility ()
  (org-typora-math-test--buffer
      (concat "$a$\n\n" (make-string 5000 ?\n) "$b$\n\n$c$\n")
    (org-typora-math--collect)
    (let* ((items org-typora-math--items)
           (jobs (mapcar (lambda (item) (list item "k" "d")) (reverse items)))
           (previous (window-buffer (selected-window))))
      (setq org-typora-math--active (nth 2 items))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) (current-buffer))
            (set-window-start (selected-window) (point-min))
            (let ((order (cl-letf (((symbol-function 'window-end)
                                    (lambda (&rest _) 20)))
                           (mapcar #'car (org-typora-math--order-jobs jobs)))))
              (should (eq (nth 2 items) (car order)))
              (should (eq (nth 0 items) (cadr order)))))
        (set-window-buffer (selected-window) previous)))))

(ert-deftest org-typora-math-internal-buffer-stays-off ()
  (let ((buffer (generate-new-buffer " *tmp*"))
        (timers (length timer-list)))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (insert "$a$")
          (org-typora-math-mode 1)
          (should-not org-typora-math-mode)
          (should-not org-typora-math--timer)
          (should-not org-typora-math--log)
          (should-not org-typora-math--cache)
          (should-not (memq #'org-typora-math--after-change after-change-functions))
          (should (= timers (length timer-list)))
          (should-not (get-buffer " *org-typora-math-log*")))
      (kill-buffer buffer))))

(defmacro org-typora-math-test--painting (text &rest body)
  "Run BODY with real painting in a displayed buffer containing TEXT.
Every item gets a fake SVG, and `image-size' works without a display."
  (declare (indent 1))
  `(org-typora-math-test--buffer ,text
     (let ((org-typora-math-test--real-paint t)
           (previous (window-buffer (selected-window))))
       (cl-letf (((symbol-function 'image-size) (lambda (&rest _) '(100 . 20))))
         (unwind-protect
             (progn
               (set-window-buffer (selected-window) (current-buffer))
               (org-typora-math--collect)
               (dolist (item org-typora-math--items)
                 (setf (org-typora-math--item-svg item) (copy-sequence "<svg/>")))
               (org-typora-math--paint)
               ,@body)
           (set-window-buffer (selected-window) previous))))))

(defmacro org-typora-math-test--count-overlay-puts (&rest body)
  "Run BODY and return the list of overlays passed to `overlay-put'."
  `(let (puts)
     (let ((recorder (lambda (overlay &rest _) (push overlay puts))))
       (advice-add 'overlay-put :before recorder)
       (unwind-protect (progn ,@body)
         (advice-remove 'overlay-put recorder)))
     puts))

(ert-deftest org-typora-math-scrolling-does-not-touch-overlays ()
  (org-typora-math-test--painting "$a$ and $b$ and $c$"
    (goto-char 2)
    (org-typora-math--post-command)
    (should org-typora-math--active)
    (should (null (org-typora-math-test--count-overlay-puts
                   (org-typora-math--window-change)
                   (org-typora-math--window-change)
                   (run-hook-with-args 'window-scroll-functions
                                       (selected-window) 1))))))

(ert-deftest org-typora-math-moving-point-repaints-two-formulas ()
  (org-typora-math-test--painting "$a$ and $b$ and $c$"
    (let ((overlays (mapcar #'org-typora-math--item-overlay org-typora-math--items)))
      (goto-char 2)
      (org-typora-math--post-command)
      (goto-char 10)
      (let ((puts (org-typora-math-test--count-overlay-puts
                   (org-typora-math--post-command))))
        (should puts)
        (should (equal (list (nth 0 overlays) (nth 1 overlays))
                       (sort (delete-dups puts)
                             (lambda (x y) (< (overlay-start x) (overlay-start y))))))))))

(ert-deftest org-typora-math-reuses-image-descriptors ()
  (org-typora-math-test--painting "$a$ and $b$"
    (let ((creations 0) (item (car org-typora-math--items)))
      (cl-letf* ((create (symbol-function 'create-image))
                 ((symbol-function 'create-image)
                  (lambda (&rest args) (cl-incf creations) (apply create args))))
        (setq creations 0)
        (org-typora-math--paint)
        (org-typora-math--paint)
        (should (= 0 creations))
        (setf (org-typora-math--item-svg item) (copy-sequence "<svg/>"))
        (org-typora-math--paint)
        (should (= 1 creations))
        (let ((org-typora-math-scale 3.0))
          (org-typora-math--paint)
          (should (= 3 creations))
          (should (eql 3.0 (plist-get (cdr (org-typora-math--item-image item))
                                      :scale))))))))

(ert-deftest org-typora-math-finished-compile-repaints-one-formula ()
  (org-typora-math-test--painting "$a$ and $b$"
    (let* ((item (cadr org-typora-math--items))
           (puts (org-typora-math-test--count-overlay-puts
                  (org-typora-math--repaint-item item))))
      (should puts)
      (should (equal (list (org-typora-math--item-overlay item))
                     (delete-dups puts))))))

(ert-deftest org-typora-math-ignores-dollar-in-text-and-code ()
  (org-typora-math-test--buffer
      "It costs 5 \\$ or so.\n\n: fixed $a$\n\n# comment $b$\n\nReal \\(c\\) and $d$.\n"
    (org-typora-math--collect)
    (should (equal '("\\(c\\)" "$d$")
                   (mapcar #'org-typora-math--item-source org-typora-math--items)))))

(ert-deftest org-typora-math-caches-preamble ()
  (org-typora-math-test--buffer "#+LATEX_HEADER: \\newcommand{\\a}{1}\n\n$\\a$\n"
    (let ((builds 0)
          (make (symbol-function 'org-latex-make-preamble)))
      (cl-letf (((symbol-function 'org-latex-make-preamble)
                 (lambda (&rest args) (cl-incf builds) (apply make args))))
        (let ((first (org-typora-math--preamble)))
          (should (equal first (org-typora-math--preamble)))
          (should (= 1 builds))
          ;; Editing text outside the header lines keeps the preamble.
          (goto-char (point-max))
          (insert "more $b$\n")
          (org-typora-math--preamble)
          (should (= 1 builds))
          (goto-char (point-min))
          (insert "#+LATEX_HEADER: \\newcommand{\\b}{2}\n")
          (should (string-match-p "newcommand{\\\\b}" (org-typora-math--preamble)))
          (should (= 2 builds))
          (let ((org-format-latex-header (concat org-format-latex-header "\n%")))
            (org-typora-math--preamble)
            (should (= 3 builds))))))))

(ert-deftest org-typora-math-display-center-option ()
  (with-temp-buffer
    (setq fill-column 70)
    (should (equal '(space :align-to (- center (50)))
                   (org-typora-math--align 100)))
    (let ((org-typora-math-display-center 'fill-column))
      (should (equal '(space :align-to (- 35.0 (50)))
                     (org-typora-math--align 100))))
    (let ((org-typora-math-display-center 40))
      (should (equal '(space :align-to (- 40 (50)))
                     (org-typora-math--align 100))))
    (let ((org-typora-math-display-center 0.3))
      (should (equal '(space :align-to (- (0.3 . text) (50)))
                     (org-typora-math--align 100))))))

(defmacro org-typora-math-test--disk-cache (&rest body)
  "Run BODY with the disk cache in a new temporary directory."
  `(let ((org-typora-math-cache-directory
          (file-name-as-directory (make-temp-file "org-typora-math-cache-" t))))
     (unwind-protect (progn ,@body)
       (set-file-modes org-typora-math-cache-directory #o700)
       (delete-directory org-typora-math-cache-directory t))))

(defun org-typora-math-test--cache-files ()
  (directory-files-recursively org-typora-math-cache-directory "\\.svg\\'"))

(ert-deftest org-typora-math-disk-cache-survives-toggle ()
  (org-typora-math-test--disk-cache
   (org-typora-math-test--buffer "$a$"
     (org-typora-math--refresh)
     (org-typora-math-test--wait)
     (should (= 1 (length (org-typora-math-test--cache-files))))
     (should (string-match-p "/[0-9a-f][0-9a-f]/[0-9a-f]\\{64\\}\\.svg\\'"
                             (car (org-typora-math-test--cache-files))))
     (org-typora-math-mode -1)
     (org-typora-math-mode 1)
     (org-typora-math--cancel-timer 'org-typora-math--timer)
     (org-typora-math--refresh)
     (should-not org-typora-math--process)
     (should (string-match-p "<svg" (org-typora-math--item-svg
                                     (car org-typora-math--items)))))))

(ert-deftest org-typora-math-disk-cache-serves-new-buffer ()
  (org-typora-math-test--disk-cache
   (org-typora-math-test--buffer "$a$"
     (org-typora-math--refresh)
     (org-typora-math-test--wait))
   (org-typora-math-test--buffer "$a$"
     (org-typora-math--refresh)
     (should-not org-typora-math--process)
     (should (string-match-p "<svg" (org-typora-math--item-svg
                                     (car org-typora-math--items)))))))

(ert-deftest org-typora-math-refresh-command-forces-compile ()
  (org-typora-math-test--disk-cache
   (org-typora-math-test--buffer "$a$"
     (org-typora-math--refresh)
     (org-typora-math-test--wait)
     (let ((file (car (org-typora-math-test--cache-files))))
       (with-temp-file file (insert "<svg>old</svg>"))
       (org-typora-math-refresh)
       (should (processp org-typora-math--process))
       (org-typora-math-test--wait)
       (should-not (equal "<svg>old</svg>"
                          (with-temp-buffer (insert-file-contents file)
                                            (buffer-string))))))))

(ert-deftest org-typora-math-disk-cache-replaces-bad-file ()
  (org-typora-math-test--disk-cache
   (org-typora-math-test--buffer "$a$"
     (org-typora-math--refresh)
     (org-typora-math-test--wait)
     (let ((file (car (org-typora-math-test--cache-files))))
       (org-typora-math-mode -1)
       (org-typora-math-mode 1)
       (org-typora-math--cancel-timer 'org-typora-math--timer)
       (with-temp-file file)
       (org-typora-math--refresh)
       (should (processp org-typora-math--process))
       (org-typora-math-test--wait)
       (should (string-match-p "<svg" (with-temp-buffer
                                        (insert-file-contents file)
                                        (buffer-string))))))))

(ert-deftest org-typora-math-no-disk-cache-when-option-is-nil ()
  (let ((directory (make-temp-file "org-typora-math-cache-" t)))
    (unwind-protect
        (let ((org-typora-math-cache-directory nil))
          (org-typora-math-test--buffer "$a$"
            (should-not (org-typora-math--cache-file "abcdef"))
            (org-typora-math--refresh)
            (org-typora-math-test--wait)
            (should (org-typora-math--item-svg (car org-typora-math--items)))
            (should-not (directory-files-recursively directory ""))))
      (delete-directory directory t))))

(ert-deftest org-typora-math-disk-cache-write-failure-is-harmless ()
  (skip-unless (not (zerop (user-uid))))
  (org-typora-math-test--disk-cache
   (set-file-modes org-typora-math-cache-directory #o500)
   (org-typora-math-test--buffer "$a$"
     (org-typora-math--refresh)
     (org-typora-math-test--wait)
     (let ((item (car org-typora-math--items)))
       (should (string-match-p "<svg" (org-typora-math--item-svg item)))
       (should-not (org-typora-math--item-error item))
       (should-not (org-typora-math-test--cache-files))
       (with-current-buffer org-typora-math--log
         (should (string-match-p "Cannot write cache file" (buffer-string))))))))

;;; org-typora-math-test.el ends here
