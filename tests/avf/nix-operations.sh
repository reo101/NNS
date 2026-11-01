#!/usr/bin/env bash
set -eu
export NIX_REMOTE=daemon

socket=/run/nns-phone-daemon/socket
hello=@HELLO@
bash=@BASH@
coreutils=@COREUTILS@

echo 'nns-guest: GUEST DAEMON REACHABLE'
systemctl status nix-daemon.service --no-pager || true
journalctl -u nix-daemon.service -b --no-pager | tail -60 || true
for attempt in $(seq 1 60); do
  if nix store info >/dev/null 2>&1; then break; fi
  sleep 2
done
ls -la /nix/var/nix/daemon-socket || true
nix store info

# The guest store is the writable build partition, not the phone store.
findmnt --noheadings --output SOURCE /nix/store

# Realise hello from the guest's substituter, proving guest networking.
for attempt in $(seq 1 30); do
  if nix-store --realise "$hello"; then break; fi
  sleep 2
done
nix path-info "$hello"
mkdir -p /var/lib/nns-avf-verification
nix profile add --offline --profile /var/lib/nns-avf-verification/profile "$hello"
[ "$(/var/lib/nns-avf-verification/profile/bin/hello)" = 'Hello, world!' ]
echo 'nns-guest: PACKAGE REALISATION AND EXECUTION SUCCEEDED'

# A distinct derivation each boot proves a sandboxed guest build.
output=$(nix build --impure --no-link --print-out-paths \
  --option substitute false --option builders '' \
  --argstr verificationId "$(cat /proc/sys/kernel/random/boot_id)" --expr "$(cat <<'EOF'
{ verificationId }:
let
  bash = builtins.storePath "@BASH@";
  coreutils = builtins.storePath "@COREUTILS@";
in builtins.derivation {
  name = "nns-avf-guest-build-${verificationId}";
  system = "aarch64-linux";
  builder = "${bash}/bin/bash";
  args = [ "-c" ''${coreutils}/bin/mkdir "$out"; printf guest-build > "$out/result"'' ];
}
EOF
)")
nix path-info "$output"
[ "$(cat "$output/result")" = guest-build ]
printf 'nns-guest: guest build output=%s\n' "$output"

# Publish the output into the phone store through the bridge.
[ -S "$socket" ]
NIX_REMOTE= NIX_DAEMON_SOCKET_PATH="$socket" nix copy --no-check-sigs --to daemon "$output"
NIX_REMOTE= NIX_DAEMON_SOCKET_PATH="$socket" nix path-info --store daemon "$output"
echo 'nns-guest: GUEST BUILD AND PHONE PUBLICATION SUCCEEDED'
