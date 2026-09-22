#!/system/bin/sh
# Immutable store/config must remain executable from app domains, and the
# labels must match file_contexts (generic /data rule = system_data_file):
# the ROM's init runs `restorecon --recursive --skip-ce /data` at
# post-fs-data, and our old system_file labels made it pay a denial +
# printk + audit record per store path - 332 seconds at 25k paths.
# Aligned labels make the walk match and skip; new objects inherit the
# label from their (aligned) parent dirs, so no per-file store walk is
# needed anymore. Label only the public store/config, never app data.
LOG=/data/local/tmp/nix-service.log
exec > "$LOG" 2>&1

[ -d /data/nix/store ] || exit 0
for path in /data/nix /data/nix/store /data/nix/etc /data/nix/etc/nix /data/nix/etc/profile /data/nix/etc/nix/nix.conf \
    /data/nix/var /data/nix/var/nix; do
  [ ! -e "$path" ] || chcon -h u:object_r:system_data_file:s0 "$path"
done
# Profile links: activation creates them inside the profiles dir and they
# inherit its label; re-assert the few existing ones so old links align
# too. Readable by every domain either way (system_data_file is open-read).
find /data/nix/var/nix/profiles -maxdepth 1 -type l \
  -exec chcon -h u:object_r:system_data_file:s0 {} +

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
# The daemon resolves trusted-users (@group) against its OWN /etc, which
# the staged tree provides with the nix-trusted group; see stage-etc.sh.
sh /data/adb/modules/nix/stage-etc.sh
# A canonical profile may be dangling outside the namespace. Resolve its
# executable only after entering /nix, not with a host-side test -x.
# A reboot leaves the pidfile on /data and pids recycle - ours once
# landed on Bitwarden and the gate believed the daemon was alive. Only
# trust a pid whose cmdline still is our launcher wrapper or nix itself.
if [ -f "$PIDFILE" ]; then
  p=$(cat "$PIDFILE" 2>/dev/null || true)
  case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)" in
    *nix-enter* | *bin/nix*) ;;
    *) rm -f "$PIDFILE" ;;
  esac
fi
if [ -L "$PROFILE" ] || [ -d "$PROFILE" ]; then
  if ! [ -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    nohup env TMPDIR=/data/nix/tmp HOME=/data/nix/home \
      NIX_CONF_DIR=/data/nix/etc/nix NIX_REMOTE=local \
      /data/adb/modules/nix/bin/nix-enter --etc /data/nix/var/daemon-etc -- "$NIX" daemon \
      >> /data/local/tmp/nix-daemon.log 2>&1 &
    echo $! > "$PIDFILE"
  fi
fi
