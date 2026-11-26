;;; test-fixture-pkg.el --- Tests for fixture package -*- lexical-binding: t; -*-

(require 'ert)
(require 'fixture-pkg)

(ert-deftest fixture-pkg/greet ()
  "Test greeting function."
  (should (equal (fixture-pkg-greet "World") "Hello, World!")))

(ert-deftest fixture-pkg/add ()
  "Test add function."
  (should (= (fixture-pkg-add 20 22) 42)))

(ert-deftest fixture-pkg/skipped-test ()
  "Ensure coverage runs tolerate ERT skips."
  (ert-skip "Exercise skipped tests in the coverage runner"))

(ert-deftest fixture-pkg/zz-after-skip ()
  "Ensure the coverage runner continues after a skipped test."
  (should (equal (fixture-pkg-greet "after") "Hello, after!")))

(provide 'test-fixture-pkg)
;;; test-fixture-pkg.el ends here
