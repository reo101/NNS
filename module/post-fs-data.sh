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
export PATH=/data/adb/ksu/bin:/system/bin:/system/xbin
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
. "$MODDIR/system-generation.sh"
NNS_SYSTEM_GENERATION=false
if nns_system_selected; then NNS_SYSTEM_GENERATION=true; fi
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

if [ "$NNS_SYSTEM_GENERATION" = false ]; then
# Nix wants CA certificates; Android ships no /etc/ssl/certs, so point
# nix.conf at the nss-cacert bundle already inside the store (referenced
# via /nix, the path visible inside launcher sessions).
cacert=$(ls /data/nix/store/*cacert*/etc/ssl/certs/ca-bundle.crt /data/nix/store/*cacert*/etc/ssl/certs/ca-certificates.crt 2>/dev/null | head -n 1)
if [ -n "$cacert" ] && [ -f /data/nix/etc/nix/nix.conf ]; then
  sed -i '/^ssl-cert-file/d' /data/nix/etc/nix/nix.conf
  printf 'ssl-cert-file = /nix/store/%s\n' "${cacert#/data/nix/store/}" >> /data/nix/etc/nix/nix.conf
fi

# Sync the module-owned base config, preserving the NoD-managed
# settings block (nns.nix.settings) written by activation.
if [ -f /data/nix/etc/nix/nix.conf ]; then
  sed -n '/^# >>> nns.nix.settings/,/^# <<< nns.nix.settings/p' \
    /data/nix/etc/nix/nix.conf > /data/nix/etc/nix/.nns-managed || true
fi
cp "$MODDIR/etc/nix/nix.conf" /data/nix/etc/nix/nix.conf || exit 1
if [ -s /data/nix/etc/nix/.nns-managed ]; then
  cat /data/nix/etc/nix/.nns-managed >> /data/nix/etc/nix/nix.conf
fi
rm -f /data/nix/etc/nix/.nns-managed

# Trust: apps whose uid maps into the nix-trusted group (resolved through
# the daemon's staged /etc, see stage-etc.sh) are nix trusted-users.
if [ -f /data/nix/etc/nix/nix.conf ]; then
  sed -i '/^trusted-users/d' /data/nix/etc/nix/nix.conf
  printf '\ntrusted-users = root @nix-trusted\n' >> /data/nix/etc/nix/nix.conf
fi
[ -f /data/nix/etc/nss-trusted ] || : > /data/nix/etc/nss-trusted
fi

# nns.services state, all DE so it exists before first unlock: services/ is
# activation-owned (app uid writes run-script symlinks into it), ready/ takes
# the unlock markers (root-only). The launcher supplies /var/empty privately.
mkdir -p /data/nix/var/nns/services /data/nix/var/nns/ready \
  /data/nix/var/nns/bin /data/nix/var/sshd
if [ "$NNS_SYSTEM_GENERATION" = true ]; then
  chown 0:0 /data/nix/var/nns /data/nix/var/nns/bin
  chmod 755 /data/nix/var/nns /data/nix/var/nns/bin
else
chown @APP_UID@:@APP_GID@ /data/nix/var/nns/services /data/nix/var/nns/bin /data/nix/var/sshd
# The app's SELinux categories derive from its uid (c66,... above = uid
# 10578); mirror the app data dir's live context instead of hardcoding it.
chcon "$(ls -Zd /data/data/@APP_ID@ | tr -s ' ' | cut -d ' ' -f 1)" \
  /data/nix/var/nns/services
chcon u:object_r:system_data_file:s0 /data/nix/var/sshd
fi

# Shizuku-backed su/sudo/rish for every launcher session. /data/nix/var/nns/bin
# is already the first sessionPath entry and nix-enter prepends it for bare
# sessions, so no NoD login is required. The dex rides in the module (no store
# path baked into the scripts); the staged app-id gives the wrappers their
# per-host default while NNS_APPLICATION_ID overrides per invocation.
for artifact in rish su sudo rish-probe; do
  rm -f "/data/nix/var/nns/bin/$artifact.new"
  cp "$MODDIR/bin/$artifact" "/data/nix/var/nns/bin/$artifact.new" || exit 1
  chmod 755 "/data/nix/var/nns/bin/$artifact.new"
  chown 0:0 "/data/nix/var/nns/bin/$artifact.new"
  chcon u:object_r:system_data_file:s0 "/data/nix/var/nns/bin/$artifact.new" || exit 1
  mv -f "/data/nix/var/nns/bin/$artifact.new" "/data/nix/var/nns/bin/$artifact"
done
rm -f /data/nix/lib/rish.dex.new
cp "$MODDIR/lib/rish.dex" /data/nix/lib/rish.dex.new || exit 1
chmod 444 /data/nix/lib/rish.dex.new
chown 0:0 /data/nix/lib/rish.dex.new
chcon u:object_r:system_data_file:s0 /data/nix/lib/rish.dex.new || exit 1
mv -f /data/nix/lib/rish.dex.new /data/nix/lib/rish.dex
printf '%s\n' '@APP_ID@' > /data/nix/etc/app-id
chown 0:0 /data/nix/etc/app-id
chmod 644 /data/nix/etc/app-id
# Boot reset, same class as the daemon pidfile: readiness markers and runsv
# control state never survive a boot - a stale 'unlock' marker would let
# startAt=unlock services race CE, stale supervise pids recycle like the
# daemon's pid did (Bitwarden).
if [ "$NNS_SYSTEM_GENERATION" = true ]; then
  rm -f /data/nix/var/nns/supervisor.pid
else
  rm -f /data/nix/var/nns/ready/*
  rm -rf /data/nix/var/nns/services/*/supervise
fi

# nix store gc keeps only what is reachable from /nix/var/nix/gcroots.
# The profile links (system-profile, nix-on-droid generations) are
# created manually and would be collected otherwise - root the whole
# profiles directory once; every link inside it is then protected.
if [ ! -e /data/nix/var/nix/gcroots/profiles ]; then
  mkdir -p /data/nix/var/nix/gcroots
  ln -sfn /data/nix/var/nix/profiles /data/nix/var/nix/gcroots/profiles
  chown 0:0 /data/nix/var/nix/gcroots/profiles
fi

# convenience symlink inside the store dir for on-device poking
[ -e /data/local/tmp/nix ] || ln -s /data/nix /data/local/tmp/nix

echo "nix store ready at /data/nix"
echo "app session: /data/nix/bin/nix-enter --userns -- <command>"
echo "root fallback: su -c '/data/adb/modules/nix/bin/nix-enter -- <command>'"
