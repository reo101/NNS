{
  lib,
  pkgs,
  stdenvNoCC,
  zig,
  callPackage,
  target ? "aarch64-linux-musl",
}:
let
  dependencies = callPackage ./zig-dependencies.nix { };
  androidPkgs = import pkgs.path {
    localSystem = pkgs.stdenv.buildPlatform.system;
    crossSystem = lib.systems.examples.aarch64-android-prebuilt;
    config.allowUnfree = true;
  };
in
stdenvNoCC.mkDerivation {
  pname = "nns-native-${target}";
  version = "3.2.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../module/src/nix-enter.zig
      ../module/src/dns-bridge.zig
      ../module/src/dns-wire.zig
      ../module/src/dns-resolver.zig
      ../module/src/dns-resolver.h
      ../integrations/shizuku/rish-terminal.zig
      ../integrations/shizuku/rish-terminal.h
      ../experiments/activation/service-control.zig
      ../experiments/activation/service-control.h
    ];
  };
  nativeBuildInputs = [ zig ];
  dontConfigure = true;
  dontFixup = true;
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build all --system ${dependencies} -Dtarget=${target} -Doptimize=small \
      -Dandroid-sysroot=${androidPkgs.stdenv.cc.cc}/toolchain/sysroot --prefix "$PWD/result"
  '';
  installPhase = ''
    mkdir -p "$out"
    cp -r result/. "$out/"
  '';
}
