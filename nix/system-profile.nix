# The root-owned system profile: the nix daemon's own tooling plus the
# helpers boot scripts and services call by name (runit, socat, ...).
# Delivered by nix/system-profile-deploy (atomic versioned flip with a
# ping guard); NOT part of the module zip.
#
# Evaluated against the phone platform: pass `phonePkgs` scoped to
# aarch64-linux (pkgsCross.aarch64-multiplatform).
{
  lib ? null,
  phonePkgs,
  # Extra packages to merge into the profile.
  extraPaths ? [ ],
}:
phonePkgs.buildEnv {
  name = "nns-system-profile";
  paths = with phonePkgs;
    [
      nix
      runit
      socat
      busybox
      coreutils
      gnugrep
      gnutar
      gnused
      findutils
    ] ++ extraPaths;
  postBuild = ''
    # Older generated run scripts exec `nix-daemon` directly; nix ships it,
    # but fail loudly at build time rather than at boot if that ever moves.
    [ -x "$out/bin/nix-daemon" ] || {
      echo "nix package lacks bin/nix-daemon" >&2
      exit 1
    }
  '';
  passthru = { inherit extraPaths; };
}
