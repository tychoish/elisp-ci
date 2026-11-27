;;; test-coverage-summary.el --- Coverage summary tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Regression tests for the coverage summary shown by GitHub Actions.

;;; Code:

(require 'ert)
(require 'map)
(require 'coverage-summary)

(ert-deftest coverage-summary/numbers-and-weighted-total ()
  "Show measured lines, missed lines and weighted aggregate coverage."
  (let* ((summary (make-temp-file "coverage-summary"))
         (process-environment (copy-sequence process-environment))
         (statistics
          (map-into
           `((,(expand-file-name "src/example.el") . ,(map-into '((2 . 3) (4 . 0)) 'hash-table))
             (,(expand-file-name "lib/example.el") . ,(map-into '((1 . 1)) 'hash-table)))
           '(hash-table :test equal))))
    (unwind-protect
        (progn
          (setenv "GITHUB_STEP_SUMMARY" summary)
          (elisp-ci--render-step-summary
           '("src/example.el" "lib/example.el" "missing.el")
           "coverage.json" "simplecov" statistics)
          (with-temp-buffer
            (insert-file-contents summary)
            (should (search-forward "| `src/example.el` | 50.00% | 2 | 1 | 1 | 4 |" nil t))
            (should (search-forward "| `lib/example.el` | 100.00% | 1 | 1 | 0 | — |" nil t))
            (should (search-forward "| `missing.el` | N/A | — | — | — | Not instrumented |" nil t))
            (should (search-forward "| **Total** | **66.67%** | 3 | 2 | 1 |" nil t))))
      (delete-file summary))))

(ert-deftest coverage-summary/empty-data ()
  "Empty coverage must be explicit and must not divide by zero."
  (let* ((summary (make-temp-file "coverage-summary"))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (setenv "GITHUB_STEP_SUMMARY" summary)
          (elisp-ci--render-step-summary nil "coverage.txt" "text" (make-hash-table))
          (with-temp-buffer
            (insert-file-contents summary)
            (should (search-forward "**N/A**" nil t))
            (should (search-forward "No executable lines were measured" nil t))))
      (delete-file summary))))

(ert-deftest coverage-summary/no-github-environment ()
  "Local coverage runs do not require GitHub's summary environment."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "GITHUB_STEP_SUMMARY" nil)
    (should-not (elisp-ci--render-step-summary nil "coverage.json" "simplecov" nil))))

(ert-deftest coverage-summary/zero-coverage-and-empty-file ()
  "Distinguish uncovered lines from files without executable lines."
  (let* ((summary (make-temp-file "coverage-summary"))
         (process-environment (copy-sequence process-environment))
         (statistics
          (map-into
           `((,(expand-file-name "uncovered.el") . ,(map-into '((9 . 0) (2 . 0)) 'hash-table))
             (,(expand-file-name "empty.el") . ,(make-hash-table)))
           '(hash-table :test equal))))
    (unwind-protect
        (progn
          (setenv "GITHUB_STEP_SUMMARY" summary)
          (elisp-ci--render-step-summary
           '("uncovered.el" "empty.el") "coverage.txt" "text" statistics)
          (with-temp-buffer
            (insert-file-contents summary)
            (should (search-forward "| `uncovered.el` | 0.00% | 2 | 0 | 2 | 2, 9 |" nil t))
            (should (search-forward "| `empty.el` | N/A | 0 | 0 | 0 | No executable lines |" nil t))
            (should (search-forward "| **Total** | **0.00%** | 2 | 0 | 2 |" nil t))))
      (delete-file summary))))

(ert-deftest coverage-summary/creates-summary-file ()
  "Create a summary file that GitHub has named but not yet created."
  (let* ((directory (make-temp-file "coverage-summary" t))
         (summary (expand-file-name "summary.md" directory))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (setenv "GITHUB_STEP_SUMMARY" summary)
          (elisp-ci--render-step-summary nil "coverage.txt" "text" nil)
          (should (file-exists-p summary)))
      (delete-directory directory t))))

(ert-deftest coverage-summary/symlinked-source ()
  "Match the canonical paths used by Undercover's statistics."
  (let* ((directory (make-temp-file "coverage-summary" t))
         (source (expand-file-name "source.el" directory))
         (alias (expand-file-name "alias.el" directory))
         (summary (expand-file-name "summary.md" directory))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (with-temp-file source (insert "(provide 'source)\n"))
          (make-symbolic-link source alias)
          (setenv "GITHUB_STEP_SUMMARY" summary)
          (elisp-ci--render-step-summary
           (list alias) "coverage.txt" "text"
           (map-into `((,source . ,(map-into '((1 . 1)) 'hash-table)))
                     '(hash-table :test equal)))
          (with-temp-buffer
            (insert-file-contents summary)
            (should (search-forward "| 100.00% | 1 | 1 | 0 |" nil t))))
      (delete-directory directory t))))

(provide 'test-coverage-summary)
;;; test-coverage-summary.el ends here
