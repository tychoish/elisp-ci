;;; run-ert.el --- run-ert.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'bootstrap nil t)

(declare-function elpaish-test-package-batch "elpaish-check")

;; Load bootstrap logic
(let ((bootstrap-file (expand-file-name "bootstrap.el" (file-name-directory (or load-file-name buffer-file-name)))))
  (when (file-exists-p bootstrap-file)
    (load-file bootstrap-file)))

(defun elisp-ci--run-tests ()
  "Load test files and execute ERT test suite."
  (let ((test-files (elisp-ci--find-test-files))
        (runner (or (getenv "INPUT_RUNNER")
                    (getenv "ELISP_CI_RUNNER")
                    "ert")))
    (unless test-files
      (message "No test files found matching INPUT_TEST_FILES")
      (kill-emacs 1))
    (message "Discovered test files: %S" test-files)

    (if (string-equal runner "elpaish")
        (progn
          (unless (package-installed-p 'elpaish)
            (package-install 'elpaish))
          (require 'elpaish-check)
          (elpaish-test-package-batch))
      ;; Standard ERT batch runner
      (dolist (tf test-files)
        (message "Loading test file: %s" tf)
        (load-file (expand-file-name tf)))
      (ert-run-tests-batch-and-exit))))

(elisp-ci--run-tests)

;;; run-ert.el ends here
