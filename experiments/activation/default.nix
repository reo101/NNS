{ pkgs ? (builtins.getFlake (toString ../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem} }:
let
  inherit (pkgs) lib;
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../nix/nns-system/activate.sh
      ../../nix/nns-system/service-runtime.sh
      ../../tests/test-nns-activation.py
      ../../tests/test-nns-services.py
      ./activate.nu
      ./activate.clj
      ./process-boundary.sh
      ./test-activation.py
      ./test-service-control.py
      ./test-s6-rc.py
    ];
  };
  directory = "${source}/experiments/activation";
  serviceFixture = import ../../tests/nns-service-fixture.nix { inherit pkgs; };
  launcher = pkgs.callPackage ../../nix/launcher.nix {
    target = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl";
  };
  # Replace only the final interpreter invocation, retaining all generated state paths.
  rewriteFixture = language: command: pkgs.runCommand "nns-service-fixture-${language}" { } ''
    test "$(grep -c '^exec .*activate\.sh ' ${serviceFixture}/activate)" -eq 1
    mkdir -p "$out"
    cp -r ${serviceFixture}/* "$out/"
    rm "$out/activate"
    sed '/^exec .*activate\.sh /d' ${serviceFixture}/activate > "$out/activate"
    printf '%s\n' '${command} "$generation" "''${1:-switch}"' >> "$out/activate"
    chmod 755 "$out/activate"
  '';
  fixtures = {
    shell = serviceFixture;
    nushell = rewriteFixture "nushell" "exec ${lib.getExe pkgs.nushell} --no-config-file ${directory}/activate.nu";
    babashka = rewriteFixture "babashka" "exec ${lib.getExe pkgs.babashka} ${directory}/activate.clj";
  };
  native-control = import ./native-control.nix { inherit pkgs; };
in
{
  inherit fixtures native-control;
  versions = {
    nushell = pkgs.nushell.version;
    babashka = pkgs.babashka.version;
    zig = pkgs.zig.version;
    runit = pkgs.runit.version;
    s6 = pkgs.s6.version;
    s6-rc = pkgs.s6-rc.version;
  };
  tests = pkgs.writeShellApplication {
    name = "nns-activation-experiments";
    runtimeInputs = with pkgs; [
      python3 bash util-linux coreutils findutils gnugrep runit nushell babashka s6 s6-rc
    ];
    text = ''
      python3 ${directory}/test-activation.py
      ${lib.concatMapStringsSep "\n" (language: ''
        printf '\nReal runit lifecycle: ${language}\n'
        # The inherited fixture can race runsvdir while stopping runsv children.
        # A private PID namespace contains any remaining descendants at test exit.
        unshare --user --map-root-user --pid --mount --fork --kill-child --mount-proc \
          python3 ${source}/tests/test-nns-services.py ${lib.getExe launcher} ${fixtures.${language}}
      '') [ "shell" "nushell" "babashka" ]}
      export NNS_SERVICE_CONTROL=${lib.getExe native-control}
      python3 ${directory}/test-service-control.py
      python3 ${directory}/test-s6-rc.py
    '';
  };
}
