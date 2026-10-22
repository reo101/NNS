{ pkgs }:
let
  lib = pkgs.lib;
  evaluate = extraModules: lib.evalModules {
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
  consumer = evaluate [ ];
  consumerHome = evaluate [{
    home-manager = lib.mkForce {
      config.home.activationPackage = "/nix/store/test-home-manager";
      useUserPackages = false;
      backupFileExtension = "backup";
    };
  }];
  disabled = evaluate [{ nns.enable = lib.mkForce false; }];
  command = lib.findFirst (package: package.name == "nns-nix-on-droid") null consumer.config.environment.packages;
  rejects = definition: !(builtins.tryEval (builtins.deepSeq (lib.evalModules {
    class = "nixOnDroid";
    specialArgs = { inherit pkgs; };
    modules = [
      ../nix/nix-on-droid.nix
      {
        options.build = lib.mkOption { type = lib.types.attrs; default = { }; };
        options.environment.sessionVariables = lib.mkOption { type = lib.types.attrs; default = { }; };
        config.environment.packages = [ ];
      }
      definition
    ];
  }).config true)).success;
in
assert command.drvPath != "";
assert !(consumer.options.nns ? systemManaged);
assert !(consumer.options.nns ? services);
assert !(consumer.options.nns ? nix);
assert !(consumer.config.build.activation ? syncNixSettings);
assert !(consumer.config.build.activation ? materializeServices);
assert lib.hasInfix (builtins.unsafeDiscardStringContext "${pkgs.nix}/bin/nix") consumer.config.build.activationBefore.checkNixVersions;
assert lib.hasInfix "/nix/var/nix/profiles/per-user/nix/nix-on-droid" consumer.config.build.activationAfter.linkProfile;
assert lib.hasInfix "HOME_MANAGER_BACKUP_EXT=backup" consumerHome.config.build.activationAfter.homeManager;
assert lib.hasInfix "/nix/store/test-home-manager/activate" consumerHome.config.build.activationAfter.homeManager;
assert !consumer.config.build.linkProotStatic;
assert lib.hasInfix "nns-termux.properties" consumer.config.build.activation.linkProperties;
assert disabled.config.build.linkProotStatic;
assert !(disabled.config.build ? activationBefore);
assert !(rejects { });
assert rejects { nns.systemManaged = true; };
assert rejects { nns.services.enable = true; };
assert rejects { nns.nix.settings.max-jobs = 1; };
true
