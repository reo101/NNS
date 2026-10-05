;;; nns.el --- Run local subprocesses in a native Nix namespace -*- lexical-binding: t; -*-
;; Version: 3.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: processes, tools
;;
;;; Commentary:
;; Local subprocesses retain the hosting app's UID and HOME.  A selected
;; package profile supplies tools, not another app's login or activation.
;; Profile names and generations resolve inside the namespace.  Each buffer
;; keeps its resolved target until the selection is reset.
;;; Code:

(require 'subr-x)
(declare-function comint-check-proc "comint" (buffer))

(defgroup nns nil "Native Nix subprocess namespaces." :group 'processes)
(defcustom nns-launcher "/data/nix/bin/nix-enter"
  "Absolute path of the public, non-setuid namespace launcher."
  :type 'file :group 'nns)
(defcustom nns-store "/data/nix"
  "Physical backing directory for canonical /nix."
  :type 'directory :group 'nns)
(defcustom nns-profile "development"
  "Published profile name or absolute profile path inside the namespace.
This changes subprocess tools, not UID, HOME or services.  Directory-local
configuration can select a profile for a project.  Published generations
must remain retained by the administrative NNS configuration."
  :type 'string :group 'nns)
(defcustom nns-profile-generation nil
  "Generation of the named profile, or nil for its current generation.
The selected target is resolved once per buffer, not on every subprocess."
  :type '(choice (const :tag "Current" nil) (integer :tag "Generation"))
  :group 'nns)
(make-variable-buffer-local 'nns-profile)
(make-variable-buffer-local 'nns-profile-generation)
(defcustom nns-system-shell "/system/bin/sh"
  "Android shell used for namespace diagnostics and command execution."
  :type 'file :group 'nns)
(defvar-local nns--profile-cache nil)
(defvar nns--inhibit nil)
(defvar nns-mode nil)
(defvar android-use-exec-loader)

(defun nns--launcher-command (command &optional profile generation)
  "Wrap COMMAND with PROFILE and GENERATION without shell interpolation."
  (append (list nns-launcher "--userns" "--store" nns-store
                "--tmpdir" (directory-file-name temporary-file-directory))
          (when profile (list "--profile" profile))
          (when generation (list "--generation" (number-to-string generation)))
          (list "--") command))

(defun nns--invoke (function &rest args)
  "Call FUNCTION with ARGS and process-local Nix client configuration."
  (let ((nns--inhibit t)
        ;; Android's emulated exec traces children outside their namespace.
        (android-use-exec-loader nil)
        (process-environment (copy-sequence process-environment)))
    (setenv "NIX_CONF_DIR" (concat (directory-file-name nns-store) "/etc/nix"))
    (setenv "NIX_REMOTE" "daemon")
    (apply function args)))

(defun nns--resolved-profile ()
  "Resolve this buffer's selection inside the namespace and retain its target."
  (unless (and (stringp nns-profile)
               (or (string-prefix-p "/" nns-profile)
                   (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\'" nns-profile)))
    (user-error "NNS profile must be a published name or absolute path"))
  (when (and nns-profile-generation
             (or (not (integerp nns-profile-generation))
                 (<= nns-profile-generation 0)
                 (string-prefix-p "/" nns-profile)))
    (user-error "NNS generation requires a named profile and a positive integer"))
  (if (equal (list nns-profile nns-profile-generation) (car nns--profile-cache))
      (cdr nns--profile-cache)
    ;; Capture the selection before entering a temporary buffer: profile
    ;; variables are buffer-local, while the Android GUI cannot inspect /nix.
    (let* ((selection (list nns-profile nns-profile-generation))
           (command (nns--launcher-command
                     (list nns-system-shell "-c" "printf '%s' \"$NNS_PROFILE\"")
                     nns-profile nns-profile-generation))
           (target
            (with-temp-buffer
              (let ((status (apply #'nns--invoke #'call-process
                                   (car command) nil (current-buffer) nil (cdr command))))
                (unless (and (integerp status) (zerop status))
                  (user-error "NNS profile resolution failed (%s): %s" status (buffer-string)))
                (buffer-string)))))
      (unless (and (string-prefix-p "/" target)
                   (not (string-match-p "[\n\r]" target)))
        (user-error "NNS launcher returned an invalid profile target"))
      (setq nns--profile-cache (cons selection target))
      target)))

(defun nns--command (command)
  "Run COMMAND in this buffer's pinned package environment."
  (nns--launcher-command
   (append
    (list nns-system-shell "-c"
          (concat "if [ -f \"$NNS_PROFILE/etc/nns/environment\" ]; then "
                  ". \"$NNS_PROFILE/etc/nns/environment\" || exit; fi; exec \"$@\"")
          "nns-exec")
    command)
   (nns--resolved-profile)))

(defun nns--wrap-p (program)
  (and nns-mode (not nns--inhibit) program
       (not (equal program nns-launcher))
       (not (file-remote-p default-directory))))

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
  (if (not (nns--wrap-p command))
      (funcall function command remote)
    (let ((wrapped (nns--command
                    (list nns-system-shell "-c"
                          "p=$(command -v \"$1\") && test -f \"$p\" && test -x \"$p\" && printf '%s' \"$p\""
                          "nns-executable-find" command))))
      (with-temp-buffer
        (let ((status (apply #'nns--invoke #'call-process (car wrapped) nil (current-buffer) nil
                             (cdr wrapped))))
          ;; Do not fall back to host tools when the selected environment
          ;; lacks a command. Discovery and actual execution must agree.
          (when (and (integerp status) (zerop status)) (buffer-string)))))))

(defun nns--nix-file-p (file)
  (and nns-mode (not nns--inhibit)
       (not (file-remote-p default-directory))
       (stringp file) (string-prefix-p "/nix/" file)))

(defun nns--ns-test (file test)
  "Return non-nil when TEST passes for FILE inside the namespace."
  (let* ((command (nns--command
                   (list nns-system-shell "-c" (concat test " \"$1\"") "nns-file-test" file)))
         (status (apply #'nns--invoke #'call-process (car command) nil nil nil (cdr command))))
    (and (integerp status) (zerop status))))

(defun nns--file-executable-p (function file)
  (if (nns--nix-file-p file) (nns--ns-test file "test -x") (funcall function file)))
(defun nns--file-exists-p (function file)
  (if (nns--nix-file-p file) (nns--ns-test file "test -e") (funcall function file)))
(defun nns--file-regular-p (function file)
  (if (nns--nix-file-p file) (nns--ns-test file "test -f") (funcall function file)))

(defun nns--eshell-get-path (function &optional literal-p)
  (let ((path (funcall function literal-p)))
    (if (not (and nns-mode (not nns--inhibit)
                  (not (file-remote-p default-directory)) path))
        path
      (let ((bin (concat (directory-file-name (nns--resolved-profile)) "/bin")))
        (cons "/data/nix/var/nns/bin"
              (cons bin (remove "/data/nix/var/nns/bin" (remove bin path))))))))

(defun nns--eshell-advice (enable)
  (with-eval-after-load 'esh-util
    (if enable
        (advice-add 'eshell-get-path :around #'nns--eshell-get-path)
      (advice-remove 'eshell-get-path #'nns--eshell-get-path))))

;;;###autoload
(defun nns-select-profile (profile &optional generation)
  "Select PROFILE and optional GENERATION for new processes in this buffer.
Existing processes are not restarted.  With a prefix, prompt for a generation.
Re-select the current name to resolve its latest target."
  (interactive (list (read-string "NNS profile name or path: " nns-profile)
                     (when current-prefix-arg (read-number "Generation: "))))
  (let ((previous (list nns-profile nns-profile-generation nns--profile-cache)))
    (setq-local nns-profile profile nns-profile-generation generation nns--profile-cache nil)
    (condition-case error
        (message "NNS profile: %s" (nns--resolved-profile))
      (error
       (setq-local nns-profile (nth 0 previous) nns-profile-generation (nth 1 previous)
                   nns--profile-cache (nth 2 previous))
       (signal (car error) (cdr error))))))

;;;###autoload
(defun nns-check ()
  "Report this buffer's namespace, pinned profile and editor tool availability.
No root fallback is attempted.  Missing tools are reported, not installed."
  (interactive)
  (when (file-remote-p default-directory) (user-error "Run nns-check from a local buffer"))
  (let ((command (nns--command
                  (list nns-system-shell "-c"
                        (concat "set -e; id; test -d /nix/store; test \"$(id -u)\" = \"$1\"; "
                                "printf 'PROFILE=%s\\nHOME=%s\\n' \"$NNS_PROFILE\" \"$HOME\"; "
                                "for tool in git bash; do command -v \"$tool\" || "
                                "printf 'MISSING: %s\\n' \"$tool\"; done; echo NNS-USERNS-OK")
                        "nns-check" (number-to-string (user-uid))))))
    (with-temp-buffer
      (let* ((status (apply #'nns--invoke #'call-process (car command) nil (current-buffer) nil (cdr command)))
             (output (buffer-string)))
        (unless (and (integerp status) (zerop status))
          (user-error "NNS namespace setup failed (%s): %s" status output))
        (when (called-interactively-p 'interactive) (message "%s" output))
        output))))

;;;###autoload
(define-minor-mode nns-mode
  "Run local subprocesses with canonical /nix, retaining the app's UID and HOME.
Remote/TRAMP processes are left alone.  Disable to run outside NNS."
  :global t :group 'nns
  (when nns-mode
    (condition-case error
        (nns-check)
      (error (setq nns-mode nil) (signal (car error) (cdr error)))))
  (dolist (pair '((call-process . nns--call-process)
                  (call-process-region . nns--call-process-region)
                  (start-process . nns--start-process)
                  (make-process . nns--make-process)
                  (executable-find . nns--executable-find)
                  (file-executable-p . nns--file-executable-p)
                  (file-regular-p . nns--file-regular-p)
                  (file-exists-p . nns--file-exists-p)))
    (if nns-mode
        (advice-add (car pair) :around (cdr pair))
      (advice-remove (car pair) (cdr pair))))
  (nns--eshell-advice nns-mode))

;;;###autoload
(defun nns-shell ()
  "Open a shell in the selected profile without adopting another app's HOME."
  (interactive)
  (nns-check)
  (require 'comint)
  (let* ((target (nns--resolved-profile))
         (selection (list nns-profile nns-profile-generation))
         (command (nns--command '("bash" "--noprofile" "--norc" "-i")))
         (buffer (get-buffer-create (format "*NNS: %s*" target))))
    (unless (comint-check-proc buffer)
      (apply #'nns--invoke #'make-comint-in-buffer "NNS" buffer (car command) nil (cdr command)))
    (with-current-buffer buffer
      (setq-local nns-profile (car selection)
                  nns-profile-generation (cadr selection)
                  nns--profile-cache (cons selection target)))
    (pop-to-buffer buffer)))

(provide 'nns)
;;; nns.el ends here
