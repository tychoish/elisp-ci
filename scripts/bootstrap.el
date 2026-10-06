;;; bootstrap.el --- Bootstrap package.el, keyrings, and dependencies -*- lexical-binding: t; -*-

(require 'package)
(require 'seq)
(require 'subr-x)
(require 'url)

(defconst elisp-ci--builtin-packages
  '("emacs" "cl-lib" "subr-x" "seq" "pcase" "bytecomp" "ert" "syntax" "faces")
  "Built-in Emacs packages that do not need external ELPA installation.")

(defun elisp-ci--parse-list (input)
  "Parse INPUT into a list of cleaned string tokens.
INPUT can be:
- A list or sequence of strings, symbols, or sub-elements.
- A string in YAML structure format (bullets `- item` or `* item`, `[a, b]`).
- A string with newline, comma, tab, or space delimiters.
- Nil (returns nil)."
  (cond
   ((null input) nil)
   ((and (sequencep input) (not (stringp input)))
    (let ((results nil))
      (seq-doseq (elem input)
        (dolist (item (elisp-ci--parse-list elem))
          (push item results)))
      (nreverse (delete-dups results))))
   ((stringp input)
    (let* ((cleaned (string-trim input)))
      (if (string-empty-p cleaned)
          nil
        (let* ((unbracketed (if (and (string-prefix-p "[" cleaned)
                                     (string-suffix-p "]" cleaned))
                                (substring cleaned 1 -1)
                              cleaned))
               (raw-lines (split-string unbracketed "[\n\r]+" t))
               (results nil))
          (dolist (line raw-lines)
            (let* ((line-no-comment (replace-regexp-in-string "#.*$" "" line))
                   (item (string-trim line-no-comment)))
              ;; Strip leading YAML bullet: '- ' or '* '
              (when (string-match "\\`[-*]\\s-+\\(.*\\)\\'" item)
                (setq item (string-trim (match-string 1 item))))
              ;; Strip single leading dash without space e.g. "-item"
              (when (and (string-prefix-p "-" item) (> (length item) 1) (not (string-prefix-p "--" item)))
                (setq item (string-trim (substring item 1))))
              ;; Split comma, space, or tab separated tokens on this line
              (dolist (tok (split-string item "[, \t]+" t))
                (let ((sub (string-trim tok)))
                  ;; Strip surrounding single or double quotes from individual token
                  (when (or (and (string-prefix-p "\"" sub) (string-suffix-p "\"" sub) (> (length sub) 1))
                            (and (string-prefix-p "'" sub) (string-suffix-p "'" sub) (> (length sub) 1)))
                    (setq sub (substring sub 1 -1)))
                  (unless (string-empty-p sub)
                    (push sub results))))))
          (nreverse (delete-dups results))))))
   ((symbolp input)
    (list (symbol-name input)))
   (t
    (list (format "%s" input)))))

(defun elisp-ci--discover-package-requires ()
  "Extract dependencies from Package-Requires headers in source .el files."
  (let ((el-files (file-expand-wildcards "*.el" t))
        (deps nil))
    (dolist (f el-files)
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (when (re-search-forward "^;;;?\\s-*Package-Requires:\\s-*" nil t)
          (let* ((start (point))
                 (end (line-end-position))
                 (header-str (buffer-substring-no-properties start end))
                 (parsed (condition-case nil
                             (read header-str)
                           (error nil))))
            (dolist (item parsed)
              (let ((name (if (listp item) (symbol-name (car item)) (symbol-name item))))
                (unless (member name elisp-ci--builtin-packages)
                  (push name deps))))))))
    (delete-dups (nreverse deps))))

(defun elisp-ci--get-dependencies (&optional extra-deps)
  "Get all required dependencies.
Resolved from inputs, env vars, Package-Requires headers, and EXTRA-DEPS."
  (let* ((input-dep (getenv "INPUT_DEPENDENCIES"))
         (env-dep (or (getenv "ELISP_CI_DEPENDENCIES")
                      (getenv "ELISP_DEPENDENCIES")
                      (getenv "DEPENDENCIES")))
         (raw (cond
               ((and input-dep (not (string-empty-p (string-trim input-dep))))
                input-dep)
               ((and env-dep (not (string-empty-p (string-trim env-dep))))
                env-dep)
               (t nil)))
         (specified (when raw (elisp-ci--parse-list raw)))
         (discovered (unless specified (elisp-ci--discover-package-requires)))
         (extra (when extra-deps (elisp-ci--parse-list extra-deps)))
         (all (append (or specified discovered) extra)))
    (when all
      (message "Resolved package dependencies: %S (source: %s)"
               all
               (cond (specified "configured via input/env")
                     (discovered "auto-discovered from Package-Requires")
                     (t "extra-deps"))))
    all))

(defun elisp-ci--import-elpaish-keyring ()
  "Fetch and import ELPAish GPG public keyring for archive verification."
  (condition-case err
      (let* ((keyring-url (or (getenv "INPUT_KEYRING_URL")
                              (getenv "ELISP_CI_KEYRING_URL")
                              "https://tychoish.github.io/elpaish/elpaish-keyring.gpg"))
             (temp-file (make-temp-file "elpaish-keyring" nil ".gpg")))
        (message "Fetching ELPAish GPG keyring from %s..." keyring-url)
        (url-copy-file keyring-url temp-file t)
        (when (fboundp 'package-import-keyring)
          (package-import-keyring temp-file)
          (message "Successfully imported ELPAish GPG keyring into package.el GnuPG dir."))
        (delete-file temp-file))
    (error
     (message "Note: Could not import ELPAish GPG keyring (%s); using fallback unsigned archive entry."
              (error-message-string err)))))

(defconst elisp-ci--known-gnu-mirrors
  '(("ustc" . "https://mirrors.ustc.edu.cn/elpa/gnu/")
    ("tuna" . "https://mirrors.tuna.tsinghua.edu.cn/elpa/gnu/")
    ("bfsu" . "https://mirrors.bfsu.edu.cn/elpa/gnu/"))
  "Known mirror mappings for GNU ELPA.")

(defconst elisp-ci--known-nongnu-mirrors
  '(("ustc" . "https://mirrors.ustc.edu.cn/elpa/nongnu/")
    ("tuna" . "https://mirrors.tuna.tsinghua.edu.cn/elpa/nongnu/")
    ("bfsu" . "https://mirrors.bfsu.edu.cn/elpa/nongnu/"))
  "Known mirror mappings for NonGNU ELPA.")

(defun elisp-ci--getenv-nonempty (name)
  "Return trimmed value of environment variable NAME if non-empty, else nil."
  (let ((val (getenv name)))
    (and val (not (string-empty-p (string-trim val))) (string-trim val))))

(defun elisp-ci--resolve-archive-url (mirror-input known-mirrors default-url)
  "Resolve archive URL from MIRROR-INPUT and KNOWN-MIRRORS.
Fall back to DEFAULT-URL when MIRROR-INPUT is unset or empty."
  (cond
   ((or (null mirror-input) (string-empty-p (string-trim mirror-input)))
    default-url)
   ((assoc (downcase (string-trim mirror-input)) known-mirrors)
    (cdr (assoc (downcase (string-trim mirror-input)) known-mirrors)))
   (t
    (string-trim mirror-input))))

(defun elisp-ci--configure-archives ()
  "Configure package archives and unsigned archives from environment."
  (let* ((archive-env (or (elisp-ci--getenv-nonempty "INPUT_ARCHIVES")
                          (elisp-ci--getenv-nonempty "ELISP_CI_ARCHIVES")
                          (elisp-ci--getenv-nonempty "ELISP_ARCHIVES")))
         (archive-names (or (and archive-env (elisp-ci--parse-list archive-env))
                            '("gnu" "nongnu" "melpa" "elpaish")))
         (unsigned-env (or (elisp-ci--getenv-nonempty "INPUT_UNSIGNED_ARCHIVES")
                           (elisp-ci--getenv-nonempty "ELISP_CI_UNSIGNED_ARCHIVES")))
         (unsigned-names (or (and unsigned-env (elisp-ci--parse-list unsigned-env))
                             '("elpaish")))
         (gnu-mirror (or (elisp-ci--getenv-nonempty "INPUT_GNU_MIRROR")
                         (elisp-ci--getenv-nonempty "ELISP_CI_GNU_MIRROR")
                         (elisp-ci--getenv-nonempty "ELISP_CI_GNU_URL")
                         (elisp-ci--getenv-nonempty "GNU_MIRROR")))
         (nongnu-mirror (or (elisp-ci--getenv-nonempty "INPUT_NONGNU_MIRROR")
                            (elisp-ci--getenv-nonempty "ELISP_CI_NONGNU_MIRROR")
                            (elisp-ci--getenv-nonempty "ELISP_CI_NONGNU_URL")
                            (elisp-ci--getenv-nonempty "NONGNU_MIRROR")))
         (gnu-url (elisp-ci--resolve-archive-url gnu-mirror
                                                 elisp-ci--known-gnu-mirrors
                                                 "https://elpa.gnu.org/packages/"))
         (nongnu-url (elisp-ci--resolve-archive-url nongnu-mirror
                                                   elisp-ci--known-nongnu-mirrors
                                                   "https://elpa.nongnu.org/nongnu/"))
         (standard-map `(("gnu" . ,gnu-url)
                         ("nongnu" . ,nongnu-url)
                         ("melpa" . "https://melpa.org/packages/")
                         ("elpaish" . "https://tychoish.github.io/elpaish/snapshot/"))))
    (setq package-archives
          (delq nil
                (mapcar (lambda (item)
                          (cond
                           ((string-match "\\`\\([^=]+\\)=\\(.+\\)\\'" item)
                            (cons (string-trim (match-string 1 item))
                                  (string-trim (match-string 2 item))))
                           ((assoc item standard-map)
                            (cons item (cdr (assoc item standard-map))))
                           (t
                            (message "Warning: unknown standard archive '%s'" item)
                            nil)))
                        archive-names)))
    (setq package-unsigned-archives unsigned-names)
    (when (or (assoc "elpaish" package-archives)
              (member "elpaish" archive-names))
      (elisp-ci--import-elpaish-keyring))
    (message "Configured package-archives: %S" package-archives)
    (message "Configured package-unsigned-archives: %S" package-unsigned-archives)))

(defun elisp-ci--setup-load-paths ()
  "Add directories in INPUT_LOAD_PATHS to `load-path`."
  (let* ((paths-env (or (getenv "INPUT_LOAD_PATHS")
                        (getenv "ELISP_CI_LOAD_PATHS")
                        (getenv "ELISP_LOAD_PATHS")))
         (paths (or (and paths-env (elisp-ci--parse-list paths-env))
                    '("."))))
    (dolist (p paths)
      (let ((exp (expand-file-name p)))
        (when (file-directory-p exp)
          (add-to-list 'load-path exp)
          (message "Added to load-path: %s" exp))))))

(defun elisp-ci--install-dependencies (&optional extra-deps)
  "Install required dependencies.
Resolved from inputs, env vars, Package-Requires, and EXTRA-DEPS."
  (package-initialize)
  (let* ((dep-strs (elisp-ci--get-dependencies extra-deps))
         (dep-syms (delete-dups (mapcar #'intern dep-strs))))
    (when dep-syms
      (unless package-archive-contents
        (message "Refreshing package archive contents...")
        (package-refresh-contents))
      ;; Pre-install transient archive package if requested or needed by dependencies
      ;; to avoid built-in Emacs 30 transient conflict with cl-generic
      (when (member 'transient dep-syms)
        (let ((desc (cadr (assq 'transient package-archive-contents))))
          (when desc
            (message "Installing archive transient explicitly...")
            (package-install desc))))
      (dolist (dep dep-syms)
        (unless (package-installed-p dep)
          (message "Installing dependency: %s" dep)
          (package-install dep))))))

(defun elisp-ci--find-test-files (&optional pattern-override)
  "Find test files matching pattern in INPUT_TEST_FILES or PATTERN-OVERRIDE."
  (let* ((pattern-input (or pattern-override
                            (getenv "INPUT_TEST_FILES")
                            (getenv "ELISP_CI_TEST_FILES")
                            "test/test-*.el"))
         (patterns (elisp-ci--parse-list pattern-input))
         (matched nil))
    (dolist (pat patterns)
      (let ((files (file-expand-wildcards pat t)))
        (setq matched (append matched files))))
    (delete-dups matched)))

;; Execute standard bootstrapping
(elisp-ci--configure-archives)
(elisp-ci--setup-load-paths)
(unless (string-equal (or (getenv "INPUT_RUNNER")
                          (getenv "ELISP_CI_RUNNER"))
                      "elpaish")
  (elisp-ci--install-dependencies))

(provide 'bootstrap)
;;; bootstrap.el ends here
