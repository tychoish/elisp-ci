;;; run-eval.el --- Batch evaluation runner for elisp-ci -*- lexical-binding: t; -*-

(require 'seq)
(require 'subr-x)

(defun elisp-ci-action-path ()
  "Return normalized action directory path, adapting to Docker container mounts.
Checks inputs, environment variables, and converts GitHub runner host paths
(/home/runner/work/...) to in-container mount points (/__w/...) when needed."
  (let* ((raw (or (getenv "INPUT_ACTION_PATH")
                  (getenv "ACTION_PATH")
                  (getenv "ELISP_CI_ACTION_PATH")
                  (getenv "ELISP_CI_HOST_ACTION_PATH")
                  (getenv "GITHUB_ACTION_PATH")
                  default-directory))
         (clean (and raw (string-trim raw))))
    (cond
     ((or (null clean) (string-empty-p clean))
      (expand-file-name default-directory))
     ((file-directory-p clean)
      (expand-file-name clean))
     ((and (string-prefix-p "/home/runner/work/" clean)
           (file-directory-p (concat "/__w/" (substring clean 18))))
      (expand-file-name (concat "/__w/" (substring clean 18))))
     ((and (getenv "GITHUB_ACTION_PATH")
           (file-directory-p (getenv "GITHUB_ACTION_PATH")))
      (expand-file-name (getenv "GITHUB_ACTION_PATH")))
     (t
      (expand-file-name default-directory)))))

(defun elisp-ci--eval-runner ()
  "Execute batch evaluation runner.
Processes load-paths, dependencies, file loading, and inline expression
evaluation."
  ;; 1. Optional dependency bootstrapping
  (let* ((dep-input (getenv "INPUT_DEPENDENCIES"))
         (has-deps (and dep-input (not (string-empty-p (string-trim dep-input)))))
         (bootstrap-file (expand-file-name "bootstrap.el"
                                           (file-name-directory (or load-file-name buffer-file-name)))))
    (when (and has-deps (file-exists-p bootstrap-file))
      (load-file bootstrap-file)))

  ;; 2. Populate load-paths
  (let* ((lp-raw (or (getenv "INPUT_LOAD_PATHS")
                     (getenv "ELISP_CI_LOAD_PATHS")
                     "."))
         (tokens (split-string lp-raw "[\t\n\r ,]+" t)))
    (dolist (tok tokens)
      (let* ((p (string-trim tok))
             (candidate (cond
                         ((file-directory-p p) (expand-file-name p))
                         ((file-directory-p (expand-file-name p (elisp-ci-action-path)))
                          (expand-file-name p (elisp-ci-action-path)))
                         (t nil))))
        (when candidate
          (add-to-list 'load-path candidate)))))

  ;; 3. File execution
  (let ((file (or (getenv "INPUT_FILE")
                  (getenv "ELISP_CI_EVAL_FILE"))))
    (when (and file (not (string-empty-p (string-trim file))))
      (let* ((clean-file (string-trim file))
             (resolved (cond
                        ((file-exists-p clean-file) (expand-file-name clean-file))
                        ((file-exists-p (expand-file-name clean-file (elisp-ci-action-path)))
                         (expand-file-name clean-file (elisp-ci-action-path)))
                        (t (error "Elisp script file not found: %s" clean-file)))))
        (load resolved nil nil t))))

  ;; 4. Inline expression evaluation
  (let ((expr (or (getenv "INPUT_EVAL")
                  (getenv "ELISP_CI_EVAL_EXPR"))))
    (when (and expr (not (string-empty-p (string-trim expr))))
      (condition-case err
          (eval (read (concat "(progn\n" expr "\n)")) t)
        (error
         (message "Execution error during elisp-ci/eval: %S" err)
         (kill-emacs 1))))))

(elisp-ci--eval-runner)

(provide 'run-eval)
;;; run-eval.el ends here
