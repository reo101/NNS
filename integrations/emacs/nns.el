;;; nns.el --- Run local subprocesses in a native Nix namespace -*- lexical-binding: t; -*-
;; Version: 3.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: processes, tools
;;
;;; Commentary:
;; `nns-mode' wraps local subprocess creation with the non-setuid NNS launcher.
;; Git, language servers and shells see canonical /nix; the GUI Emacs process
;; itself does not.  This is not a file-name handler, proot, or a root daemon.
;; Android app SELinux/seccomp must permit the launcher's namespace operations.
;;; Code:

(defgroup nns nil "Native Nix subprocess namespaces." :group 'processes)
(defcustom nns-launcher "/data/nix/bin/nix-enter"
  "Absolute path of the public, non-setuid namespace launcher."
  :type 'file :group 'nns)
(defcustom nns-store "/data/nix"
  "Physical backing directory for canonical /nix."
  :type 'directory :group 'nns)
(defcustom nns-profile "/nix/var/nix/profiles/default"
  "Profile whose bin directory is searched inside the namespace.
The default bootstrap profile provides nix, git and bash for every
hosting app; point this at another profile for a richer PATH."
  :type 'directory :group 'nns)
(defcustom nns-system-shell "/system/bin/sh"
  "Existing Android shell used for namespace diagnostics and shell sessions."
  :type 'file :group 'nns)
(defvar nns--inhibit nil)
(defvar nns-mode nil)
(defvar android-use-exec-loader)

(defun nns--command (command)
  "Prefix COMMAND without interpreting or concatenating its arguments."
  (append (list nns-launcher "--userns" "--store" nns-store
                "--tmpdir" (directory-file-name temporary-file-directory) "--")
          command))

(defun nns--wrap-p (program)
  (and nns-mode (not nns--inhibit) program
       (not (equal program nns-launcher))
       (not (file-remote-p default-directory))))

(defun nns--invoke (function &rest args)
  "Call FUNCTION with ARGS and a process-local Nix environment."
  (let ((nns--inhibit t)
        ;; Android's emulated exec bypasses SELinux entrypoint transitions and
        ;; traces descendants from outside their new mount namespace.
        (android-use-exec-loader nil)
        (process-environment (copy-sequence process-environment)))
    (setenv "PATH" (concat (directory-file-name nns-profile) "/bin:"
                          (or (getenv "PATH") "/system/bin")))
    (setenv "NIX_CONF_DIR" (concat (directory-file-name nns-store) "/etc/nix"))
    ;; The store is root-owned; every single-user nix command locks the
    ;; DB, so sessions talk to the root daemon instead of the DB directly.
    (setenv "NIX_REMOTE" "daemon")
    (apply function args)))

(defun nns--call-process (function program &optional infile destination display &rest args)
  (if (nns--wrap-p program)
      (apply #'nns--invoke function nns-launcher infile destination display
             (cdr (nns--command (cons program args))))
    (apply function program infile destination display args)))

(defun nns--call-process-region (function start end program &optional delete destination display &rest args)
  (if (nns--wrap-p program)
      (apply #'nns--invoke function start end nns-launcher delete destination display
             (cdr (nns--command (cons program args))))
    (apply function start end program delete destination display args)))

(defun nns--start-process (function name buffer program &rest args)
  (if (nns--wrap-p program)
      (apply #'nns--invoke function name buffer (nns--command (cons program args)))
    (apply function name buffer program args)))

(defun nns--make-process (function &rest args)
  (let ((command (plist-get args :command)))
    (if (nns--wrap-p (car command))
        (apply #'nns--invoke function
               (plist-put (copy-sequence args) :command (nns--command command)))
      (apply function args))))

(defun nns--executable-find (function command &optional remote)
  ;; Native Emacs cannot stat /nix itself. Ask a child in the namespace instead.
  (if (not (nns--wrap-p command))
      (funcall function command remote)
    (with-temp-buffer
      (let ((status
             (apply #'nns--invoke #'call-process nns-launcher nil (current-buffer) nil
                    (cdr (nns--command
                          (list nns-system-shell "-c"
                                "p=$(command -v \"$1\") && test -f \"$p\" && test -x \"$p\" && printf '%s' \"$p\""
                                "nns-executable-find" command))))))
        (if (and (integerp status) (zerop status))
            (buffer-string)
          (funcall function command remote))))))

(defun nns--nix-file-p (file)
  (and nns-mode (not nns--inhibit)
       (stringp file) (string-prefix-p "/nix/" file)))

(defun nns--ns-test (file test)
  "Return non-nil when TEST passes for FILE inside the namespace."
  (let ((status (apply #'nns--invoke #'call-process nns-launcher nil nil nil
                       (cdr (nns--command
                             (list nns-system-shell "-c"
                                   (concat test " \"$1\"")
                                   "nns-file-test" file))))))
    (and (integerp status) (zerop status))))

(defun nns--file-executable-p (function file)
  ;; Eshell resolves external commands with a native stat, which cannot
  ;; see /nix; ask a namespace child instead of returning nil.
  (if (nns--nix-file-p file)
      (nns--ns-test file "test -x")
    (funcall function file)))

(defun nns--file-regular-p (function file)
  (if (nns--nix-file-p file)
      (nns--ns-test file "test -f")
    (funcall function file)))

(defun nns--eshell-get-path (function &optional literal-p)
  ;; Eshell's $PATH derives from `exec-path', which never contains the
  ;; namespace's profile; prepend it so eshell resolves like the child env.
  (let ((path (funcall function literal-p)))
    (if (not (and nns-mode (not nns--inhibit)
                  (not (file-remote-p default-directory))
                  path))
        path
      (let ((bin (directory-file-name (file-name-concat nns-profile "bin"))))
        (cons bin (remove bin path))))))

(defun nns--eshell-advice (enable)
  (with-eval-after-load 'esh-util
    (if enable
        (advice-add 'eshell-get-path :around #'nns--eshell-get-path)
      (advice-remove 'eshell-get-path #'nns--eshell-get-path))))

;;;###autoload
(defun nns-check ()
  "Test namespace setup from this Emacs process's actual Android domain.
No root fallback is attempted.  Return diagnostic output on success."
  (interactive)
  (when (file-remote-p default-directory)
    (user-error "Run nns-check from a local buffer"))
  (with-temp-buffer
    (let* ((status (apply #'nns--invoke #'call-process nns-launcher nil (current-buffer) nil
                          (cdr (nns--command
                                (list nns-system-shell "-c"
                                      "set -e; id; test -d /nix/store; test \"$(id -u)\" = \"$1\"; echo NNS-USERNS-OK"
                                      "nns-check" (number-to-string (user-uid)))))))
           (output (buffer-string)))
      (unless (and (integerp status) (zerop status))
        (user-error "NNS namespace setup failed (%s): %s" status output))
      (when (called-interactively-p 'interactive) (message "%s" output))
      output)))

;;;###autoload
(define-minor-mode nns-mode
  "Run local subprocesses with canonical /nix, retaining the app's UID.
Does not relocate the existing Emacs/ART process or make /nix global.
Remote/TRAMP processes are left alone.  Disable to run outside NNS."
  :global t :group 'nns
  (when nns-mode
    (condition-case err
        (nns-check)
      (error (setq nns-mode nil) (signal (car err) (cdr err)))))
  (dolist (pair '((call-process . nns--call-process)
                  (call-process-region . nns--call-process-region)
                  (start-process . nns--start-process)
                  (make-process . nns--make-process)
                  (executable-find . nns--executable-find)
                  (file-executable-p . nns--file-executable-p)
                  (file-regular-p . nns--file-regular-p)))
    (if nns-mode
        (advice-add (car pair) :around (cdr pair))
      (advice-remove (car pair) (cdr pair))))
  (nns--eshell-advice nns-mode))

;;;###autoload
(defun nns-shell ()
  "Open an app-UID shell with canonical /nix, without enabling global advice."
  (interactive)
  (nns-check)
  (require 'comint)
  (let ((buffer (get-buffer-create "*NNS*")))
    (unless (comint-check-proc buffer)
      (apply #'nns--invoke #'make-comint-in-buffer "NNS" buffer nns-launcher nil
             (cdr (nns--command
                   (list nns-system-shell "-c"
                         ;; Non-interactive Android mksh: interactive mode
                         ;; needs a pty the namespace child does not have,
                         ;; and hangs after echoing commands. comint itself
                         ;; provides the prompt/history layer.
                         "exec /nix/var/nix/profiles/profile/bin/bash -i")))))
    (pop-to-buffer buffer)))

(provide 'nns)
;;; nns.el ends here
