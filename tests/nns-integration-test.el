;;; nns-integration-test.el --- Real Emacs-to-userns tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'nns)
(setq nns-launcher (getenv "NNS_TEST_HELPER")
      nns-store (getenv "NNS_TEST_STORE")
      nns-profile "/nix"
      nns-system-shell "/bin/sh"
      temporary-file-directory (file-name-as-directory (getenv "NNS_TEST_TMP")))
(nns-mode 1)

(ert-deftest nns-real-synchronous-process ()
  (should-not (file-exists-p "/nix/bin/nns-test-program"))
  (should (equal (executable-find "nns-test-program") "/nix/bin/nns-test-program"))
  (with-temp-buffer
    (should (zerop (call-process "nns-test-program" nil t nil "with spaces")))
    (should (equal (buffer-string) "canonical-store|with spaces\n"))))

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
