;;; build-elpaish.el --- Headless build runner for ELPAish archives -*- lexical-binding: t; -*-

;; Author: tychoish
;; Keywords: tools, package, elpa, ci

;;; Commentary:
;; Headless entry point for building ELPAish package archives.
;; Invoked by GitHub Actions CI workflows or local batch runs.
;; Supports automatic path resolution for GitHub Actions container jobs.

;;; Code:

(require 'cl-lib)

(defvar elpaish-parallel-jobs)
(defvar elpaish-work-dir)
(defvar elpaish-packages-file)
(defvar elpaish-output-dir)
(defvar elpaish-run-preflight)
(declare-function elpaish-build-all "elpaish")
(declare-function elpaish-init-signing-from-env "elpaish")
(declare-function elpaish-load-packages "elpaish-recipes")

(unless (macrop 'incf)
  (defmacro incf (place &optional delta)
    "Increment PLACE by DELTA (default 1)."
    (declare (debug (gv-place &optional form)))
    (if (and (symbolp place) (null delta))
        (list 'setq place (list '1+ place))
      (list 'cl-incf place delta))))

(unless (macrop 'decf)
  (defmacro decf (place &optional delta)
    "Decrement PLACE by DELTA (default 1)."
    (declare (debug (gv-place &optional form)))
    (if (and (symbolp place) (null delta))
        (list 'setq place (list '1- place))
      (list 'cl-decf place delta))))

(unless (macrop 'static-when)
  (defmacro static-when (condition &rest body)
    "A conditional compilation macro."
    (declare (indent 1) (debug t))
    (when (eval condition lexical-binding)
      (cons 'progn body))))

(defun elpaish--resolve-container-path (path)
  "Resolve PATH, translating runner host paths to container paths if needed."
  (cond
   ((or (null path) (string-empty-p path)) path)
   ((file-exists-p path) (expand-file-name path))
   ((string-prefix-p "/home/runner/work/" path)
    (let ((cpath (concat "/__w/" (substring path (length "/home/runner/work/")))))
      (if (file-exists-p cpath)
          (expand-file-name cpath)
        path)))
   (t path)))

(let* ((raw-root (getenv "ELPAISH_ROOT"))
       (elpaish-root (or (and raw-root (elpaish--resolve-container-path raw-root))
                         (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name default-directory))))
                         default-directory))
       (pkg-dir (expand-file-name "pkg" elpaish-root))
       (scripts-dir (expand-file-name "scripts" elpaish-root)))
  (add-to-list 'load-path pkg-dir)
  (add-to-list 'load-path scripts-dir)
  (add-to-list 'load-path (expand-file-name "pkg" default-directory))
  (add-to-list 'load-path (expand-file-name "scripts" default-directory)))

;; Initialize package infrastructure so dependencies installed by bootstrap-elpaish.el
;; or present in elpa/ are activated.
(require 'package)

(let ((ci-dir (expand-file-name "elpa-ci" default-directory)))
  (when (file-directory-p ci-dir)
    (setq package-user-dir ci-dir)
    (dolist (d (file-expand-wildcards (expand-file-name "*" ci-dir)))
      (when (file-directory-p d)
        (add-to-list 'load-path d)))))

(let* ((ci-elpa (expand-file-name "elpa-ci" default-directory))
       (local-elpa (expand-file-name "elpa" default-directory))
       (target-user-dir (cond
                         ((file-directory-p ci-elpa) ci-elpa)
                         ((file-directory-p local-elpa) local-elpa)
                         (t (and (boundp 'package-user-dir) package-user-dir))))
       (package-user-dir (or target-user-dir (expand-file-name "elpa" default-directory)))
       (package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                           ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                           ("melpa" . "https://melpa.org/packages/"))))
  (package-initialize)

  ;; Ensure elpaish pkg/ directory takes precedence over installed packages if present
  (let* ((raw-root (getenv "ELPAISH_ROOT"))
         (elpaish-root (or (and raw-root (elpaish--resolve-container-path raw-root))
                           (and (file-exists-p (expand-file-name "pkg/elpaish.el" default-directory))
                                default-directory)
                           (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name default-directory))))
                           default-directory))
         (pkg-dir (expand-file-name "pkg" elpaish-root)))
    (when (file-exists-p (expand-file-name "elpaish.el" pkg-dir))
      (setq load-path (cons pkg-dir (delete pkg-dir load-path)))))
  (require 'compat)
  (require 'elpaish)
  (require 'elpaish-recipes)
  (require 'elpaish-website)
  (require 'elpaish-check nil t)
  (require 'elpaish-async nil t)

  ;; Configure concurrency from ELPAISH_PARALLEL_JOBS
  (when-let* ((jobs-env (getenv "ELPAISH_PARALLEL_JOBS"))
              ((not (string-empty-p jobs-env))))
    (if (or (string= jobs-env "auto") (string= jobs-env "0"))
        (setq elpaish-parallel-jobs (min 8 (num-processors)))
      (let ((parsed (string-to-number jobs-env)))
        (when (> parsed 0)
          (setq elpaish-parallel-jobs parsed)))))

  ;; Configure cloned repositories workspace directory from environment
  (when (and (getenv "ELPAISH_WORK_DIR")
             (not (string-empty-p (getenv "ELPAISH_WORK_DIR"))))
    (setq elpaish-work-dir (expand-file-name (elpaish--resolve-container-path (getenv "ELPAISH_WORK_DIR")) default-directory)))

  ;; Load external package definitions from top-level packages.el or ELPAISH_PACKAGES_FILE
  (when (and (getenv "ELPAISH_PACKAGES_FILE")
             (not (string-empty-p (getenv "ELPAISH_PACKAGES_FILE"))))
    (setq elpaish-packages-file (elpaish--resolve-container-path (getenv "ELPAISH_PACKAGES_FILE"))))
  (elpaish-load-packages)

  ;; Configure output directory from environment or default to public/
  (setq elpaish-output-dir
        (if (and (getenv "ELPAISH_OUTPUT_DIR")
                 (not (string-empty-p (getenv "ELPAISH_OUTPUT_DIR"))))
            (elpaish--resolve-container-path (getenv "ELPAISH_OUTPUT_DIR"))
          (expand-file-name "public/" default-directory)))

  ;; Preflight quality gates can be toggled via ELPAISH_RUN_PREFLIGHT
  (when-let* ((pf-env (getenv "ELPAISH_RUN_PREFLIGHT")))
    (when (not (string-empty-p (string-trim pf-env)))
      (setq elpaish-run-preflight
            (not (member (downcase (string-trim pf-env))
                         '("false" "off" "no" "0" "none" "skip" "disabled"))))))

  ;; Initialize GPG signing from environment variables (ELPAISH_SIGNING_KEY)
  (elpaish-init-signing-from-env)

  (let ((streams (if (and (getenv "ELPAISH_STREAMS")
                          (not (string-empty-p (getenv "ELPAISH_STREAMS"))))
                     (let ((items (split-string (getenv "ELPAISH_STREAMS"))))
                       (if (member "all" items)
                           'all
                         (mapcar #'intern items)))
                   'all)))
    (message "[elpaish] Building ELPAish repository (%s) into %s..." streams elpaish-output-dir)
    (if (eq streams 'all)
        (elpaish-build-all 'all elpaish-output-dir)
      (dolist (st streams)
        (elpaish-build-all st elpaish-output-dir))))
  (message "[elpaish] Repository build complete!"))

(provide 'build-elpaish)
;;; build-elpaish.el ends here
