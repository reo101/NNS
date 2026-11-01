{ pkgs, androidSdk, kernel, helper, apk, sources }:
let
  ksud = pkgs.runCommand "nns-test-ksud" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    unzip -p ${sources.sukisuManager} lib/x86_64/libksud.so > "$out"
    chmod +x "$out"
  '';
  probes = pkgs.callPackage ./native-probes.nix { target = "x86_64-linux-musl"; };
  fscryptPolicy = "${probes}/bin/fscrypt-policy";
  bindRemount = "${probes}/bin/bind-remount";
  specification = pkgs.writeText "nns-android-mount-specification.json" (builtins.toJSON {
    sdk = "${androidSdk}/libexec/android-sdk";
    kernel = "${kernel}/kernel-ranchu";
    helper = "${helper}/bin/nns-mount";
    apk = "${apk}/nns-probe.apk";
    inherit ksud fscryptPolicy bindRemount;
    integration = ../integrations/rom;
    java = "${pkgs.jdk17_headless}";
  });
in
pkgs.writeShellApplication {
  name = "nns-test-android-mount";
  runtimeInputs = [ pkgs.python3 pkgs.e2fsprogs.bin pkgs.android-tools pkgs.util-linux ];
  text = ''
    exec python3 ${../tests/android/mount-test.py} ${specification} "$@"
  '';
}
