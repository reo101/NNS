# The sshd feature module: the supervised service is declared through the
# generic nns.services machinery and its materialization is spliced into
# the materializeServices activation step. Uses the same mock identity as
# test-modular-services.nix, plus nixos's assertions module (the option the
# real NoD eval enforces and the feature relies on).
{ pkgs }:
let
  lib = pkgs.lib;
  sshdModule = import ../services/sshd.nix;
  evaluate = extraConfig:
    lib.evalModules {
      class = "nixOnDroid";
      specialArgs = { inherit pkgs; };
      modules = [
        (pkgs.path + "/nixos/modules/misc/assertions.nix")
        ../nix/nix-on-droid.nix
        sshdModule
        {
          options.build.linkProotStatic = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          config = {
            _module.freeformType = lib.types.lazyAttrsOf lib.types.anything;
            nns.enable = true;
            nns.services.enable = true;
            nns.services.sshd.enable = true;
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
        (if extraConfig == null then { } else extraConfig)
      ];
    };
  errors = evaluation:
    map (item: item.message)
      (builtins.filter (item: !item.assertion) evaluation.config.assertions);
  enabled = evaluate null;
  disabled = evaluate { nns.services.sshd.enable = lib.mkForce false; };
in
assert errors enabled == [ ];
assert enabled.config.nns.services.sessionPath == "/data/nix/var/nns/bin:/nix/var/nix/profiles/system-profile/bin:/data/data/com.termux.nix/files/home/.nix-profile/bin:/system/bin:/system/xbin";
assert lib.hasInfix "nns-sshd-wrapper" (lib.elemAt enabled.config.nns.services.services.sshd.process.argv 0);
assert lib.hasInfix "nns-sshd_config" enabled.config.build.activation.materializeServices;
assert lib.hasInfix "nns-ssh-environment" enabled.config.build.activation.materializeServices;
assert lib.hasInfix "nix-store" (lib.elemAt enabled.config.nns.services.services.sshd.process.argv 0) == false;
assert !enabled.config.nns.services.services.sshd ? nns || enabled.config.nns.services.services.sshd.nns.startAt == "boot";
assert errors disabled == [ ];
assert !(disabled.config.nns.services.services ? sshd);
assert !(lib.hasInfix "nns-sshd_config" disabled.config.build.activation.materializeServices);
true
