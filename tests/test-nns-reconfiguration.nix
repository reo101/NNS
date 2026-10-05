{ pkgs }:
let
  evaluate =
    modules:
    (import ../nix/nns-system.nix { nixpkgs = pkgs.path; } {
      system = pkgs.stdenv.hostPlatform.system;
      inherit pkgs;
      modules = [
        {
          environment.profiles.development.packages = [
            pkgs.git
            pkgs.bashInteractive
          ];
          services.openssh = {
            enable = true;
            authorizedRootKeys = [ "ssh-ed25519 AAAATEST evaluation-only" ];
          };
        }
      ]
      ++ modules;
    }).config.system.build.toplevel;
  original = evaluate [ ];
  daemonChanged = evaluate [ { nix.settings.max-jobs = 1; } ];
  keysChanged = evaluate [
    {
      services.openssh.authorizedRootKeys = pkgs.lib.mkForce [ "ssh-ed25519 AAAANEW evaluation-only" ];
    }
  ];
  profileChanged = evaluate [ { environment.profiles.development.variables.EDITOR = "editor"; } ];
in
pkgs.runCommand "check-nns-reconfiguration" { } ''
  test "$(readlink -f ${original}/services/nix-daemon/run)" != \
    "$(readlink -f ${daemonChanged}/services/nix-daemon/run)"
  test "$(readlink -f ${original}/services/sshd/run)" != \
    "$(readlink -f ${keysChanged}/services/sshd/run)"
  for service in nix-daemon sshd; do
    test "$(readlink -f ${original}/services/$service/run)" = \
      "$(readlink -f ${profileChanged}/services/$service/run)"
  done
  touch "$out"
''
