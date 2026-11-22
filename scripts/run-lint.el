;;; run-lint.el --- Configurable linter & byte-compilation harness -*- lexical-binding: t; -*-

(require 'bytecomp)
(require 'seq)
(require 'subr-x)
(require 'cl-lib)

;; Load bootstrap logic
(let ((bootstrap-file (expand-file-name "bootstrap.el" (file-name-directory (or load-file-name buffer-file-name)))))
  (when (file-exists-p bootstrap-file)
    (load-file bootstrap-file)))
(require 'bootstrap nil t)
(defvar package-lint-main-file)
(declare-function package-lint-buffer "package-lint")
(declare-function relint-file "relint")


(defun elisp-ci--find-target-files ()
  "Find elisp target files to lint from INPUT_TARGET_FILES."
  (let* ((pattern-input (or (getenv "INPUT_TARGET_FILES")
                            (getenv "ELISP_CI_TARGET_FILES")
                            "*.el"))
         (patterns (elisp-ci--parse-list pattern-input))
         (matched nil))
    (dolist (pat patterns)
      (let ((files (file-expand-wildcards pat t)))
        (setq matched (append matched files))))
    (delete-dups matched)))

(defun elisp-ci--package-lint-main-file (files)
  "Return the package-lint main file for FILES, or nil.
Use INPUT_PACKAGE_LINT_MAIN_FILE when set.  Otherwise pick the file in
FILES named after the repository (GITHUB_REPOSITORY, or the current
directory), so secondary files of a multi-file package are linted
against its prefix and dependencies."
  (let ((explicit (string-trim (or (getenv "INPUT_PACKAGE_LINT_MAIN_FILE") "")))
        (repo (file-name-nondirectory
               (directory-file-name
                (or (getenv "GITHUB_REPOSITORY") default-directory)))))
    (if (not (string-empty-p explicit))
        (expand-file-name explicit)
      (when-let* ((match (seq-find
                          (lambda (f)
                            (string= (file-name-base f) repo))
                          files)))
        (expand-file-name match)))))

(defun elisp-ci--run-lint ()
  "Run enabled linters across target files with configurable requirement gates."
  (let* ((files (elisp-ci--find-target-files))
         (active-linters (or (elisp-ci--parse-list (getenv "INPUT_LINTERS"))
                             (elisp-ci--parse-list (getenv "ELISP_CI_LINTERS"))
                             '("byte-compile" "checkdoc")))
         (required-linters (or (elisp-ci--parse-list (getenv "INPUT_REQUIRED_LINTERS"))
                               (elisp-ci--parse-list (getenv "ELISP_CI_REQUIRED_LINTERS"))
                               active-linters))
         (fail-on-warning (not (member (downcase (string-trim (or (getenv "INPUT_FAIL_ON_WARNING")
                                                                  (getenv "ELISP_CI_FAIL_ON_WARNING")
                                                                  "true")))
                                       '("false" "off" "no" "0" "disabled" "none"))))
         (error-count 0)
         (warning-count 0))

    (unless files
      (message "No files found matching INPUT_TARGET_FILES")
      (kill-emacs 0))
    (message "Target files for linting: %S" files)
    (message "Enabled linters: %S (required: %S)" active-linters required-linters)

    ;; 1. Byte compilation
    (when (member "byte-compile" active-linters)
      (message "\n=== [Linter: byte-compile] ===")
      (setq byte-compile-error-on-warn fail-on-warning)
      (dolist (f files)
        (message "==> Byte-compiling %s..." f)
        (condition-case err
            (unless (byte-compile-file (expand-file-name f))
              (message "ERROR: Byte compilation failed for %s" f)
              (if (member "byte-compile" required-linters)
                  (cl-incf error-count)
                (cl-incf warning-count)))
          (error
           (message "ERROR: Exception during byte compilation of %s: %S" f err)
           (if (member "byte-compile" required-linters)
               (cl-incf error-count)
             (cl-incf warning-count))))))

    ;; 2. Checkdoc docstring linting
    (when (member "checkdoc" active-linters)
      (message "\n=== [Linter: checkdoc] ===")
      (require 'checkdoc)
      (dolist (f files)
        (message "==> Checking docstrings in %s..." f)
        (with-temp-buffer
          (insert-file-contents f)
          (emacs-lisp-mode)
          (condition-case err
              (checkdoc-current-buffer t)
            (error
             (message "Checkdoc warning in %s: %S" f err)
             (if (member "checkdoc" required-linters)
                 (cl-incf error-count)
               (cl-incf warning-count)))))))

    ;; 3. Package-lint (if requested)
    (when (member "package-lint" active-linters)
      (message "\n=== [Linter: package-lint] ===")
      (elisp-ci--install-dependencies '(package-lint))
      (require 'package-lint)
      (setq package-lint-main-file
            (elisp-ci--package-lint-main-file files))
      (message "package-lint main file: %S" package-lint-main-file)
      (dolist (f files)
        (message "==> Running package-lint on %s..." f)
        (condition-case err
            (let* ((buf (find-file-noselect (expand-file-name f) t))
                   (errors (with-current-buffer buf
                             (unwind-protect (package-lint-buffer)
                               (kill-buffer buf)))))
              (when errors
                (dolist (e errors)
                  (message "package-lint: %s:%d:%d: %s: %s"
                           f (nth 0 e) (nth 1 e) (nth 2 e) (nth 3 e)))
                (if (member "package-lint" required-linters)
                    (cl-incf error-count (length errors))
                  (cl-incf warning-count (length errors)))))
          (error
           (message "ERROR: package-lint failed on %s: %S" f err)
           (if (member "package-lint" required-linters)
               (cl-incf error-count)
             (cl-incf warning-count))))))

    ;; 4. Relint (regexp linter, if requested)
    (when (member "relint" active-linters)
      (message "\n=== [Linter: relint] ===")
      (elisp-ci--install-dependencies '(relint))
      (require 'relint)
      (dolist (f files)
        (message "==> Running relint on %s..." f)
        (condition-case err
            (let ((errors (relint-file (expand-file-name f))))
              (when errors
                (if (member "relint" required-linters)
                    (cl-incf error-count (length errors))
                  (cl-incf warning-count (length errors)))))
          (error
           (message "Error running relint on %s: %S" f err)))))

    (message "\n=== Lint Summary ===")
    (message "Errors (blocking): %d | Warnings (advisory): %d" error-count warning-count)
    (if (> error-count 0)
        (progn
          (message "Linting failed with %d fatal error(s)" error-count)
          (kill-emacs 1))
      (message "Linting completed successfully")
      (kill-emacs 0))))

(elisp-ci--run-lint)

;;; run-lint.el ends here
