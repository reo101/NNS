# The sshd feature module: the supervised service is declared through the
# generic nns.services machinery, the option types are lifted from the
# stock NixOS sshd module, the invariants are forced in the settings
# apply (with a warning for user-set managed keys), and the materialization
# is spliced into the materializeServices activation step. Uses the same
# mock identity as test-modular-services.nix, plus nixos's assertions
# module (the option the real NoD eval enforces and the feature relies on).
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
  overridden = evaluate {
    nns.services.sshd.settings.SetEnv = "FOO=bar";
    nns.services.sshd.settings.PermitTTY = true;
    nns.services.sshd.settings.Ciphers = [ "chacha20-poly1305@openssh.com" ];
  };
in
assert errors enabled == [ ];
assert enabled.config.nns.services.sessionPath == "/data/nix/var/nns/bin:/nix/var/nix/profiles/system-profile/bin:/data/data/com.termux.nix/files/home/.nix-profile/bin:/system/bin:/system/xbin";
assert enabled.config.nns.services.sshd.ports == [ 8022 ];
# The stolen NixOS types: settings is the freeform sshd_config submodule.
assert !enabled.config.nns.services.sshd.settings.PasswordAuthentication;
assert enabled.config.nns.services.sshd.settings.PermitRootLogin == "no";
# Invariants forced in apply, invariants render into the config file.
assert enabled.config.nns.services.sshd.settings.PermitUserEnvironment;
assert !enabled.config.nns.services.sshd.settings.StrictModes;
assert lib.hasInfix "nns-sshd-wrapper" (lib.elemAt enabled.config.nns.services.runit.sshd.process.argv 0);
let
  sshdConfig = enabled.config.nns.services.sshd.settings;
in
assert lib.hasInfix "nns-sshd-wrapper" (lib.elemAt enabled.config.nns.services.runit.sshd.process.argv 0);
assert sshdConfig.PermitUserEnvironment == true;
assert sshdConfig.StrictModes == false;
assert sshdConfig.UsePAM == false;
assert sshdConfig.SetEnv == "NIX_REMOTE=daemon";
assert sshdConfig.PasswordAuthentication == false;
assert sshdConfig.PermitRootLogin == "no";
assert sshdConfig.AuthorizedKeysFile
  == [ "/data/nix/var/sshd/authorized_keys" "/data/data/com.termux.nix/files/home/.ssh/authorized_keys" ];
assert lib.hasInfix "nns-sshd_config" enabled.config.build.activation.materializeServices;
assert lib.hasInfix "nns-ssh-environment" enabled.config.build.activation.materializeServices;
assert errors disabled == [ ];
assert !(disabled.config.nns.services.runit ? sshd);
assert !(lib.hasInfix "nns-sshd_config" disabled.config.build.activation.materializeServices);
# Managed keys are overridden (SetEnv forced to the daemon value, traced
# as an evaluation warning); plain keys pass through.
assert overridden.config.nns.services.sshd.settings.SetEnv == "NIX_REMOTE=daemon";
assert overridden.config.nns.services.sshd.settings.PermitTTY == true;
assert overridden.config.nns.services.sshd.settings.Ciphers
  == [ "chacha20-poly1305@openssh.com" ];
true
