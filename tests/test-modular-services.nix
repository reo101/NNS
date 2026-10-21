{ pkgs }:
let
  lib = pkgs.lib;
  evaluateWith = extraModules: service: lib.evalModules {
    class = "nixOnDroid";
    specialArgs = { inherit pkgs; };
    modules = [
      ../nix/nix-on-droid.nix
      {
        options.build.linkProotStatic = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        config = {
          _module.freeformType = lib.types.lazyAttrsOf lib.types.anything;
          nns.enable = true;
          nix.package = pkgs.nix;
          nns.services.enable = true;
          nns.services.runit.example = service;
          user.home = "/data/data/com.termux.nix/files/home";
          user.userName = "nix";
          user.uid = 10578;
          user.gid = 10578;
          user.shell = "/system/bin/sh";
          build.installationDir = "/data/data/com.termux.nix/files";
          build.sessionInit = "/nix/etc";
          build.etc = "/nix/etc";
          home-manager.config = null;
          environment.packages = [ (pkgs.writeShellScriptBin "nix-on-droid" ''
            PROFILE_DIRECTORY="/nix/var/nix/profiles/nix-on-droid"
            printf '%s\\n' "$PROFILE_DIRECTORY"
          '') ];
          environment.path = "/nix/var/nix/profiles/profile";
          environment.binSh = "/system/bin/sh";
          environment.usrBinEnv = "/system/bin/env";
          environment.etcBackupExtension = "";
          terminal.font = null;
          terminal.colors = { };
          terminal.properties.fullscreen = "false";
        };
      }
    ] ++ extraModules;
  };
  evaluate = evaluateWith [ ];
  consumer = evaluateWith [{
    nns.systemManaged = true;
    nns.services.enable = lib.mkForce false;
  }] { nns.enable = false; };
  consumerHome = evaluateWith [{
    nns.systemManaged = true;
    nns.services.enable = lib.mkForce false;
    home-manager = lib.mkForce {
      config.home.activationPackage = "/nix/store/test-home-manager";
      useUserPackages = false;
      backupFileExtension = "backup";
    };
  }] { nns.enable = false; };
  valid = evaluate {
    imports = [
      ({ options, lib, ... }: {
        _class = "service";
        config = {
          process.argv = [ "/system/bin/sleep" "30" ];
        } // lib.optionalAttrs (options ? nns) {
          nns.startAt = "unlock";
        };
      })
    ];
    process.environment.EXAMPLE = "text with spaces";
    process.environment.REMOVE = null;
  };
  disabled = evaluate { nns.enable = false; };
  invalid = evaluate {
    process.argv = [ "/system/bin/sleep" "30" ];
    process.environment."BAD;KEY" = "value";
    configData."server.conf".text = "value";
  };
  consumerCommand = lib.findFirst (package: package.name == "nns-nix-on-droid") null consumer.config.environment.packages;
  errors = evaluation:
    map (item: item.message)
      (builtins.filter (item: !item.assertion) evaluation.config.assertions);
in
assert consumerCommand.drvPath != "";
assert errors consumer == [ ];
assert consumer.config.build.activation.syncNixSettings == "";
assert lib.hasInfix (builtins.unsafeDiscardStringContext "${pkgs.nix}/bin/nix") consumer.config.build.activationBefore.checkNixVersions;
assert !(valid.config.build.activationBefore ? checkNixVersions);
assert !(consumer.config.build.activation ? materializeServices);
assert lib.hasInfix "/nix/var/nix/profiles/per-user/nix/nix-on-droid" consumer.config.build.activationAfter.linkProfile;
assert lib.hasInfix "HOME_MANAGER_BACKUP_EXT=backup" consumerHome.config.build.activationAfter.homeManager;
assert lib.hasInfix "/nix/store/test-home-manager/activate" consumerHome.config.build.activationAfter.homeManager;
assert errors valid == [ ];
assert valid.config.warnings == [ ];
assert valid.config.nns.services.runit.example.nns.startAt == "unlock";
assert !valid.config.build.linkProotStatic;
assert lib.hasInfix "nns-run-example" valid.config.build.activation.materializeServices;
assert lib.hasInfix "nns-termux.properties" valid.config.build.activation.linkProperties;
assert errors disabled == [ ];
assert !(lib.hasInfix "nns-run-example" disabled.config.build.activation.materializeServices);
assert builtins.length (errors invalid) == 2;
true
