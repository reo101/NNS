#!/bin/sh
set -eu

nix=$1
jq=$2
client_version=$("$nix" --version)
client_version=${client_version##* }
printf 'nns: Nix client=%s\n' "$client_version"
daemon_info=$(NIX_REMOTE=daemon "$nix" --extra-experimental-features nix-command store info --json)
daemon_version=$(printf '%s\n' "$daemon_info" | "$jq" -r '.version // "unknown"')
printf 'nns: Nix daemon=%s; daemon connection succeeded\n' "$daemon_version"
if [ "$client_version" != "$daemon_version" ]; then
    printf 'nns: warning: Nix versions differ; feature support can differ despite a successful connection\n' >&2
fi
