{ pkgs }:
let
  lib = pkgs.lib;
  evaluate = service: lib.evalModules {
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
          nns.services.enable = true;
          nns.services.services.example = service;
          user.home = "/data/data/com.termux.nix/files/home";
          user.userName = "nix";
          user.uid = 10578;
          user.gid = 10578;
          user.shell = "/system/bin/sh";
          build.installationDir = "/data/data/com.termux.nix/files";
          build.sessionInit = "/nix/etc";
          build.etc = "/nix/etc";
          home-manager.config = null;
          environment.path = "/nix/var/nix/profiles/profile";
          environment.binSh = "/system/bin/sh";
          environment.usrBinEnv = "/system/bin/env";
          environment.etcBackupExtension = "";
          terminal.font = null;
          terminal.colors = { };
          terminal.properties.fullscreen = "false";
        };
      }
    ];
  };
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
  errors = evaluation:
    map (item: item.message)
      (builtins.filter (item: !item.assertion) evaluation.config.assertions);
in
assert errors valid == [ ];
assert valid.config.warnings == [ ];
assert valid.config.nns.services.services.example.nns.startAt == "unlock";
assert !valid.config.build.linkProotStatic;
assert lib.hasInfix "nns-run-example" valid.config.build.activation.materializeServices;
assert lib.hasInfix "nns-termux.properties" valid.config.build.activation.linkProperties;
assert errors disabled == [ ];
assert !(lib.hasInfix "nns-run-example" disabled.config.build.activation.materializeServices);
assert builtins.length (errors invalid) == 2;
true
