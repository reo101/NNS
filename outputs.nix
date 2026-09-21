inputs:
inputs.flake-parts.lib.mkFlake { inherit inputs; } (
  { lib, ... }:
  {
    systems = import inputs.systems.outPath;
    imports = [ inputs.flake-file.flakeModules.default ];
    flake-file = {
      nixConfig = {
        commit-lockfile-summary = "chore(flake): update `flake.lock`";
        extra-experimental-features = [ "pipe-operators" ];
      };
      inputs = {
        systems.url = "github:nix-systems/default";
        nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
        flake-file.url = "github:vic/flake-file";
        flake-parts = {
          url = "github:hercules-ci/flake-parts";
          inputs.nixpkgs-lib.follows = "nixpkgs";
        };
      };
    };
    perSystem = { pkgs, system, ... }:
      let
        sources = pkgs.callPackage ./kernel/sources.nix { };
        clang = pkgs.callPackage ./kernel/clang.nix { inherit sources; };
        kernel = pkgs.callPackage ./kernel { inherit sources clang; };
        launcher = pkgs.callPackage ./nix/launcher.nix { };
        hostLauncher = launcher.override {
          target = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl";
        };
        androidPkgs = import inputs.nixpkgs {
          localSystem = system;
          crossSystem = lib.systems.examples.aarch64-android-prebuilt;
          # Google's prebuilt NDK and its SDK packaging are marked unfree.
          config.allowUnfree = true;
        };
        dns = pkgs.callPackage ./nix/dns.nix {
          androidToolchain = androidPkgs.stdenv.cc.cc;
        };
        module = pkgs.callPackage ./nix/module.nix { inherit launcher dns; };
        emacs = pkgs.callPackage ./nix/emacs.nix { };
        usernsTest = pkgs.writeShellApplication {
          name = "nns-test-userns";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${./tests/test-userns.py} ${hostLauncher}/bin/nix-enter "$@"
          '';
        };
        emacsTest = pkgs.writeShellApplication {
          name = "nns-test-emacs";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${./tests/test-emacs.py} ${hostLauncher}/bin/nix-enter \
              ${pkgs.emacs-nox}/bin/emacs ${emacs}/share/emacs/site-lisp \
              ${./tests/nns-integration-test.el}
          '';
        };
        repacker = pkgs.writeShellApplication {
          name = "nns-repack-boot";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${./kernel/repack-boot.py} --manifest ${./kernel/avb.json} "$@"
          '';
        };
        bundle = pkgs.runCommand "nns-cheetah" { } ''
          mkdir -p "$out/bin"
          ln -s ${kernel} "$out/kernel"
          ln -s ${sources.sukisuManager} "$out/SukiSU-manager.apk"
          ln -s ${module}/nns-module.zip "$out/nns-module.zip"
          ln -s ${module}/module "$out/module"
          ln -s ${emacs}/nns-emacs.zip "$out/nns-emacs.zip"
          ln -s ${emacs}/share/emacs/site-lisp "$out/emacs-lisp"
          ln -s ${repacker}/bin/nns-repack-boot "$out/bin/nns-repack-boot"
        '';
      in
      {
        packages = {
          nns-module = module;
          sukisu-manager = sources.sukisuManager;
          nix-enter = launcher;
          nns-dns = dns;
          emacs-integration = emacs;
          repack-boot = repacker;
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          nix-enter-host = hostLauncher;
          test-userns = usernsTest;
          test-emacs = emacsTest;
        } // lib.optionalAttrs (system == "x86_64-linux") {
          kernel-cheetah = kernel;
          clang-cheetah = clang;
          cheetah = bundle;
          default = bundle;
        };
        checks = {
          nns-dns = dns;
          nns-module = module;
          emacs-integration = emacs;
          repack-boot = pkgs.runCommand "check-repack-boot" {
            nativeBuildInputs = [ pkgs.python3 ];
          } ''
            python3 ${./tests/test-repack.py} ${./kernel/repack-boot.py}
            touch "$out"
          '';
        } // lib.optionalAttrs (system == "x86_64-linux") {
          kernel-cheetah = kernel;
        };
        devShells = {
          default = pkgs.mkShell { packages = [ pkgs.android-tools pkgs.zig ]; };
        } // lib.optionalAttrs (system == "x86_64-linux") {
          kernel-cheetah = pkgs.mkShell {
            inputsFrom = [ kernel ];
            packages = [ pkgs.sccache ];
            shellHook = ''
              export SCCACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/sccache"
            '';
          };
        };
        formatter = pkgs.nixfmt;
      };
  }
)
