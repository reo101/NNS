#!/system/bin/sh
# Sourced by Magisk/KernelSU's manager installer. No recovery or network setup.
[ "$BOOTMODE" = true ] || abort "Install NNS from the root manager, not recovery."
[ "$ARCH" = @ARCH@ ] || abort "This NNS build requires @ARCH@."

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/nix-enter" 0 0 0755
set_perm "$MODPATH/bin/nns-storage" 0 0 0755
set_perm "$MODPATH/bin/nns-resolver" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/prepare-runtime.sh" 0 0 0755
set_perm "$MODPATH/mount-ownership.sh" 0 0 0755

. "$MODPATH/mount-ownership.sh" || abort "Cannot read mount ownership mode."
nns_mount_mode || abort "Unsupported or unreadable mount ownership mode."
"$MODPATH/bin/nns-storage" --check || abort "Configured Nix backing is not ready."
if [ "$NNS_MOUNT_MODE" = rom ]; then
  nns_check_global_mount || abort "The ROM global Nix mount is not ready."
  umask 0022
fi

mkdir -p /data/nix/etc/nix /data/nix/var/log
# Seed defaults on first install; preserve user configuration on upgrades.
for file in profile nix/nix.conf; do
  if [ ! -e "/data/nix/etc/$file" ] && [ ! -L "/data/nix/etc/$file" ]; then
    cp "$MODPATH/etc/$file" "/data/nix/etc/$file" || abort "Cannot install $file"
    chmod 0644 "/data/nix/etc/$file"
  fi
done
ui_print "NNS installed. The Nix store/bootstrap closure is not included."
