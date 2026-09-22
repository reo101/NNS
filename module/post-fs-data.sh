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
# Boot is a hard reset for the daemon pidfile: nothing alive survived, and
# a recycled pid fooled the service.sh gate once (landed on Bitwarden).
rm -f /data/nix/var/nix/daemon.pid
chmod 755 /data/nix /data/nix/store /data/nix/var
# Owner too: something in this ROM's early /data pass chowns unknown
# directories to bluetooth:960, and sshd StrictModes rejects any
# AuthorizedKeysFile path component not owned by root or the user.
chown 0:0 /data/nix
chmod 1777 /data/nix/tmp
# init recreates /tmp (shell:shell 0771) at every boot; sessions run as
# the app uid and need a standard sticky temp dir there (deploy-rs's
# activation watcher, scp, ...). post-fs-data runs after init, so this
# lands every boot.
chmod 1777 /tmp

# /data/adb is deliberately inaccessible to apps. Publish only the static,
# non-setuid launcher; callers retain their UID and enter the nns_app domain
# via the sepolicy.rule type_transition.
chown 0:0 /data/nix/bin
chmod 755 /data/nix/bin
rm -f /data/nix/bin/nix-enter.new
cp "$MODDIR/bin/nix-enter" /data/nix/bin/nix-enter.new || exit 1
chmod 755 /data/nix/bin/nix-enter.new
# system_data_file, not system_file: that is what file_contexts maps for
# all of /data, and mismatching it made init's boot restorecon -R /data
# burn 332 seconds in per-path denial+printk loops over the store.
# nix-enter keeps nns_exec - init cannot relabel it (relabelfrom denied),
# which is precisely what preserves the app -> nns_app transition.
chcon u:object_r:system_data_file:s0 /data/nix /data/nix/bin || exit 1
chcon u:object_r:nns_exec:s0 /data/nix/bin/nix-enter.new || exit 1
mv -f /data/nix/bin/nix-enter.new /data/nix/bin/nix-enter

# Public, non-setuid resolver artifacts. Publish atomically so running sessions
# never map a partially copied library. No Android /etc files are replaced.
mkdir -p /data/nix/lib
chown 0:0 /data/nix/lib
chmod 755 /data/nix/lib
chcon u:object_r:system_data_file:s0 /data/nix/lib || exit 1
for artifact in bin/nns-resolver lib/libnns-dns.so; do
  rm -f "/data/nix/$artifact.new"
  cp "$MODDIR/$artifact" "/data/nix/$artifact.new" || exit 1
  chmod 755 "/data/nix/$artifact.new"
  chown 0:0 "/data/nix/$artifact.new"
  chcon u:object_r:system_data_file:s0 "/data/nix/$artifact.new" || exit 1
  mv -f "/data/nix/$artifact.new" "/data/nix/$artifact"
done

# This kernel exposes an exec-time seccomp bypass allowlist; register the
# launcher so app-domain sessions can shed the zygote seccomp filter. On
# kernels without the sysctl this is a no-op (the launcher is limited to
# syscall subsets the app filter permits).
if [ -w /proc/sys/kernel/seccomp_bypass_paths ]; then
  echo /data/nix/bin/nix-enter > /proc/sys/kernel/seccomp_bypass_paths
fi

# Nix wants CA certificates; Android ships no /etc/ssl/certs, so point
# nix.conf at the nss-cacert bundle already inside the store (referenced
# via /nix, the path visible inside launcher sessions).
cacert=$(ls /data/nix/store/*cacert*/etc/ssl/certs/ca-bundle.crt /data/nix/store/*cacert*/etc/ssl/certs/ca-certificates.crt 2>/dev/null | head -n 1)
if [ -n "$cacert" ] && [ -f /data/nix/etc/nix/nix.conf ]; then
  sed -i '/^ssl-cert-file/d' /data/nix/etc/nix/nix.conf
  printf 'ssl-cert-file = /nix/store/%s\n' "${cacert#/data/nix/store/}" >> /data/nix/etc/nix/nix.conf
fi

# Trust: apps whose uid maps into the nix-trusted group (resolved through
# the daemon's staged /etc, see stage-etc.sh) are nix trusted-users.
if [ -f /data/nix/etc/nix/nix.conf ]; then
  sed -i '/^trusted-users/d' /data/nix/etc/nix/nix.conf
  echo 'trusted-users = root @nix-trusted' >> /data/nix/etc/nix/nix.conf
fi
[ -f /data/nix/etc/nss-trusted ] || : > /data/nix/etc/nss-trusted

# nns.services state, all DE so it exists before first unlock: services/ is
# activation-owned (app uid writes run-script symlinks into it), ready/ takes
# the unlock markers (root-only), /data/ve is sshd's privsep chroot (contents
# are provisioned from staged NSS in service.sh, after stage-etc runs).
mkdir -p /data/nix/var/nns/services /data/nix/var/nns/ready \
  /data/nix/var/sshd /data/ve/etc
chown 10578:10578 /data/nix/var/nns/services /data/nix/var/sshd
chcon u:object_r:app_data_file:s0:c66,c258,c512,c768 /data/nix/var/nns/services
chcon u:object_r:system_data_file:s0 /data/nix/var/sshd
chmod 755 /data/ve /data/ve/etc
# Boot reset, same class as the daemon pidfile: readiness markers and runsv
# control state never survive a boot - a stale 'unlock' marker would let
# startAt=unlock services race CE, stale supervise pids recycle like the
# daemon's pid did (Bitwarden).
rm -f /data/nix/var/nns/ready/*
rm -rf /data/nix/var/nns/services/*/supervise

# convenience symlink inside the store dir for on-device poking
[ -e /data/local/tmp/nix ] || ln -s /data/nix /data/local/tmp/nix

echo "nix store ready at /data/nix"
echo "app session: /data/nix/bin/nix-enter --userns -- <command>"
echo "root fallback: su -c '/data/adb/modules/nix/bin/nix-enter -- <command>'"
