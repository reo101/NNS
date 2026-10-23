{
  pkgs ? (builtins.getFlake (toString ../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:
let
  launcher = (pkgs.callPackage ../../nix/launcher.nix { }).override {
    target = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl";
  };
  backends = [
    "runit"
    "s6-rc"
    "dinit"
  ];
  variants = [
    "base"
    "update"
    "typechange"
    "remove"
    "gated"
    "finite-failure"
  ];
  fixtures = builtins.listToAttrs (
    builtins.concatMap (
      backend:
      map (variant: {
        name = "${backend}-${variant}";
        value = import ./fixture.nix { inherit pkgs backend variant; };
      }) variants
    ) backends
  );
  evaluation =
    assert import ./evaluation.nix { inherit pkgs; };
    pkgs.runCommand "check-nns-service-manager-evaluation" { } "touch $out";
in
{
  inherit fixtures evaluation;
  tests = pkgs.writeShellApplication {
    name = "test-nns-service-managers";
    runtimeInputs = with pkgs; [
      python3
      bash
      coreutils
      util-linux
      s6
      s6-rc
      dinit
    ];
    text = ''
      test -e ${evaluation}
      scratch=$(mktemp -d)
      trap 'rmdir "$scratch"' EXIT
      unshare --user --map-root-user --mount --fork \
        ${pkgs.lib.getExe launcher} --store /nix --tmpdir "$scratch" -- \
        unshare --pid --fork --kill-child --mount-proc python3 ${./test-runtime.py} ${
          builtins.concatStringsSep " " (
            builtins.concatMap (backend: map (variant: "${fixtures."${backend}-${variant}"}") variants) backends
          )
        }
    '';
  };
}
