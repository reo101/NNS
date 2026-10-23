inputs:
inputs.flake-parts.lib.mkFlake { inherit inputs; } (
  { lib, inputs, ... }:
  {
    systems = import inputs.systems.outPath;
    imports = [
      inputs.flake-file.flakeModules.default
      # Device specializations; the base flake depends on none of them.
      ./specialized/cheetah.nix
    ];
    # A Nix-on-Droid module (class `nixOnDroid`) that replaces proot sessions
    # with the NNS launcher; pass it into `lib.nixOnDroidConfiguration`.
    flake.nixOnDroidModules.nns = import ./nix/nix-on-droid.nix;
    flake.lib.nnsSystem = import ./nix/nns-system.nix { nixpkgs = inputs.nixpkgs; };
    flake.lib.evalPortableServices = import ./nix/service-backends;
    flake.nnsModules.default = import ./nix/nns-system/module.nix;
    # Data shared with consumers: the accepted binary caches, rendered into
    # the NixOS substituters module and the phone's staged nix.conf alike.
    flake.nns.caches = import ./nix/caches.nix;
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
        # nix/module.nix has no uid/gid/appId defaults: every build names them.
        # Device specializations call this with their own values (see
        # specialized/).
        mkModule = { arch ? "arm64", launcher, dns, rish, appUid, appGid, appId }:
          pkgs.callPackage ./nix/module.nix { inherit arch appUid appGid appId launcher dns rish policy; };
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
        # Mock identity for the test module: no real device is involved.
        moduleX86 = mkModule {
          launcher = hostLauncher;
          dns = dns.override { arch = "x86_64"; };
          rish = rish.override { arch = "x86_64"; };
          arch = "x64";
          appUid = 12345;
          appGid = 12345;
          appId = "com.example.nns";
        };
        androidTest = import ./nix/android-vm-test.nix {
          inherit pkgs lib sources;
          androidSdk = androidTestSdk;
          kernel = androidTestKernel;
          module = moduleX86;
        };
        emacs = pkgs.callPackage ./nix/emacs.nix { };
        avfClient = pkgs.callPackage ./nix/avf-client.nix { androidSdk = avfClientSdk; };
        # NixOS guest payload for AVF: evaluated natively for aarch64, so
        # building needs an aarch64 builder or cache hits.
        avfNixosPayload = import ./nix/avf-guest.nix { inherit lib; nixpkgs = inputs.nixpkgs; };
        avfVirtiofsd = (import inputs.nixpkgs { system = "aarch64-linux"; }).virtiofsd;
        usernsTest = pkgs.writeShellApplication {
          name = "nns-test-userns";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${./tests/test-userns.py} ${lib.getExe hostLauncher} "$@"
          '';
        };
        emacsTest = pkgs.writeShellApplication {
          name = "nns-test-emacs";
          runtimeInputs = [ pkgs.python3 pkgs.nix pkgs.coreutils ];
          text = ''
            exec python3 ${./tests/test-emacs.py} ${lib.getExe hostLauncher} \
              ${pkgs.emacs-nox}/bin/emacs ${emacs}/share/emacs/site-lisp \
              ${./tests/nns-integration-test.el}
          '';
        };
        serviceTestFixture = import ./tests/nns-service-fixture.nix { inherit pkgs; };
        serviceTests = pkgs.writeShellApplication {
          name = "nns-test-services";
          runtimeInputs = [ pkgs.python3 pkgs.util-linux pkgs.coreutils ];
          text = ''
            exec python3 ${./tests/test-nns-services.py} ${lib.getExe hostLauncher} ${serviceTestFixture}
          '';
        };
        serviceManagerTests = import ./tests/nns-service-managers { inherit pkgs; };
        systemTestSource = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./tests/test-nns-activation.py
            ./tests/test-nns-boot.py
            ./nix/nns-system/activate.sh
            ./nix/nns-system/service-runtime.sh
            ./module/system-generation.sh
            ./module/stage-android-runtime.sh
          ];
        };
        activationTest = pkgs.writeShellApplication {
          name = "nns-test-activation";
          runtimeInputs = [ pkgs.python3 pkgs.bash pkgs.util-linux pkgs.coreutils pkgs.findutils pkgs.gnugrep ];
          text = ''exec python3 ${systemTestSource}/tests/test-nns-activation.py "$@"'';
        };
        bootTest = pkgs.writeShellApplication {
          name = "nns-test-boot";
          runtimeInputs = [ pkgs.python3 pkgs.util-linux pkgs.coreutils pkgs.openssh pkgs.mksh ];
          text = ''exec python3 ${systemTestSource}/tests/test-nns-boot.py ${lib.getExe hostLauncher} "$@"'';
        };
      in
      {
        # Shared derivations for the device specializations.
        _module.args.nnsShared = { inherit mkModule launcher dns rish sources clang; };
        packages = {
          nns-sepolicy = policy;
          nns-sepolicy-candidates = policyCandidates;
          nix-enter = launcher;
          nns-dns = dns;
          emacs-integration = emacs;
        } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          nix-enter-host = hostLauncher;
          test-userns = usernsTest;
          test-emacs = emacsTest;
          test-nns-activation = activationTest;
          test-nns-services = serviceTests;
          test-nns-service-managers = serviceManagerTests.tests;
          test-nns-boot = bootTest;
        } // lib.optionalAttrs (system == "x86_64-linux") {
          kernel-android-test = androidTestKernel;
          android-test-sdk = androidTestSdk;
          nns-module-x86_64 = moduleX86;
          test-android = androidTest.driver;
          android-vm-test = androidTest;
          android-test-apk = pkgs.callPackage ./nix/android-test-apk.nix { androidSdk = androidTestSdk; };
          avf-client = avfClient;
          avf-probe-initramfs = pkgs.callPackage ./nix/avf-probe-initramfs.nix { };
          # NixOS guest payload for AVF; the deploy script runs host-side
          # (adb + ssh + nix copy).
          nns-avf-nixos-payload = avfNixosPayload;
          nns-avf-virtiofsd = avfVirtiofsd;
          nns-avf-deploy-guest = pkgs.callPackage ./nix/avf-guest-deploy.nix {
            payload = avfNixosPayload;
            client = avfClient;
            virtiofsd = avfVirtiofsd;
            runner = ./integrations/avf/run-guest.sh;
          };
        };
        checks = {
          nns-dns = dns;
          nns-module = moduleX86;
          nns-rish = import ./tests/test-rish.nix { inherit pkgs; };
          nns-system =
            assert import ./tests/test-nns-system.nix { inherit pkgs; };
            pkgs.runCommand "check-nns-system" { } "touch $out";
          nns-generation = ((import ./nix/nns-system.nix { nixpkgs = inputs.nixpkgs; }) {
            inherit pkgs system;
            modules = [{
              environment.profiles.development.packages = [ pkgs.git pkgs.bashInteractive ];
              services.openssh.enable = true;
              accounts.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAATEST evaluation-only" ];
            }];
          }).config.system.build.toplevel;
          nns-service-managers = serviceManagerTests.evaluation;
          nns-reconfiguration = import ./tests/test-nns-reconfiguration.nix { inherit pkgs; };
          nns-nix-versions = import ./tests/test-nns-nix-versions.nix { inherit pkgs; };
          avf-client-timeout = pkgs.runCommand "check-avf-client-timeout" {
            nativeBuildInputs = [ pkgs.python3 pkgs.kotlin pkgs.jdk17 ];
          } ''
            python3 ${./tests/test-avf-timeout.py} ${./integrations/avf/VirtualMachineClient.kt}
            touch "$out"
          '';
          nns-nod-consumer = import ./tests/test-nod-consumer.nix { inherit pkgs; };
          emacs-integration = emacs;
        };
        devShells.default = pkgs.mkShell { packages = [ pkgs.android-tools pkgs.zig ]; };
        formatter = pkgs.nixfmt;
      };
  }
)
