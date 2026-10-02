# Deploy the system profile to a phone: copy the closure, verify it
# complete, flip `system-profile` to a new numbered generation (atomic
# rename), exec-test the new nix against the running daemon, roll back on
# any failure, then retire the legacy profile names.
#
# The daemon keeps running the old binary until the next boot; the
# exec-test proves the new one loads and links under bionic, which is the
# only failure mode that would break boot.
{
  pkgs,
  lib,
  systemProfile,
  sshUser,
  sshHost,
  sshPort ? 22,
}:
pkgs.writeShellApplication {
  name = "nns-system-profile-deploy";
  runtimeInputs = [ pkgs.openssh ];
  # The profile path is content-addressed; a closure copy of an identical
  # build is a no-op.
  text = ''
    set -euo pipefail

    P=/data/nix/var/nix/profiles
    L=/data/nix/bin/nix-enter
    E="--etc /data/nix/var/daemon-etc"
    NEW="${systemProfile}"
    SSH_DEST="${sshUser}@${sshHost}"
    SSH_PORT="${toString sshPort}"
    SSH="ssh -o BatchMode=yes -p $SSH_PORT $SSH_DEST"

    die() {
      echo "system-profile-deploy: $*" >&2
      exit 1
    }

    # The launcher session must talk to the daemon as an app uid.
    remote_nix() {
      $SSH "env NIX_REMOTE=daemon $L $E -- $1"
    }

    # 1. Daemon reachable through the current profile.
    remote_nix "/nix/var/nix/profiles/system-profile/bin/nix store ping" \
      || die "daemon not reachable on $SSH_DEST"

    # 2. Ship the closure. The port rides via NIX_SSHOPTS; the remote side
    # resolves nix-store through its sshd session PATH.
    NIX_SSHOPTS="-p $SSH_PORT" nix copy --to "ssh://$SSH_DEST" "$NEW" \
      || die "closure copy failed"

    # 3. The closure must be complete before the flip.
    remote_nix "/nix/var/nix/profiles/system-profile/bin/nix path-info -r $NEW" \
      >/dev/null || die "copied closure is incomplete"

    # 4. Versioned atomic flip: rename(2) over the symlink, generations
    # browsable, old target kept for rollback.
    n=$(
      $SSH "ls $P 2>/dev/null | grep -o 'system-profile-[0-9]*-link' | sed 's/[^0-9]//g' | sort -n | tail -1"
    )
    n=$(( ''${n:-0} + 1 ))
    old=$($SSH "readlink $P/system-profile" || true)
    $SSH "ln -sfn $NEW $P/system-profile-$n-link && ln -sfn system-profile-$n-link $P/system-profile" \
      || die "flip failed"

    # 5. Exec-test: the new nix must load under bionic and reach the daemon.
    if ! remote_nix "$NEW/bin/nix store ping" >/dev/null 2>&1; then
      if [ -n "''${old:-}" ]; then
        $SSH "ln -sfn $old $P/system-profile" || true
      fi
      die "new profile failed verification, rolled back"
    fi

    # 6. Transitional fixes for artifacts that still name the old links:
    # sshd's session environment and generated run scripts (activation
    # regenerates both on the next host deploy, this keeps the interim
    # correct).
    $SSH "sed -i 's|profiles/profile|profiles/system-profile|g; s|profiles/default|profiles/system-profile|g' ~/.ssh/environment /data/nix/var/nns/services/*/run 2>/dev/null" \
      || true

    # 7. Legacy names out - nothing references them any more.
    $SSH "rm -f $P/profile $P/default $P/default-1"

    echo "system profile generation $n deployed: $NEW"
  '';
  passthru = { inherit systemProfile sshUser sshHost sshPort; };
}
