# Device-side switch for the system profile, shipped inside the profile
# itself. Run inside a launcher session (the daemon talks through
# NIX_REMOTE there):
#
#   nix-enter -- nns-system-profile-switch /nix/store/<hash>-nns-system-profile
#
# The path must already be in the store (`nix copy --to ssh://…` from the
# host, or a native on-device build). Verifies, bumps the numbered
# generation atomically, exec-tests under bionic, rolls back on failure,
# then restarts the daemon into the new profile.
{
  phonePkgs,
}:
let
  switch = phonePkgs.writeText "nns-system-profile-switch" /* sh */ ''
    #!/system/bin/sh
    set -eu
    if [ "$#" -ne 1 ]; then
      echo "usage: nns-system-profile-switch /nix/store/<hash>-nns-system-profile" >&2
      exit 2
    fi
    new=$1
    case "$new" in
      /nix/store/*) ;;
      *) echo "expected a /nix/store path, got: $new" >&2; exit 2 ;;
    esac
    if [ ! -x "$new/bin/nix-daemon" ]; then
      echo "$new lacks bin/nix-daemon - not a system profile" >&2
      exit 1
    fi

    P=/data/nix/var/nix/profiles
    n=$(ls "$P" | sed -n 's/^system-profile-\([0-9]*\)-link$/\1/p' | sort -n | tail -1)
    n=$(( ''${n:-0} + 1 ))
    old=$(readlink "$P/system-profile" 2>/dev/null || true)

    ln -sfn "$new" "$P/system-profile-$n-link"
    ln -sfn "system-profile-$n-link" "$P/system-profile"

    # The new nix must load and link under bionic before it matters.
    if ! "$new/bin/nix" --version >/dev/null 2>&1; then
      if [ -n "$old" ]; then
        ln -sfn "$old" "$P/system-profile"
      fi
      echo "switch: new profile failed verification, rolled back" >&2
      exit 1
    fi

    # Restart the daemon into the new profile. The pidfile gate in
    # service.sh re-asserts or replaces this at the next boot either way.
    if [ -f /data/nix/var/nix/daemon.pid ]; then
      kill "$(cat /data/nix/var/nix/daemon.pid)" 2>/dev/null || true
      rm -f /data/nix/var/nix/daemon.pid
    fi
    nohup env TMPDIR=/data/nix/tmp HOME=/data/nix/home \
      NIX_CONF_DIR=/data/nix/etc/nix NIX_REMOTE=local \
      /data/nix/bin/nix-enter --etc /data/nix/var/daemon-etc -- "$new/bin/nix" daemon \
      >> /data/local/tmp/nix-daemon.log 2>&1 &
    echo $! > /data/nix/var/nix/daemon.pid

    echo "switched to generation $n: $new (daemon restarted)"
  '';
in
phonePkgs.runCommand "nns-system-profile-switch" { } ''
  mkdir -p "$out/bin"
  install -m 755 ${switch} "$out/bin/nns-system-profile-switch"
''
