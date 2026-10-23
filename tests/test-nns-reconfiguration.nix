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
          services.openssh.enable = true;
          accounts.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAATEST evaluation-only" ];
        }
      ]
      ++ modules;
    }).config.system.build.toplevel;
  original = evaluate [ ];
  daemonChanged = evaluate [ { nix.settings.max-jobs = 1; } ];
  keysChanged = evaluate [
    {
      accounts.root.openssh.authorizedKeys.keys = pkgs.lib.mkForce [
        "ssh-ed25519 AAAANEW evaluation-only"
      ];
    }
  ];
  profileChanged = evaluate [ { environment.profiles.development.variables.EDITOR = "editor"; } ];
  accountModule = {
    accounts = {
      editor = {
        uid = 1001;
        gid = 1001;
        home = "/home/editor";
      };
      reader = {
        uid = 1002;
        gid = 1002;
        home = "/home/reader";
      };
    };
  };
  untrusted = evaluate [ accountModule ];
  trusted = evaluate [
    accountModule
    { accounts.editor.nixTrusted = true; }
  ];
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
  cmp ${trusted}/system-profile/etc/nns/passwd ${trusted}/etc/passwd
  cmp ${untrusted}/system-profile/etc/nns/passwd ${untrusted}/etc/passwd
  grep -Fx 'trusted-users = root @nix-trusted' ${trusted}/etc/nix/nix.conf
  grep -Fx 'nix-trusted:x:30000:editor' ${trusted}/etc/group
  grep -Fx 'nix-trusted:x:30000:' ${untrusted}/etc/group
  test "$(readlink -f ${trusted}/services/nix-daemon/run)" != \
    "$(readlink -f ${untrusted}/services/nix-daemon/run)"
  test "$(readlink -f ${trusted}/services/sshd/run)" = \
    "$(readlink -f ${untrusted}/services/sshd/run)"
  touch "$out"
''
