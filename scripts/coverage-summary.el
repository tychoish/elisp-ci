;;; coverage-summary.el --- Render measured coverage -*- lexical-binding: t; -*-

;;; Commentary:
;; Render the same line statistics used by Undercover's coverage artifacts.

;;; Code:

(require 'map)
(require 'seq)
(require 'subr-x)

(defun elisp-ci--render-step-summary (source-files output-file format-opt statistics)
  "Append measured coverage to GitHub's step summary when available.
SOURCE-FILES are the requested files, OUTPUT-FILE is the artifact path,
FORMAT-OPT names its format, and STATISTICS maps absolute file names to
maps of executable line numbers and their hit counts."
  (when-let* ((summary-file (getenv "GITHUB_STEP_SUMMARY")))
    (let ((total-lines 0)
          (total-covered 0))
      (with-temp-buffer
        (insert "\n## 📊 Emacs Lisp Test Coverage Report\n\n")
        (insert (format "- **Report Format**: `%s`\n" format-opt))
        (insert (format "- **Artifact Output**: `%s`\n\n" output-file))
        (insert "| Source File | Coverage | Executable Lines | Covered | Missed | Missed Lines |\n")
        (insert "| :--- | ---: | ---: | ---: | ---: | :--- |\n")
        (seq-do
         (lambda (source-file)
           (let* ((line-hits (map-elt statistics (file-truename source-file)))
                  (line-count (map-length line-hits))
                  (covered 0)
                  (missed-lines nil)
                  (display-name
                   (replace-regexp-in-string
                    "[|\n\r]" " " (file-relative-name source-file))))
             (map-do
              (lambda (line hits)
                (if (> hits 0)
                    (setq covered (1+ covered))
                  (push line missed-lines)))
              line-hits)
             (setq total-lines (+ total-lines line-count))
             (setq total-covered (+ total-covered covered))
             (cond
              ((null line-hits)
               (insert (format "| `%s` | N/A | — | — | — | Not instrumented |\n"
                               display-name)))
              ((zerop line-count)
               (insert (format "| `%s` | N/A | 0 | 0 | 0 | No executable lines |\n"
                               display-name)))
              (t
               (insert
                (format "| `%s` | %.2f%% | %d | %d | %d | %s |\n"
                        display-name (* 100.0 (/ (float covered) line-count))
                        line-count covered (- line-count covered)
                        (if missed-lines
                            (mapconcat #'number-to-string (sort missed-lines #'<) ", ")
                          "—")))))))
         source-files)
        (insert
         (format "| **Total** | **%s** | %d | %d | %d | |\n\n"
                 (if (> total-lines 0)
                     (format "%.2f%%" (* 100.0 (/ (float total-covered) total-lines)))
                   "N/A")
                 total-lines total-covered (- total-lines total-covered)))
        (if (zerop total-lines)
            (insert "No executable lines were measured. Check source patterns and that tests load uncompiled source files.\n")
          (insert "Coverage counts executable lines only; the total is weighted by executable line count.\n"))
        (append-to-file (point-min) (point-max) summary-file)))))

(provide 'coverage-summary)
;;; coverage-summary.el ends here
