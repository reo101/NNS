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
        rish = pkgs.callPackage ./nix/rish.nix { };
        policyCandidates = pkgs.callPackage ./nix/sepolicy-candidates.nix { };
        # nix/module.nix has no uid/gid/appId defaults: every build names them
        # (mkModule without appUid/appGid/appId errors out). This is cheetah's
        # pair (meta.uid/meta.gid); other phones call mkModule with their
        # own.
        mkModule = { arch ? "arm64", launcher, dns, rish, appUid, appGid, appId }:
          pkgs.callPackage ./nix/module.nix { inherit arch appUid appGid appId launcher dns rish policy; };
        moduleCheetah = mkModule { inherit launcher dns rish; appUid = 10578; appGid = 10578; appId = "com.termux.nix"; };
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
        avfClientSdk = (androidTestPkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "35" ];
          buildToolsVersions = [ "35.0.0" ];
          includeSystemImages = false;
          includeEmulator = false;
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
        moduleX86 = mkModule { launcher = hostLauncher; dns = dnsX86; inherit rish; arch = "x64"; appUid = 10578; appGid = 10578; appId = "com.termux.nix"; };
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
            exec python3 ${./tests/test-userns.py} ${lib.getExe hostLauncher} "$@"
          '';
        };
        emacsTest = pkgs.writeShellApplication {
          name = "nns-test-emacs";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${./tests/test-emacs.py} ${lib.getExe hostLauncher} \
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
          ln -s ${moduleCheetah}/nns-module.zip "$out/nns-module.zip"
          ln -s ${moduleCheetah}/module "$out/module"
          ln -s ${emacs}/nns-emacs.zip "$out/nns-emacs.zip"
          ln -s ${emacs}/share/emacs/site-lisp "$out/emacs-lisp"
          ln -s ${repacker}/bin/nns-repack-boot "$out/bin/nns-repack-boot"
        '';
      in
      {
        packages = {
          # No unsupplied nns-module here: nix/module.nix requires appUid/
          # appGid, so every zip output names its host and callers with
          # other ids use module.override.
          nns-module-cheetah = moduleCheetah;
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
          avf-client = pkgs.callPackage ./nix/avf-client.nix { androidSdk = avfClientSdk; };
          avf-probe-initramfs = pkgs.callPackage ./nix/avf-probe-initramfs.nix { };
          clang-cheetah = clang;
          cheetah = bundle;
          default = bundle;
        };
        checks = {
          nns-dns = dns;
          nns-module = moduleCheetah;
          nns-modular-services =
            assert import ./tests/test-modular-services.nix { inherit pkgs; };
            pkgs.runCommand "check-nns-modular-services" { } "touch $out";
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
