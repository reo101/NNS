#!/system/bin/sh
# Shared, immutable store contents must remain executable from app domains.
# Label only the public store/config, never app data or Nix's private state.
LOG=/data/local/tmp/nix-service.log
exec > "$LOG" 2>&1

[ -d /data/nix/store ] || exit 0
find /data/nix/store -xdev -exec chcon -h u:object_r:system_file:s0 {} +
for path in /data/nix/etc /data/nix/etc/nix /data/nix/etc/profile /data/nix/etc/nix/nix.conf; do
  [ ! -e "$path" ] || chcon -h u:object_r:system_file:s0 "$path"
done
# No /nix mount in init's namespace, no symlink rewriting, no daemon startup.
