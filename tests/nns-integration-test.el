;;; nns-integration-test.el --- Real Emacs-to-userns tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'nns)
(setq nns-launcher (getenv "NNS_TEST_HELPER")
      nns-store (getenv "NNS_TEST_STORE")
      nns-system-shell "/bin/sh"
      temporary-file-directory (file-name-as-directory (getenv "NNS_TEST_TMP")))
(setq-default nns-profile "/nix/store/nns-emacs-base")
(nns-mode 1)

(ert-deftest nns-real-synchronous-process ()
  (should (file-exists-p "/nix/store/nns-emacs-base/bin/nns-test-program"))
  (should (equal (executable-find "nns-test-program") "/nix/store/nns-emacs-base/bin/nns-test-program"))
  (with-temp-buffer
    (should (zerop (call-process "nns-test-program" nil t nil "with spaces")))
    (should (equal (buffer-string) "canonical-store|with spaces\n"))))

(ert-deftest nns-real-named-generations-retain-home-and-environment ()
  (let ((home (getenv "HOME")))
    (dolist (entry '((1 . "first") (2 . "second")))
      (with-temp-buffer
        (setq-local nns-profile "development"
                    nns-profile-generation (car entry))
        (should (equal (nns--resolved-profile) (concat "/nix/store/nns-emacs-" (cdr entry))))
        (should (zerop (call-process "nns-profile-program" nil t nil)))
        (should (equal (buffer-string) (concat (cdr entry) "|" home "\n")))))))

(ert-deftest nns-real-buffer-selection-pins-target ()
  (with-temp-buffer
    (setq-local nns-profile "development")
    (should (equal (nns--resolved-profile) "/nix/store/nns-emacs-first"))
    (let ((pointer (concat (getenv "NNS_TEST_STORE") "/var/nix/profiles/development")))
      (unwind-protect
          (progn
            (make-symbolic-link "development-2-link" pointer t)
            (should (equal (nns--resolved-profile) "/nix/store/nns-emacs-first"))
            (should (zerop (call-process "nns-profile-program" nil t nil)))
            (should (string-prefix-p "first|" (buffer-string))))
        (make-symbolic-link "development-1-link" pointer t)))))

(ert-deftest nns-real-asynchronous-process ()
  (with-temp-buffer
    (let ((process (make-process :name "nns-integration" :buffer (current-buffer)
                                 :command '("nns-test-program" "async")
                                 :connection-type 'pipe :noquery t :sentinel #'ignore))
          (deadline (+ (float-time) 20)))
      (while (and (process-live-p process) (< (float-time) deadline))
        (accept-process-output process 0.1))
      (should-not (process-live-p process))
      (should (zerop (process-exit-status process)))
      (should (equal (buffer-string) "canonical-store|async\n")))))

(ert-deftest nns-real-eshell-infrastructure-command ()
  (require 'eshell)
  (require 'esh-mode)
  (let ((eshell-directory-name (expand-file-name "eshell" (getenv "NNS_TEST_TMP"))))
    (with-temp-buffer
      (eshell-mode)
      (setq-local nns-profile "development" nns-profile-generation 2)
      (should (equal (seq-take (eshell-get-path) 3)
                     '("/data/nix/var/nns/bin" "/nix/store/nns-emacs-second/bin"
                       "/nix/var/nix/profiles/system-profile/bin")))
      (should (equal (eshell-search-path "id")
                     "/nix/var/nix/profiles/system-profile/bin/id"))
      (goto-char (point-max))
      (insert "id -u")
      (eshell-send-input)
      (let ((deadline (+ (float-time) 20)))
        (while (and eshell-process-list (< (float-time) deadline))
          (accept-process-output nil 0.1)))
      (should (zerop eshell-last-command-status))
      (should (string-match-p (format "\n%d\n" (user-uid)) (buffer-string))))))

(ert-deftest nns-real-ghostel-native-process ()
  (with-temp-buffer
    (setq-local nns-profile "development" nns-profile-generation 2)
    ;; Stand in for the module's fork/exec primitive, not its namespace setup.
    (let ((process
           (nns--ghostel-spawn-via-native
            (lambda (command)
              (should nns--inhibit)
              (make-process :name "nns-native-spawn" :buffer (current-buffer)
                            :command command :connection-type 'pipe
                            :noquery t :sentinel #'ignore))
            '("nns-profile-program")))
          (deadline (+ (float-time) 20)))
      (while (and (process-live-p process) (< (float-time) deadline))
        (accept-process-output process 0.1))
      (should-not (process-live-p process))
      (should (zerop (process-exit-status process)))
      (should (equal (buffer-string) (concat "second|" (getenv "HOME") "\n"))))))

(ert-deftest nns-real-start-process ()
  (with-temp-buffer
    (let ((process (start-process "nns-start" (current-buffer) "nns-test-program" "start"))
          (deadline (+ (float-time) 20)))
      (set-process-sentinel process #'ignore)
      (while (and (process-live-p process) (< (float-time) deadline))
        (accept-process-output process 0.1))
      (should-not (process-live-p process))
      (should (zerop (process-exit-status process)))
      (should (equal (buffer-string) "canonical-store|start\n")))))
