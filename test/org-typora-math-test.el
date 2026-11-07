;;; org-typora-math-test.el --- Tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-typora-math)

(defmacro org-typora-math-test--buffer (text &rest body)
  "Evaluate BODY in an Org buffer containing TEXT, without GUI painting."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,text)
     (goto-char (point-min))
     (cl-letf (((symbol-function 'org-typora-math--paint) #'ignore))
       (unwind-protect
           (progn (org-typora-math-mode 1)
                  (org-typora-math--cancel-timer 'org-typora-math--timer)
                  ,@body)
         (org-typora-math-mode -1)))))

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
    (kill-buffer org-typora-math--log)
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

;;; org-typora-math-test.el ends here
