;;; bench.el --- Refresh benchmark for org-typora-math -*- lexical-binding: t; -*-

;; Usage: make bench
;; Buffer: about 200 KB, 300 headings, 600 formulas, no #+SETUPFILE.

(require 'benchmark)
(require 'org-typora-math)

(defconst bench-runs 5)

(defun bench-text ()
  "Return the benchmark buffer text."
  (let ((filler (mapconcat #'identity
                           (make-list 7 "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.")
                           " ")))
    (mapconcat
     (lambda (i)
       (format "* Heading %d\n%s\nInline $x_{%d}+y^2$.\n\n\\begin{equation}\nE_%d = mc^2\n\\end{equation}\n\n#+begin_src latex\n$skipped$\n#+end_src\n\n"
               i filler i i))
     (number-sequence 1 300) "")))

(defun bench-time (function)
  "Return (FIRST . MEAN) milliseconds of FUNCTION over `bench-runs' later runs."
  (let ((first (benchmark-elapse (funcall function)))
        (total 0.0))
    (dotimes (_ bench-runs)
      (cl-incf total (benchmark-elapse (funcall function))))
    (cons (* 1000 first) (* 1000 (/ total bench-runs)))))

(defun bench-report (label result)
  (princ (format "%-28s first %7.1f ms   mean %7.1f ms\n"
                 label (car result) (cdr result))))

(with-temp-buffer
  (org-mode)
  (insert (bench-text))
  (princ (format "Buffer: %d KB\n" (/ (buffer-size) 1024)))
  (setq org-typora-math--cache (make-hash-table :test #'equal))
  (bench-report "collect formulas" (bench-time #'org-typora-math--collect))
  (princ (format "Formulas found: %d\n" (length org-typora-math--items)))
  (bench-report "collect after one edit"
                (bench-time (lambda ()
                              (goto-char (/ (point-max) 2))
                              (insert "x")
                              (org-typora-math--collect))))
  (bench-report "build preamble" (bench-time #'org-typora-math--preamble))
  (when (fboundp 'org-typora-math--build-jobs)
    (bench-report "build documents and hashes"
                  (bench-time (lambda ()
                                (dolist (item org-typora-math--items)
                                  (setf (org-typora-math--item-attempted item) nil))
                                (org-typora-math--build-jobs))))))

;;; bench.el ends here
