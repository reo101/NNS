#!/system/bin/sh
set -eu
[ "$(id -u)" = "$1" ]
[ "$(readlink /proc/self/ns/user)" != "$2" ]
grep -q '^Seccomp:[[:space:]]*0$' /proc/self/status
grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status
grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status
grep -q ':nns_app:' /proc/self/attr/current
[ -d /nix/store ]
[ ! -w /nix/store ]
# These are root-owned; no root proxy or writable shared configuration.
[ ! -w /data/nix/bin/nix-enter ]
[ ! -w /data/nix/lib/libnns-dns.so ]
[ ! -w /data/nix/etc/nix/nix.conf ]
[ -n "$LD_PRELOAD" ]
[ ! -e /etc/resolv.conf ]

# A private DNS name served only by the fixture, never /etc/hosts or public DNS.
if env -u LD_PRELOAD curl -fsS --connect-timeout 2 --max-time 4 \
    -A 'OpenAI File Downloader, XaiImageApiFetch/1.0' http://nns-cache.test:31080/nix-cache-info; then
  echo 'glibc unexpectedly resolved without the bridge' >&2
  exit 1
fi
curl -fsS --max-time 15 -A 'OpenAI File Downloader, XaiImageApiFetch/1.0' \
  http://nns-cache.test:31080/nix-cache-info | grep -q '^StoreDir: /nix/store$'

# HELLO is absent from the seed; the daemon must fetch and register its closure.
nix-store --realise @HELLO@
nix path-info @HELLO@
nix profile install --offline --profile "$HOME/profile" @HELLO@
[ "$("$HOME/profile/bin/hello")" = 'Hello, world!' ]
echo NNS-APP-PASS
