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
         (nns-store "/backing") (nns-profile "/nix/profile")
         (nns-profile-generation nil)
         (nns--profile-cache '(("/nix/profile" nil) . "/nix/profile")))
     ,@body))

(ert-deftest nns-arguments-are-not-shell-interpolated ()
  (nns-test--configured
   (let ((command (nns--command '("git" "has spaces" "$(touch /bad)" ""))))
     (should (equal (seq-take command 10)
                    '("/public/nix-enter" "--userns" "--store" "/backing"
                      "--tmpdir" "/tmp/cache" "--profile" "/nix/profile" "--" "/system/bin/sh")))
     (should (equal (last command 4) '("git" "has spaces" "$(touch /bad)" ""))))))

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
                    '("git" nil "git" "status")))
     (cl-letf (((symbol-function 'nns--ns-test)
                (lambda (&rest _) (error "Remote predicates entered the namespace"))))
       (dolist (predicate '(nns--file-executable-p nns--file-exists-p nns--file-regular-p))
         (should (equal (funcall predicate #'identity "/nix/profile/bin/git")
                        "/nix/profile/bin/git")))))
   (let ((nns--inhibit t)) (should-not (nns--wrap-p "git")))
   (should-not (nns--wrap-p nns-launcher))))

(ert-deftest nns-environment-is-process-local ()
  (nns-test--configured
   (let ((before (getenv "PATH")))
     (should (equal (nns--invoke (lambda () (getenv "PATH"))) before))
     (should (equal (getenv "PATH") before))
     (should (equal (nns--invoke (lambda () (getenv "NIX_REMOTE"))) "daemon")))))

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
     (should (nns--file-regular-p (lambda (_) nil) "/nix/profile/bin/nix"))
     (should (nns--file-exists-p (lambda (_) nil) "/nix/profile/bin/nix")))
   (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 1)))
     (should-not (nns--file-executable-p (lambda (_) t) "/nix/missing")))
   (should (nns--file-executable-p (lambda (_) t) "/usr/bin/ls"))
   (let ((nns--inhibit t))
     (should (nns--file-executable-p (lambda (_) t) "/nix/profile/bin/nix")))))

(ert-deftest nns-eshell-path-prepends-profile ()
  (nns-test--configured
   (should (equal (nns--eshell-get-path (lambda (&rest _) '("/data/bin")))
                  '("/data/nix/var/nns/bin" "/nix/profile/bin"
                    "/nix/var/nix/profiles/system-profile/bin" "/data/bin")))
   (let ((path (list "/nix/profile/bin" "/data/bin"
                     "/nix/var/nix/profiles/system-profile/bin" "/data/bin")))
     (should (equal (nns--eshell-get-path (lambda (&rest _) path))
                    '("/data/nix/var/nns/bin" "/nix/profile/bin"
                      "/nix/var/nix/profiles/system-profile/bin" "/data/bin")))
     (should (equal path '("/nix/profile/bin" "/data/bin"
                          "/nix/var/nix/profiles/system-profile/bin" "/data/bin"))))
   (let ((nns-mode nil))
     (should (equal (nns--eshell-get-path (lambda (&rest _) '("/data/bin")))
                    '("/data/bin"))))))

(ert-deftest nns-ghostel-native-spawn-preserves-command-and-environment ()
  (nns-test--configured
   (let ((command '("bash" "-c" "printf '%s' '$value with spaces'")))
     (should (equal (nns--ghostel-spawn-via-native #'identity command)
                    (nns--command command)))
     (let ((default-directory "/ssh:example:/tmp/"))
       (should (eq (nns--ghostel-spawn-via-native #'identity command) command)))
     (let ((nns-mode nil))
       (should (eq (nns--ghostel-spawn-via-native #'identity command) command)))
     (let ((nns--inhibit t))
       (should (eq (nns--ghostel-spawn-via-native #'identity command) command))))))

(ert-deftest nns-profile-selection-resolves-once-in-originating-buffer ()
  (nns-test--configured
   (let ((nns-profile "development") (nns-profile-generation 3)
         (nns--profile-cache nil) (calls 0))
     (cl-letf (((symbol-function 'call-process)
                (lambda (&rest args)
                  (setq calls (1+ calls))
                  (should (member "development" args))
                  (should (member "--generation" args))
                  (should (member "3" args))
                  (insert "/nix/store/retained-development") 0)))
       (should (equal (nns--resolved-profile) "/nix/store/retained-development"))
       (should (equal (nns--resolved-profile) "/nix/store/retained-development"))
       (should (= calls 1))))))

(ert-deftest nns-profile-errors-do-not-fall-back ()
  (nns-test--configured
   (let ((nns-profile "missing") (nns--profile-cache nil))
     (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (insert "missing profile") 1)))
       (should-error (nns--resolved-profile) :type 'user-error)))
   (let ((nns-profile "../development"))
     (should-error (nns--resolved-profile) :type 'user-error))
   (let ((nns-profile-generation 0))
     (should-error (nns--resolved-profile) :type 'user-error))
   (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 1)))
     (should-not (nns--executable-find (lambda (&rest _) "/host/git") "git")))))

(ert-deftest nns-temporary-output-buffer-does-not-change-selection ()
  (nns-test--configured
   (let ((nns-profile "project")
         (nns--profile-cache '(("project" nil) . "/nix/store/project")))
     (cl-letf (((symbol-function 'call-process)
                (lambda (&rest args)
                  (should (member "/nix/store/project" args))
                  (insert "/nix/store/project/bin/git") 0)))
       (should (equal (nns--executable-find #'ignore "git") "/nix/store/project/bin/git"))))))

(ert-deftest nns-probe-fails-closed ()
  (nns-test--configured
   (cl-letf (((symbol-function 'call-process)
              (lambda (&rest _) (insert "unshare user namespace: errno 1") 1)))
     (should-error (nns-check) :type 'user-error))))

(ert-deftest nns-shell-retains-selection-in-its-output-buffer ()
  (require 'comint)
  (nns-test--configured
   (let (buffers)
     (unwind-protect
         (cl-letf (((symbol-function 'nns-check) (lambda () "OK"))
                   ((symbol-function 'comint-check-proc) (lambda (_) nil))
                   ((symbol-function 'make-comint-in-buffer)
                    (lambda (_ buffer &rest _)
                      (push buffer buffers)
                      (with-current-buffer buffer (comint-mode))))
                   ((symbol-function 'pop-to-buffer) #'identity))
           (nns-shell)
           (with-current-buffer (car buffers)
             (should (equal nns-profile "/nix/profile"))
             (should (equal (cdr nns--profile-cache) "/nix/profile")))
           (setq nns-profile "/nix/second"
                 nns--profile-cache '(("/nix/second" nil) . "/nix/second"))
           (nns-shell)
           (should-not (eq (car buffers) (cadr buffers))))
       (mapc #'kill-buffer buffers)))))

(ert-deftest nns-mode-can-be-disabled-cleanly ()
  (cl-letf (((symbol-function 'nns-check) (lambda () "OK")))
    (let ((fixture (make-temp-file
                    "nns-ghostel-" nil ".el"
                    ";;; -*- lexical-binding: t; -*-\n(defun ghostel--spawn-via-native (command) command)\n(provide 'ghostel)\n")))
      (unwind-protect
          (progn
            (nns-mode 1)
            (load fixture nil t)
            (should (advice-member-p #'nns--make-process 'make-process))
            (should (advice-member-p #'nns--ghostel-spawn-via-native 'ghostel--spawn-via-native))
            (nns-mode -1)
            (should-not (advice-member-p #'nns--make-process 'make-process))
            (should-not (advice-member-p #'nns--ghostel-spawn-via-native 'ghostel--spawn-via-native)))
        (nns-mode -1)
        (when (featurep 'ghostel) (unload-feature 'ghostel t))
        (delete-file fixture)))))
