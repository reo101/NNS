;;; nns-android-probe.el --- Explicit -Q --batch device probe -*- lexical-binding: t; -*-
;; Copy beside nns.el into a temporary, app-owned cache directory.
;; Invoke with org.gnu.emacs.STARTUP_ARGUMENTS, never append to user init files.
(let* ((directory (file-name-directory load-file-name))
       (report (expand-file-name "report.txt" directory))
       (temporary-file-directory directory))
  (load (expand-file-name "nns.el" directory) nil t)
  ;; The kernel seccomp-disable hook matches the exact published entrypoint
  ;; path, so the probe must exec it rather than a scratch copy.
  (setq nns-launcher "/data/nix/bin/nix-enter")
  (with-temp-buffer
    (insert (format "Emacs: %s\nUID: %s\n" emacs-version (user-uid)))
    (insert-file-contents "/proc/self/attr/current")
    (goto-char (point-max))
    (insert "\n")
    (condition-case err
        (progn
          (insert (nns-check))
          (nns-mode 1)
          (let ((status (call-process "/nix/var/nix/profiles/profile/bin/nix" nil t nil "--version")))
            (insert (format "\nNix exit: %S\n" status)))
          (nns-mode -1))
      (error (insert (format "FAILED: %S\n" err))))
    (write-region (point-min) (point-max) report nil 'silent)))
(kill-emacs 0)
