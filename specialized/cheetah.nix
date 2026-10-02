# Cheetah (Pixel 7 Pro) specialization: the device's module instance, the
# boot bundle, the phone-platform system profile and its deploy app. The
# base flake depends on none of this; other devices create their own
# module under specialized/ and import it alongside.
#
# Device identity lives here and only here: appUid/appGid/appId and the
# ssh endpoint.
{
  lib,
  inputs,
  ...
}:
{
  perSystem = { pkgs, system, nnsShared, ... }:
    let
      inherit (nnsShared) mkModule launcher dns rish sources clang;
      # The phone platform, for the system profile and its deploy app.
      phonePkgs = import inputs.nixpkgs {
        localSystem = system;
        crossSystem = lib.systems.examples.aarch64-multiplatform;
      };
      moduleCheetah = mkModule {
        inherit launcher dns rish;
        appUid = 10578;
        appGid = 10578;
        appId = "com.termux.nix";
      };
      kernel = pkgs.callPackage ../kernel { inherit sources clang; };
      repacker = pkgs.writeShellApplication {
        name = "nns-repack-boot";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec python3 ${../kernel/repack-boot.py} --manifest ${../kernel/avb.json} "$@"
        '';
      };
      emacs = pkgs.callPackage ../nix/emacs.nix { };
      bundle = pkgs.runCommand "nns-cheetah" { } ''
        mkdir -p "$out/bin"
        ln -s ${kernel} "$out/kernel"
        ln -s ${sources.sukisuManager} "$out/SukiSU-manager.apk"
        ln -s ${moduleCheetah}/nns-module.zip "$out/nns-module.zip"
        ln -s ${moduleCheetah}/module "$out/module"
        ln -s ${emacs}/nns-emacs.zip "$out/nns-emacs.zip"
        ln -s ${emacs}/share/emacs/site-lisp "$out/emacs-lisp"
        ln -s ${repacker}/bin/nns-repack-boot "$out/bin/nns-repack-boot"
      '';
      systemProfile = pkgs.callPackage ../nix/system-profile.nix { inherit phonePkgs; };
      deploySystemProfile = pkgs.callPackage ../nix/system-profile-deploy.nix {
        inherit systemProfile;
        sshUser = "nix-on-droid";
        sshHost = "192.168.1.217";
        sshPort = 8022;
      };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages = {
        nns-module-cheetah = moduleCheetah;
        kernel-cheetah = kernel;
        clang-cheetah = clang;
        sukisu-manager = sources.sukisuManager;
        repack-boot = repacker;
        nns-system-profile = systemProfile;
        cheetah = bundle;
        default = bundle;
      };
      checks.kernel-cheetah = kernel;
      devShells.kernel-cheetah = pkgs.mkShell {
        inputsFrom = [ kernel ];
        packages = [ pkgs.sccache ];
        shellHook = ''
          export SCCACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/sccache"
        '';
      };
      apps.deploy-system-profile.program = lib.getExe deploySystemProfile;
    };
}
