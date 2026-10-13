;;; bootstrap-elpaish.el --- Minimal dependency bootstrapper for ELPAish -*- lexical-binding: t; -*-

;; Author: tychoish
;; Keywords: tools, package, elpa, ci

;;; Commentary:
;; Installs all dependencies declared by elpaish and any packages registered
;; in packages.el using standard package.el with GNU, NonGNU, and MELPA archives.
;; Supports automatic path resolution for GitHub Actions container jobs.

;;; Code:

(defvar elpaish-packages-file)
(defvar elpaish-registry)
(declare-function elpaish-load-packages "elpaish-recipes")
(declare-function elpaish-install-ensure-package-dependencies "elpaish-install")

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

(require 'package)

(let* ((ci-dir (expand-file-name "elpa-ci" default-directory))
       (local-dir (expand-file-name "elpa" default-directory))
       (target-dir (cond
                    ((file-directory-p ci-dir) ci-dir)
                    ((file-directory-p local-dir) local-dir)
                    (t (expand-file-name "elpa-ci" default-directory)))))
  (setq package-user-dir target-dir))

(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/")))

(package-initialize)

;; Refresh archives if not already present
(unless (file-exists-p (expand-file-name "archives" package-user-dir))
  (condition-case err
      (package-refresh-contents)
    (error (message "Warning: package-refresh-contents encountered error: %s" (error-message-string err)))))

;; Ensure compat is installed early
(unless (package-installed-p 'compat)
  (condition-case nil
      (package-install 'compat)
    (error nil)))
(let ((ci-dir (expand-file-name "elpa-ci" default-directory)))
  (dolist (d (file-expand-wildcards (expand-file-name "*" ci-dir)))
    (when (file-directory-p d)
      (add-to-list 'load-path d))))
(require 'compat nil t)

;; Load minimal installer and install dependencies for elpaish and all registered packages
(let* ((raw-root (getenv "ELPAISH_ROOT"))
       (elpaish-root (or (and raw-root (elpaish--resolve-container-path raw-root))
                         (and (file-exists-p (expand-file-name "pkg/elpaish.el" default-directory))
                              default-directory)
                         (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name default-directory))))
                         default-directory))
       (pkg-dir (expand-file-name "pkg" elpaish-root))
       (main-file (expand-file-name "elpaish.el" pkg-dir)))
  (if (file-exists-p main-file)
      (progn
        (add-to-list 'load-path pkg-dir)
        (require 'elpaish-install)
        (elpaish-install-ensure-package-dependencies main-file))
    (unless (package-installed-p 'elpaish)
      (condition-case err
          (package-install 'elpaish)
        (error (message "Notice: could not install elpaish from archive: %s" (error-message-string err))))))
  (package-initialize)
  (let ((ci-dir (expand-file-name "elpa-ci" default-directory)))
    (dolist (d (file-expand-wildcards (expand-file-name "*" ci-dir)))
      (when (file-directory-p d)
        (add-to-list 'load-path d))))
  (require 'compat nil t)
  (require 'elpaish)
  (require 'elpaish-recipes)
  (when (and (getenv "ELPAISH_PACKAGES_FILE")
             (not (string-empty-p (getenv "ELPAISH_PACKAGES_FILE"))))
    (setq elpaish-packages-file (elpaish--resolve-container-path (getenv "ELPAISH_PACKAGES_FILE"))))
  (elpaish-load-packages)
  (dolist (recipe (hash-table-values elpaish-registry))
    (elpaish-install-ensure-package-dependencies recipe))
  (package-initialize))

(provide 'bootstrap-elpaish)
;;; bootstrap-elpaish.el ends here
