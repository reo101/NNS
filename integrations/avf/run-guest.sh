#!/system/bin/sh
# Launch the NNS NixOS AVF guest: the client jar plus the payload directory
# live in /data/nix/var/avf (root-owned); the client runs in a root launcher
# session, serves the existing store read-only with virtiofsd, and relays
# the guest console to stdout. Args pass through (no args = probe guest).
# LD_PRELOAD must go: the launcher's DNS bridge is not linkable from the
# com.android.virt APEX namespace, and virtmgr inherits the caller's env.
# shellcheck disable=SC2016
exec /data/nix/bin/nix-enter -- env LD_PRELOAD= /system/bin/sh -c '
  set -eu
  root=/data/nix/var/avf
  backend=$(cat "$root/virtiofsd-path")
  export NNS_VIRTIOFS_SOCKET="$root/nix-store-$$.sock"
  "$backend" --shared-dir=/data/nix --tag=nix-store \
    --socket-path="$NNS_VIRTIOFS_SOCKET" --sandbox=chroot --readonly \
    --inode-file-handles=never --rlimit-nofile=1048576 > "$root/virtiofsd.log" 2>&1 &
  backend_pid=$!
  trap '\''kill "$backend_pid" 2>/dev/null || true; wait "$backend_pid" 2>/dev/null || true; rm -f "$NNS_VIRTIOFS_SOCKET"'\'' EXIT
  attempt=0
  while [ ! -S "$NNS_VIRTIOFS_SOCKET" ]; do
    if ! kill -0 "$backend_pid" 2>/dev/null || [ "$attempt" -ge 50 ]; then
      cat "$root/virtiofsd.log" >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  export CLASSPATH="$root/avf-client.jar"
  app_process /system/bin xyz.reo101.nns.avf.VirtualMachineClient "$@"
' sh "$@"
