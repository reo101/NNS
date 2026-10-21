{ pkgs }:
let
  evaluate =
    modules:
    import ../nix/nns-system.nix { nixpkgs = pkgs.path; } {
      system = pkgs.stdenv.hostPlatform.system;
      inherit pkgs modules;
    };
  valid = evaluate [
    {
      environment.profiles.development = {
        packages = [
          pkgs.git
          pkgs.bashInteractive
        ];
        variables.EDITOR = "emacsclient -t";
      };
      accounts.emacs = {
        uid = 1001;
        gid = 1001;
        home = "/home/emacs";
      };
      services.openssh = {
        enable = true;
        authorizedRootKeys = [ "ssh-ed25519 AAAAROOT root" ];
      };
      services.runit.example = {
        process.argv = [
          "${pkgs.coreutils}/bin/sleep"
          "infinity"
        ];
        process.environment.EXAMPLE = "value with spaces";
        nns.startAt = "unlock";
      };
    }
  ];
  selectedNix = evaluate [ { nix.package = pkgs.nixVersions.latest; } ];
  rejects =
    module: !(builtins.tryEval (evaluate [ module ]).config.system.build.toplevel.drvPath).success;
in
assert valid.config.system.build.toplevel.type == "derivation";
assert valid.config.accounts.root.uid == 0;
assert valid.config.nix.package == pkgs.nix;
assert selectedNix.config.services.runit.nix-daemon.process.argv == [
  "${pkgs.nixVersions.latest}/bin/nix-daemon"
];
assert valid.config.services.openssh.authorizedRootKeys == [ "ssh-ed25519 AAAAROOT root" ];
assert valid.config.environment.profiles.development.variables.EDITOR == "emacsclient -t";
assert valid.config.services.runit.sshd.process.argv != [ ];
assert valid.config.services.runit.nix-daemon.process.environment.NIX_REMOTE == "local";
assert rejects { environment.profiles.development.variables.HOME = "/tmp"; };
assert rejects { environment.profiles.nns-system.packages = [ ]; };
assert rejects { environment.profiles."invalid.name".packages = [ ]; };
assert rejects { environment.profiles.development-1-link.packages = [ ]; };
assert rejects {
  services.runit.invalid.process = {
    argv = [ "/system/bin/true" ];
    environment.PATH = "/app/bin";
  };
};
assert rejects { services.runit.invalid.process.argv = [ "/app/bin/command" ]; };
assert rejects {
  services.runit = {
    first = {
      process.argv = [ "/system/bin/true" ];
      nns.after = [ "second" ];
    };
    second = {
      process.argv = [ "/system/bin/true" ];
      nns.after = [ "first" ];
    };
  };
};
assert rejects { environment.profiles.development.variables."invalid-name" = "value"; };
assert rejects { services.openssh.enable = true; };
assert rejects {
  accounts.invalid = {
    uid = 0;
    gid = 1;
    home = "/tmp";
  };
};
assert rejects { services.runit.invalid.process.argv = [ ]; };
assert rejects { _class = "nixos"; };
true
