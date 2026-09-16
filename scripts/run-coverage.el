;;; run-coverage.el --- Test coverage measurement and reporting harness -*- lexical-binding: t; -*-

(require 'ert)
(require 'seq)
(require 'subr-x)

(defvar undercover-report-format)
(defvar undercover-report-file)
(declare-function undercover "undercover")
(declare-function undercover-safe "undercover")

;; Load bootstrap logic
(let ((bootstrap-file (expand-file-name "bootstrap.el" (file-name-directory (or load-file-name buffer-file-name)))))
  (when (file-exists-p bootstrap-file)
    (load-file bootstrap-file)))
(require 'bootstrap nil t)

(defun elisp-ci--render-step-summary (source-files output-file format-opt)
  "Render a markdown summary table to $GITHUB_STEP_SUMMARY if available."
  (let ((summary-file (getenv "GITHUB_STEP_SUMMARY")))
    (when (and summary-file (file-exists-p summary-file))
      (with-temp-buffer
        (insert "\n## 📊 Emacs Lisp Test Coverage Report\n\n")
        (insert (format "- **Report Format**: `%s`\n" format-opt))
        (insert (format "- **Artifact Output**: `%s`\n" output-file))
        (insert (format "- **Instrumented Files**: %d file(s)\n\n" (length source-files)))
        (insert "| Source File | Status |\n")
        (insert "| :--- | :--- |\n")
        (dolist (sf source-files)
          (insert (format "| `%s` | Instrumented |\n" (file-name-nondirectory sf))))
        (insert "\n")
        (append-to-file (point-min) (point-max) summary-file)))))

(defun elisp-ci--setup-and-run-coverage ()
  "Setup undercover, load test files, and output coverage report."
  (let* ((output-file (or (getenv "INPUT_OUTPUT_FILE")
                          (getenv "ELISP_CI_OUTPUT_FILE")
                          "coverage.json"))
         (source-pat (or (getenv "INPUT_SOURCE_FILES")
                         (getenv "ELISP_CI_SOURCE_FILES")
                         "*.el"))
         (format-opt (or (getenv "INPUT_REPORT_FORMAT")
                         (getenv "ELISP_CI_REPORT_FORMAT")
                         "simplecov"))
         (test-files (elisp-ci--find-test-files))
         (source-patterns (elisp-ci--parse-list source-pat))
         (source-files nil))

    (dolist (sp source-patterns)
      (setq source-files (append source-files (file-expand-wildcards sp t))))
    (setq source-files (delete-dups source-files))

    ;; Install undercover from MELPA
    (elisp-ci--install-dependencies '(undercover))
    (require 'undercover)
    (setq undercover-report-format (intern format-opt))
    (setq undercover-report-file (expand-file-name output-file))

    ;; Instrument source files
    (message "Instrumenting %d source file(s) for coverage: %S" (length source-files) source-files)
    (dolist (sf source-files)
      (undercover sf))

    ;; Hook markdown summary table to kill-emacs-hook
    (add-hook 'kill-emacs-hook
              (lambda ()
                (elisp-ci--render-step-summary source-files output-file format-opt)))

    ;; Load test files and execute ERT suite
    (message "Loading test files: %S" test-files)
    (dolist (tf test-files)
      (load-file (expand-file-name tf)))

    (message "Running ERT tests with coverage measurement...")
    (condition-case err
        (ert-run-tests-batch-and-exit)
      (error
       (message "Tests execution finished with: %S" err)))))

(elisp-ci--setup-and-run-coverage)

;;; run-coverage.el ends here
