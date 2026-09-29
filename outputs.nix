inputs:
inputs.flake-parts.lib.mkFlake { inherit inputs; } (
  { lib, ... }:
  {
    systems = import inputs.systems.outPath;
    imports = [ inputs.flake-file.flakeModules.default ];
    # A Nix-on-Droid module (class `nixOnDroid`) that replaces proot sessions
    # with the NNS launcher; pass it into `lib.nixOnDroidConfiguration`.
    flake.nixOnDroidModules.nns = import ./nix/nix-on-droid.nix;
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
        policy = pkgs.callPackage ./nix/sepolicy.nix { };
        policyCandidates = pkgs.callPackage ./nix/sepolicy-candidates.nix { };
        module = pkgs.callPackage ./nix/module.nix { inherit launcher dns policy; };
        androidTestPkgs = import inputs.nixpkgs {
          inherit system;
          config = { allowUnfree = true; android_sdk.accept_license = true; };
        };
        androidTestSdk = (androidTestPkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "35" ];
          buildToolsVersions = [ "35.0.0" ];
          abiVersions = [ "x86_64" ];
          systemImageTypes = [ "google_apis" ];
          includeSystemImages = true;
          includeEmulator = true;
          includeNDK = false;
        }).androidsdk;
        stockAndroidKernel = pkgs.runCommandLocal "android35-stock-kernel" { allowedReferences = [ ]; } ''
          cp ${androidTestSdk}/libexec/android-sdk/system-images/android-35/google_apis/x86_64/kernel-ranchu "$out"
        '';
        androidTestKernel = pkgs.callPackage ./nix/android-test-kernel.nix {
          inherit sources;
          stockKernel = stockAndroidKernel;
        };
        dnsX86 = dns.override { arch = "x86_64"; };
        moduleX86 = module.override { launcher = hostLauncher; dns = dnsX86; arch = "x64"; };
        androidTest = import ./nix/android-vm-test.nix {
          inherit pkgs lib sources;
          androidSdk = androidTestSdk;
          kernel = androidTestKernel;
          module = moduleX86;
        };
        emacs = pkgs.callPackage ./nix/emacs.nix { };
        nixOnDroidModule = import ./nix/nix-on-droid.nix;
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
          nns-sepolicy = policy;
          nns-sepolicy-candidates = policyCandidates;
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
          kernel-android-test = androidTestKernel;
          android-test-sdk = androidTestSdk;
          nns-module-x86_64 = moduleX86;
          test-android = androidTest.driver;
          android-vm-test = androidTest;
          android-test-apk = pkgs.callPackage ./nix/android-test-apk.nix { androidSdk = androidTestSdk; };
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
