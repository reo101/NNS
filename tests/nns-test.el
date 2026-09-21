;;; nns-test.el --- Namespace integration tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'nns)
;; The Android C variable must stay dynamically bound here; a valueless
;; declaration is enough for the reader, and the let below needs it to be
;; special rather than a lexical slot.
(defvar android-use-exec-loader t)

(defmacro nns-test--configured (&rest body)
  `(let ((nns-mode t) (nns--inhibit nil)
         (default-directory "/tmp/")
         (temporary-file-directory "/tmp/cache/")
         (nns-launcher "/public/nix-enter")
         (nns-store "/backing") (nns-profile "/nix/profile"))
     ,@body))

(ert-deftest nns-arguments-are-not-shell-interpolated ()
  (nns-test--configured
   (should (equal (nns--command '("git" "has spaces" "$(touch /bad)" ""))
                  '("/public/nix-enter" "--userns" "--store" "/backing"
                    "--tmpdir" "/tmp/cache" "--" "git" "has spaces" "$(touch /bad)" "")))))

(ert-deftest nns-call-process-keeps-io-arguments ()
  (nns-test--configured
   (let ((result (nns--call-process #'list "git" "input" 'destination t "status")))
     (should (equal (seq-take result 4) '("/public/nix-enter" "input" destination t)))
     (should (equal (seq-drop result 4) (cdr (nns--command '("git" "status"))))))))

(ert-deftest nns-call-process-region-keeps-region-and-delete ()
  (nns-test--configured
   (let ((result (nns--call-process-region #'list 1 5 "sort" t 'destination nil "-r")))
     (should (equal (seq-take result 6) '(1 5 "/public/nix-enter" t destination nil)))
     (should (equal (seq-drop result 6) (cdr (nns--command '("sort" "-r"))))))))

(ert-deftest nns-async-process-arguments ()
  (nns-test--configured
   (should (equal (nns--start-process #'list "git" 'buffer "git" "status")
                  (append '("git" buffer) (nns--command '("git" "status")))))
   (let* ((options '(:name "server" :command ("lsp" "arg") :connection-type pipe :stderr errors))
          (copy (copy-tree options))
          (result (apply #'nns--make-process #'list options)))
     (should (equal (plist-get result :command) (nns--command '("lsp" "arg"))))
     (should (eq (plist-get result :connection-type) 'pipe))
     (should (eq (plist-get result :stderr) 'errors))
     (should (equal options copy)))))

(ert-deftest nns-skips-remote-and-recursive-wrapping ()
  (nns-test--configured
   (let ((default-directory "/ssh:example:/tmp/"))
     (should (equal (nns--start-process #'list "git" nil "git" "status")
                    '("git" nil "git" "status"))))
   (let ((nns--inhibit t)) (should-not (nns--wrap-p "git")))
   (should-not (nns--wrap-p nns-launcher))))

(ert-deftest nns-environment-is-process-local ()
  (nns-test--configured
   (let ((before (getenv "PATH")))
     (should (equal (nns--invoke (lambda () (getenv "PATH")))
                    (concat "/nix/profile/bin:" before)))
     (should (equal (getenv "PATH") before)))))

(ert-deftest nns-uses-real-exec-only-for-its-children ()
  (let ((android-use-exec-loader t))
    (should-not (nns--invoke (lambda () android-use-exec-loader)))
    (should android-use-exec-loader)))

(ert-deftest nns-executable-find-uses-namespace ()
  (nns-test--configured
   (cl-letf (((symbol-function 'call-process)
              (lambda (&rest args)
                (should (equal (car args) nns-launcher))
                (insert "/nix/profile/bin/git") 0)))
     (should (equal (nns--executable-find (lambda (&rest _) nil) "git")
                    "/nix/profile/bin/git")))))

(ert-deftest nns-file-predicates-ask-namespace-for-nix ()
  (nns-test--configured
   (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 0)))
     (should (nns--file-executable-p (lambda (_) nil) "/nix/profile/bin/nix"))
     (should (nns--file-regular-p (lambda (_) nil) "/nix/profile/bin/nix")))
   (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 1)))
     (should-not (nns--file-executable-p (lambda (_) t) "/nix/missing")))
   (should (nns--file-executable-p (lambda (_) t) "/usr/bin/ls"))
   (let ((nns--inhibit t))
     (should (nns--file-executable-p (lambda (_) t) "/nix/profile/bin/nix")))))

(ert-deftest nns-eshell-path-prepends-profile ()
  (nns-test--configured
   (should (equal (nns--eshell-get-path (lambda (&rest _) '("/data/bin")))
                  '("/nix/profile/bin" "/data/bin")))
   (should (equal (nns--eshell-get-path (lambda (&rest _) '("/nix/profile/bin")))
                  '("/nix/profile/bin")))
   (let ((nns-mode nil))
     (should (equal (nns--eshell-get-path (lambda (&rest _) '("/data/bin")))
                    '("/data/bin"))))))

(ert-deftest nns-probe-fails-closed ()
  (nns-test--configured
   (cl-letf (((symbol-function 'call-process)
              (lambda (&rest _) (insert "unshare user namespace: errno 1") 1)))
     (should-error (nns-check) :type 'user-error))))

(ert-deftest nns-mode-can-be-disabled-cleanly ()
  (cl-letf (((symbol-function 'nns-check) (lambda () "OK")))
    (unwind-protect
        (progn
          (nns-mode 1)
          (should (advice-member-p #'nns--make-process 'make-process))
          (nns-mode -1)
          (should-not (advice-member-p #'nns--make-process 'make-process)))
      (nns-mode -1))))
