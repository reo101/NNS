#!/system/bin/sh
# Shared, immutable store contents must remain executable from app domains.
# Label only the public store/config, never app data or Nix's private state.
LOG=/data/local/tmp/nix-service.log
exec > "$LOG" 2>&1

[ -d /data/nix/store ] || exit 0
find /data/nix/store -xdev -exec chcon -h u:object_r:system_file:s0 {} +
for path in /data/nix/etc /data/nix/etc/nix /data/nix/etc/profile /data/nix/etc/nix/nix.conf \
    /data/nix/var /data/nix/var/nix /data/nix/var/nix/profiles; do
  [ ! -e "$path" ] || chcon -h u:object_r:system_file:s0 "$path"
done
# Shared profile links can be dangling until /nix is mounted. Label the links
# themselves, not their targets, and leave per-user profiles and the DB alone.
find /data/nix/var/nix/profiles -maxdepth 1 -type l \
  -exec chcon -h u:object_r:system_file:s0 {} +

# Root nix daemon: single-user nix locks the store DB for every command,
# so unprivileged app sessions (NIX_REMOTE=daemon) talk to this daemon
# instead of touching the DB directly. It runs inside its own root
# namespace where /nix is the canonical store, so its patchelf'd binary
# resolves its interpreter and libraries; the socket it creates is backed
# by /data/nix/var/nix/daemon-socket/socket, the same file app sessions
# reach as /nix/var/nix/daemon-socket/socket through their launcher view.
PROFILE=/data/nix/var/nix/profiles/profile
NIX=/nix/var/nix/profiles/profile/bin/nix
PIDFILE=/data/nix/var/nix/daemon.pid
# A canonical profile may be dangling outside the namespace. Resolve its
# executable only after entering /nix, not with a host-side test -x.
if [ -L "$PROFILE" ] || [ -d "$PROFILE" ]; then
  if ! [ -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    nohup env TMPDIR=/data/nix/tmp HOME=/data/nix/home \
      NIX_CONF_DIR=/data/nix/etc/nix NIX_REMOTE=local \
      /data/adb/modules/nix/bin/nix-enter -- "$NIX" daemon \
      >> /data/local/tmp/nix-daemon.log 2>&1 &
    echo $! > "$PIDFILE"
  fi
fi
