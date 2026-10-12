;;; test-action-scripts.el --- Tests for action scripts -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'bootstrap)

(ert-deftest action-scripts/parse-list-plain ()
  "Test plain space and comma separated lists."
  (should (equal (elisp-ci--parse-list "foo bar,baz qux") '("foo" "bar" "baz" "qux")))
  (should (null (elisp-ci--parse-list "")))
  (should (null (elisp-ci--parse-list nil))))

(ert-deftest action-scripts/parse-list-yaml-bullets ()
  "Test multiline YAML lists with bullet syntax (- and *)."
  (let ((yaml-input "- compat\n- transient\n- llama")
        (indented-yaml "  - compat\n  - transient\n  - llama")
        (star-input "* compat\n* transient\n* llama")
        (commented-yaml "- compat # elpa pkg\n- transient # needed"))
    (should (equal (elisp-ci--parse-list yaml-input) '("compat" "transient" "llama")))
    (should (equal (elisp-ci--parse-list indented-yaml) '("compat" "transient" "llama")))
    (should (equal (elisp-ci--parse-list star-input) '("compat" "transient" "llama")))
    (should (equal (elisp-ci--parse-list commented-yaml) '("compat" "transient")))))

(ert-deftest action-scripts/parse-list-yaml-array-and-quotes ()
  "Test YAML/JSON bracket arrays and quoted items."
  (let ((bracket-input "[\"compat\", \"transient\"]")
        (unquoted-bracket "[compat, transient]")
        (quoted-yaml "- 'compat'\n- \"transient\""))
    (should (equal (elisp-ci--parse-list bracket-input) '("compat" "transient")))
    (should (equal (elisp-ci--parse-list unquoted-bracket) '("compat" "transient")))
    (should (equal (elisp-ci--parse-list quoted-yaml) '("compat" "transient")))))

(ert-deftest action-scripts/parse-list-elisp-lists-and-structures ()
  "Test Elisp lists of strings, symbols, and sequences."
  (should (equal (elisp-ci--parse-list '("compat" "transient")) '("compat" "transient")))
  (should (equal (elisp-ci--parse-list '("compat transient" "llama")) '("compat" "transient" "llama")))
  (should (equal (elisp-ci--parse-list '(compat transient)) '("compat" "transient")))
  (should (equal (elisp-ci--parse-list '["compat" "transient"]) '("compat" "transient")))
  (should (equal (elisp-ci--parse-list '("- compat" "- transient")) '("compat" "transient"))))

(ert-deftest action-scripts/discover-package-requires ()
  "Test automatic discovery of dependencies from Package-Requires header."
  (let ((deps (elisp-ci--discover-package-requires)))
    ;; In this repository, fixture-pkg.el or others might have headers
    (message "Discovered root deps: %S" deps)
    (should (listp deps))))

(ert-deftest action-scripts/get-dependencies-env-override ()
  "Test overriding dependencies via ELISP_CI_DEPENDENCIES environment variable."
  (let ((process-environment (cons "ELISP_CI_DEPENDENCIES=transient llama" process-environment)))
    (should (equal (elisp-ci--get-dependencies) '("transient" "llama")))))

(ert-deftest action-scripts/resolve-archive-url-shortcuts ()
  "Test resolving archive mirror shortcuts and arbitrary URLs."
  (should (equal (elisp-ci--resolve-archive-url "ustc" elisp-ci--known-gnu-mirrors
                                                elisp-ci--default-gnu-mirror-url
                                                elisp-ci--upstream-gnu-url)
                 "https://mirrors.ustc.edu.cn/elpa/gnu/"))
  (should (equal (elisp-ci--resolve-archive-url "TUNA" elisp-ci--known-gnu-mirrors
                                                elisp-ci--default-gnu-mirror-url
                                                elisp-ci--upstream-gnu-url)
                 "https://mirrors.tuna.tsinghua.edu.cn/elpa/gnu/"))
  (should (equal (elisp-ci--resolve-archive-url "https://custom.org/elpa/" elisp-ci--known-gnu-mirrors
                                                elisp-ci--default-gnu-mirror-url
                                                elisp-ci--upstream-gnu-url)
                 "https://custom.org/elpa/"))
  ;; Default fallback mirror resolution when unset or empty
  (should (equal (elisp-ci--resolve-archive-url "" elisp-ci--known-gnu-mirrors
                                                elisp-ci--default-gnu-mirror-url
                                                elisp-ci--upstream-gnu-url)
                 "https://mirrors.ustc.edu.cn/elpa/gnu/"))
  (should (equal (elisp-ci--resolve-archive-url nil elisp-ci--known-gnu-mirrors
                                                elisp-ci--default-gnu-mirror-url
                                                elisp-ci--upstream-gnu-url)
                 "https://mirrors.ustc.edu.cn/elpa/gnu/"))
  ;; Explicit opt-outs via keyword
  (should (equal (elisp-ci--resolve-archive-url "upstream" elisp-ci--known-gnu-mirrors
                                                elisp-ci--default-gnu-mirror-url
                                                elisp-ci--upstream-gnu-url)
                 "https://elpa.gnu.org/packages/"))
  (should (equal (elisp-ci--resolve-archive-url "none" elisp-ci--known-gnu-mirrors
                                                elisp-ci--default-gnu-mirror-url
                                                elisp-ci--upstream-gnu-url)
                 "https://elpa.gnu.org/packages/"))
  ;; Global opt-out via INPUT_FALLBACK_MIRRORS=false
  (let ((process-environment (cons "INPUT_FALLBACK_MIRRORS=false" process-environment)))
    (should (equal (elisp-ci--resolve-archive-url nil elisp-ci--known-gnu-mirrors
                                                  elisp-ci--default-gnu-mirror-url
                                                  elisp-ci--upstream-gnu-url)
                   "https://elpa.gnu.org/packages/"))))

(ert-deftest action-scripts/configure-archives-gnu-mirror-env ()
  "Test setting GNU ELPA mirror via environment variable."
  (let ((process-environment (cons "INPUT_GNU_MIRROR=ustc" process-environment)))
    (elisp-ci--configure-archives)
    (should (equal (cdr (assoc "gnu" package-archives)) "https://mirrors.ustc.edu.cn/elpa/gnu/"))))

(ert-deftest action-scripts/configure-archives-custom-key-value ()
  "Test name=url syntax in archives list."
  (let ((process-environment (cons "INPUT_ARCHIVES=gnu=https://mirror.example.com/gnu/ melpa" process-environment)))
    (elisp-ci--configure-archives)
    (should (equal (cdr (assoc "gnu" package-archives)) "https://mirror.example.com/gnu/"))
    (should (equal (cdr (assoc "melpa" package-archives)) "https://melpa.org/packages/"))
    (should (null (assoc "nongnu" package-archives)))))

(ert-deftest action-scripts/configure-archives-empty-input-falls-back-to-job-env ()
  "Test that empty INPUT_GNU_MIRROR falls back to ELISP_CI_GNU_MIRROR."
  (let ((process-environment (cons "INPUT_GNU_MIRROR="
                                   (cons "ELISP_CI_GNU_MIRROR=ustc" process-environment))))
    (elisp-ci--configure-archives)
    (should (equal (cdr (assoc "gnu" package-archives)) "https://mirrors.ustc.edu.cn/elpa/gnu/"))))

(ert-deftest action-scripts/setup-package-dir-env ()
  "Test configuring package-user-dir via environment variables."
  (let* ((orig-dir package-user-dir)
         (temp-cache (make-temp-file "elisp-cache-test" t))
         (process-environment (cons (format "INPUT_CACHE_DIR=%s" temp-cache) process-environment)))
    (unwind-protect
        (progn
          (elisp-ci--setup-package-dir)
          (should (equal package-user-dir (expand-file-name temp-cache))))
      (setq package-user-dir orig-dir)
      (delete-directory temp-cache t))))

(ert-deftest action-scripts/import-elpaish-keyring-cached ()
  "Test importing cached ELPAish GPG keyring without downloading."
  (let* ((orig-dir package-user-dir)
         (temp-cache (make-temp-file "elpaish-cache-test" t))
         (cached-keyring (expand-file-name "elpaish-keyring.gpg" temp-cache))
         (called-url-copy nil)
         (called-import-keyring nil))
    (unwind-protect
        (progn
          (setq package-user-dir temp-cache)
          ;; Create a dummy non-empty keyring file without triggering epa-file
          (let ((file-name-handler-alist nil))
            (with-temp-file cached-keyring
              (insert "dummy-gpg-data")))
          (cl-letf (((symbol-function 'url-copy-file)
                     (lambda (&rest _args) (setq called-url-copy t)))
                    ((symbol-function 'package-import-keyring)
                     (lambda (_f) (setq called-import-keyring t))))
            (elisp-ci--import-elpaish-keyring)
            (should (null called-url-copy))
            (should called-import-keyring)))
      (setq package-user-dir orig-dir)
      (delete-directory temp-cache t))))


(ert-deftest action-scripts/eval-inline-and-file ()
  "Test batch evaluation runner for both inline expressions and file loading."
  (let* ((tmp-dir (make-temp-file "elisp-ci-eval-test-" t))
         (script-file (expand-file-name "fixture-script.el" tmp-dir))
         (test-file-dir (file-name-directory (locate-library "test-action-scripts")))
         (run-eval-path (expand-file-name "../scripts/run-eval.el" test-file-dir)))
    (with-temp-file script-file
      (insert ";;; -*- lexical-binding: t; -*-\n(setq elisp-ci--test-file-loaded 100)\n"))
    (unwind-protect
        (let* ((process-environment
                (append (list (concat "INPUT_ACTION_PATH=" tmp-dir)
                              "INPUT_FILE=fixture-script.el"
                              "INPUT_EVAL=(setq elisp-ci--test-eval-result (+ elisp-ci--test-file-loaded 42))")
                        process-environment)))
          (load run-eval-path nil t)
          (should (equal elisp-ci--test-file-loaded 100))
          (should (equal elisp-ci--test-eval-result 142)))
      (delete-directory tmp-dir t))))

(ert-deftest action-scripts/eval-action-path-resolution ()
  "Test container path remapping and default directory fallback in elisp-ci-action-path."
  (let* ((test-file-dir (file-name-directory (locate-library "test-action-scripts")))
         (run-eval-path (expand-file-name "../scripts/run-eval.el" test-file-dir)))
    (require (quote run-eval) run-eval-path)
    (let ((process-environment (cons "INPUT_ACTION_PATH=/tmp" process-environment)))
      (should (equal (elisp-ci-action-path) (expand-file-name "/tmp"))))
    (let ((process-environment (cons "INPUT_ACTION_PATH=" process-environment)))
      (should (equal (elisp-ci-action-path) (expand-file-name default-directory))))))

(provide 'test-action-scripts)
;;; test-action-scripts.el ends here
