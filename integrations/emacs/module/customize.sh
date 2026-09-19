#!/system/bin/sh
[ "$BOOTMODE" = true ] || abort "Install from the root manager, not recovery."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
ui_print "Requires the NNS core module. No Emacs configuration is overwritten."
ui_print "After reboot, load /data/nix/share/emacs/site-lisp/nns.el and run M-x nns-check."
