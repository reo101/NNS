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
      services.openssh.enable = true;
      accounts.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAROOT root" ];
      system.directories.shared = {
        path = "/data/nns-test/shared";
        owner = "emacs";
        group = "root";
        mode = "2710";
      };
      services.runit.initialize = {
        nns.type = "oneshot";
        process.argv = [ "/system/bin/true" ];
      };
      services.runit.example = {
        process.argv = [
          "${pkgs.coreutils}/bin/sleep"
          "infinity"
        ];
        process.environment.EXAMPLE = "value with spaces";
        nns.startAt = "unlock";
        nns.after = [ "initialize" ];
      };
    }
  ];
  selectedNix = evaluate [ { nix.package = pkgs.nixVersions.latest; } ];
  trustedAccount = evaluate [
    {
      accounts.editor = {
        uid = 1002;
        gid = 1002;
        home = "/home/editor";
        nixTrusted = true;
      };
    }
  ];
  rejects =
    module: !(builtins.tryEval (evaluate [ module ]).config.system.build.toplevel.drvPath).success;
in
assert valid.config.system.build.toplevel.type == "derivation";
assert valid.config.accounts.root.uid == 0;
assert !valid.config.accounts.emacs.nixTrusted;
assert trustedAccount.config.accounts.editor.nixTrusted;
assert
  valid.config.nix.settings.trusted-users == [
    "root"
    "@nix-trusted"
  ];
assert valid.config.nix.package == pkgs.nix;
assert
  selectedNix.config.services.runit.nix-daemon.process.argv == [
    "${pkgs.nixVersions.latest}/bin/nix-daemon"
  ];
assert valid.config.accounts.root.openssh.authorizedKeys.keys == [ "ssh-ed25519 AAAAROOT root" ];
assert valid.config.services.runit.initialize.nns.type == "oneshot";
assert valid.config.services.runit.example.nns.type == "longrun";
assert valid.config.services.runit.directory-shared.nns.type == "oneshot";
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
assert rejects {
  accounts.nix-trusted = {
    uid = 1002;
    gid = 1002;
    home = "/home/reserved";
  };
};
assert rejects {
  accounts.invalid = {
    uid = 1002;
    gid = 30000;
    home = "/home/invalid";
  };
};
assert rejects { services.runit.invalid.process.argv = [ ]; };
assert rejects {
  system.directories.invalid = {
    path = "/tmp/../bad";
  };
};
assert rejects {
  system.directories.invalid = {
    path = "/tmp/invalid";
    owner = "unknown";
  };
};
assert rejects {
  system.directories.invalid = {
    path = "/tmp/invalid";
    mode = "8888";
  };
};
assert rejects { accounts.root.openssh.authorizedKeys.runtimeFiles = [ "/app/authorized_keys" ]; };
assert rejects { _class = "nixos"; };
true
