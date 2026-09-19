#!/system/bin/sh
#
# NNS (Native Nix Store) - post-fs-data
#
# Prepares the persistent store. The /nix mount itself happens per-session
# via bin/nix-enter (a global boot-time root pivot proved bootloop-prone on
# this device: init keeps its old fs->root while its tree is gutted, so every
# service init spawns post-pivot crash-loops).
#
MODDIR=${0%/*}
LOG=/data/local/tmp/nix-post-fs-data.log

exec > $LOG 2>&1
set -x

mkdir -p /data/nix/store /data/nix/var /data/nix/tmp /data/nix/bin
mkdir -p /data/nix/etc/nix /data/nix/etc/profile.d /data/nix/home /data/nix/var/nix/profiles
chmod 755 /data/nix /data/nix/store /data/nix/var
chmod 1777 /data/nix/tmp

# /data/adb is deliberately inaccessible to apps. Publish only the static,
# non-setuid launcher; callers retain their UID and SELinux domain.
chown 0:0 /data/nix/bin
chmod 755 /data/nix/bin
rm -f /data/nix/bin/nix-enter.new
cp "$MODDIR/bin/nix-enter" /data/nix/bin/nix-enter.new || exit 1
chmod 755 /data/nix/bin/nix-enter.new
chcon u:object_r:system_file:s0 /data/nix /data/nix/bin /data/nix/bin/nix-enter.new || exit 1
mv -f /data/nix/bin/nix-enter.new /data/nix/bin/nix-enter

# convenience symlink inside the store dir for on-device poking
[ -e /data/local/tmp/nix ] || ln -s /data/nix /data/local/tmp/nix

echo "nix store ready at /data/nix"
echo "app session: /data/nix/bin/nix-enter --userns -- <command>"
echo "root fallback: su -c '/data/adb/modules/nix/bin/nix-enter -- <command>'"
