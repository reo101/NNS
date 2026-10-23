{
  pkgs ? (builtins.getFlake (toString ../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:
let
  inherit (pkgs) lib;
  fixtures = lib.genAttrs [ "s6-rc" "dinit" ] (
    backend: (import ./fixture.nix { inherit pkgs backend; }).package
  );
  empty = lib.genAttrs [ "s6-rc" "dinit" ] (
    backend: (import ../../nix/service-backends { inherit pkgs backend; }).package
  );
  evaluation =
    assert import ./evaluation.nix { inherit pkgs; };
    pkgs.runCommand "check-portable-service-evaluation" { } "touch $out";
in
{
  inherit fixtures empty evaluation;
  versions = {
    dinit = pkgs.dinit.version;
    s6 = pkgs.s6.version;
    s6-rc = pkgs.s6-rc.version;
  };
  tests = pkgs.writeShellApplication {
    name = "test-portable-service-backends";
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
      test -e ${empty.s6-rc}/manifest.json
      test -e ${empty.dinit}/manifest.json
      exec unshare --user --map-root-user --mount --pid --fork --kill-child --mount-proc \
        python3 ${./test-runtime.py} ${fixtures.s6-rc} ${fixtures.dinit}
    '';
  };
}
