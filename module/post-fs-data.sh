#!/system/bin/sh
#
# NNS (Native Nix Store) - post-fs-data
#
# Prepares the persistent store. The /nix mount itself happens per-session
# via bin/nix-enter (a global boot-time root pivot proved bootloop-prone on
# this device: init keeps its old fs->root while its tree is gutted, so every
# service init spawns post-pivot crash-loops).
#
LOG=/data/local/tmp/nix-post-fs-data.log

exec > $LOG 2>&1
set -x

mkdir -p /data/nix/store /data/nix/var /data/nix/tmp
mkdir -p /data/nix/etc/nix /data/nix/etc/profile.d /data/nix/home /data/nix/var/nix/profiles
chmod 755 /data/nix /data/nix/store /data/nix/var
chmod 1777 /data/nix/tmp

# convenience symlink inside the store dir for on-device poking
[ -e /data/local/tmp/nix ] || ln -s /data/nix /data/local/tmp/nix

echo "nix store ready at /data/nix"
echo "enter a session:  su -c '/data/adb/modules/nix/bin/nix-enter <command>'"
