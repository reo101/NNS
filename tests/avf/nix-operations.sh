#!/usr/bin/env bash
set -eu
export NIX_REMOTE=daemon

# This path deliberately has no Nix string context in the guest closure.
hello=@HELLO@
if [ ! -e "$hello" ]; then
  echo 'nns-guest: PACKAGE ABSENT BEFORE REALISATION'
fi
nix-store --realise "$hello"
nix path-info "$hello"
mkdir -p /var/lib/nns-avf-verification
nix profile add --offline --profile /var/lib/nns-avf-verification/profile "$hello"
[ "$(/var/lib/nns-avf-verification/profile/bin/hello)" = 'Hello, world!' ]
echo 'nns-guest: PACKAGE REALISATION AND EXECUTION SUCCEEDED'

# A distinct derivation each boot proves a build, not a cached output lookup.
output=$(nix build --impure --no-link --print-out-paths --option substitute false \
  --argstr verificationId "$(cat /proc/sys/kernel/random/boot_id)" --expr "$(cat <<'EOF'
{ verificationId }:
let
  bash = builtins.storePath "@BASH@";
  coreutils = builtins.storePath "@COREUTILS@";
in builtins.derivation {
  name = "nns-avf-daemon-build-${verificationId}";
  system = "aarch64-linux";
  builder = "${bash}/bin/bash";
  args = [ "-c" ''${coreutils}/bin/mkdir "$out"; printf phone-daemon-build > "$out/result"'' ];
}
EOF
)")
nix path-info "$output"
[ "$(cat "$output/result")" = phone-daemon-build ]
printf 'nns-guest: daemon build output=%s\n' "$output"
echo 'nns-guest: DAEMON BUILD AND STORE VISIBILITY SUCCEEDED'

# Root must not be able to bypass the read-only export.
if message=$(LC_ALL=C touch "$output/guest-write-test" 2>&1); then
  echo 'nns-guest: SHARED STORE UNEXPECTEDLY WRITABLE' >&2
  exit 1
fi
printf '%s\n' "$message"
case "$message" in
  *'Read-only file system'*) ;;
  *) exit 1 ;;
esac
echo 'nns-guest: SHARED STORE WRITE REJECTED'
