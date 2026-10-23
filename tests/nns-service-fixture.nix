{ pkgs }:
let
  base = "/data/nns-service-test";
  profileWriter = pkgs.writeShellScript "nns-test-profile-writer" ''
    set -eu
    while [ "$1" != --profile ]; do shift; done
    profile=$2; shift 2
    test "$1" = --set
    ${pkgs.coreutils}/bin/ln -sfn "$2" "$profile"
  '';
  fakeNix = pkgs.runCommand "nns-test-nix" { } ''
    mkdir -p "$out/bin"
    ln -s ${profileWriter} "$out/bin/nix-env"
    ln -s ${pkgs.coreutils}/bin/true "$out/bin/nix"
    ln -s ${pkgs.coreutils}/bin/true "$out/bin/nix-daemon"
  '';
in
(import ../nix/nns-system.nix { nixpkgs = pkgs.path; } {
  system = pkgs.stdenv.hostPlatform.system;
  inherit pkgs;
  modules = [
    {
      nix.package = fakeNix;
      system = {
        stateDirectory = "${base}/state";
        etcDirectory = "${base}/etc";
        profileDirectory = "${base}/profiles";
        nixConfDirectory = "${base}/nix";
        launcher = "${base}/bin/launcher";
        directories = {
          shared = {
            path = "${base}/shared";
            mode = "0710";
          };
          labeled = {
            path = "${base}/labeled";
            mode = "0750";
            startAt = "unlock";
            selinuxContextFromAccount = "root";
          };
        };
      };
      services.runit = {
        nix-daemon.nns.enable = false;
        prepare = {
          nns.type = "oneshot";
          process.argv = [
            (pkgs.writeShellScript "nns-test-prepare" ''
              printf 'attempt\n' >> ${base}/attempts
              test -f ${base}/release || exit 17
            '')
          ];
        };
        consumer = {
          nns.after = [ "prepare" ];
          process.argv = [
            (pkgs.writeShellScript "nns-test-consumer" ''
              : > ${base}/consumer-ready
              exec ${pkgs.coreutils}/bin/sleep infinity
            '')
          ];
        };
        unlocked = {
          nns = {
            type = "oneshot";
            startAt = "unlock";
          };
          process.argv = [
            (pkgs.writeShellScript "nns-test-unlocked" ''
              printf 'unlocked\n' >> ${base}/unlock-runs
            '')
          ];
        };
      };
    }
  ];
}).config.system.build.toplevel
