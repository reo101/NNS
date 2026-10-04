#!/system/bin/sh
# Launch the NNS NixOS AVF guest: the client jar plus the payload directory
# live in /data/nix/var/avf (root-owned); the client runs in a root launcher
# session and relays the guest console to stdout. Args pass through to the
# client (no args = the probe guest).
exec /data/nix/bin/nix-enter -- /system/bin/sh -c '
  export CLASSPATH=/data/nix/var/avf/avf-client.jar
  exec app_process /system/bin xyz.reo101.nns.avf.VirtualMachineClient "$@"
' "$@"
