;;; run-coverage.el --- Test coverage measurement and reporting harness -*- lexical-binding: t; -*-

;;; Commentary:
;; Instrument sources, run ERT, and report measured line coverage on exit.

;;; Code:

(require 'ert)
(require 'seq)
(require 'subr-x)

(defvar undercover--files-coverage-statistics)
(defvar undercover-force-coverage)
(declare-function undercover-report "undercover")
(declare-function elisp-ci--render-step-summary "coverage-summary")

;; Load bootstrap logic
(let ((bootstrap-file (expand-file-name "bootstrap.el" (file-name-directory (or load-file-name buffer-file-name)))))
  (when (file-exists-p bootstrap-file)
    (load-file bootstrap-file)))
(require 'bootstrap)

(defvar elisp-ci--coverage-context nil
  "Source files, output path and format for the current coverage run.")

(defun elisp-ci--finish-coverage ()
  "Write the coverage artifact before rendering its measured statistics."
  (undercover-report)
  (pcase-let ((`(,source-files ,output-file ,format-opt) elisp-ci--coverage-context))
    (elisp-ci--render-step-summary
     source-files output-file format-opt undercover--files-coverage-statistics)))

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
    (make-directory (file-name-directory (expand-file-name output-file)) t)
    (setq undercover-force-coverage t)

    ;; Instrument source files
    (message "Instrumenting %d source file(s) for coverage: %S" (length source-files) source-files)
    (eval `(undercover ,@source-files
                       (:report-format ',(intern format-opt))
                       (:report-file ,(expand-file-name output-file))
                       (:report-on-kill nil)
                       (:send-report nil)
                       (:merge-report nil))
          t)
    (require 'coverage-summary
             (expand-file-name "coverage-summary.el"
                               (file-name-directory (or load-file-name buffer-file-name))))

    ;; Hook markdown summary table to kill-emacs-hook
    (setq elisp-ci--coverage-context (list source-files output-file format-opt))
    (add-hook 'kill-emacs-hook #'elisp-ci--finish-coverage)

    ;; Load test files and execute ERT suite
    (message "Loading test files: %S" test-files)
    (dolist (tf test-files)
      (load-file (expand-file-name tf)))

    (message "Running ERT tests with coverage measurement...")
    ;; ERT must handle its own skip conditions.  On Emacs 29, an outer
    ;; `condition-case' for errors aborts the run when a test is skipped.
    (ert-run-tests-batch-and-exit)))

(elisp-ci--setup-and-run-coverage)

(provide 'run-coverage)
;;; run-coverage.el ends here
