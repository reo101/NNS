{ lib, pkgs, stdenvNoCC, zig, arch ? "aarch64" }:
let
  androidPkgs = import pkgs.path {
    localSystem = pkgs.stdenv.buildPlatform.system;
    crossSystem = lib.systems.examples.aarch64-android-prebuilt;
    config.allowUnfree = true;
  };
  toolchain = androidPkgs.stdenv.cc.cc;
in
stdenvNoCC.mkDerivation {
  pname = "nns-rish-terminal-${arch}";
  version = "1";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../module/src/dns-wire.zig
      ../module/src/dns-bridge.zig
      ../module/src/dns-resolver.zig
      ../integrations/shizuku/rish-terminal.zig
    ];
  };
  nativeBuildInputs = [ zig ];
  dontConfigure = true;
  dontFixup = true;
  dontSetZigDefaultFlags = true;
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    zig build rish-terminal -Doptimize=ReleaseSmall -Darch=${arch} \
      -Dandroid-sysroot=${toolchain}/toolchain/sysroot --prefix "$PWD/result"
  '';
  installPhase = ''
    install -Dm755 result/bin/nns-rish-terminal "$out/bin/nns-rish-terminal"
  '';
  passthru.tests.native = pkgs.runCommand "check-nns-rish-terminal" {
    nativeBuildInputs = [ zig pkgs.python3 ];
  } ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    zig build-exe -lc -O Debug -target ${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl \
      ${../integrations/shizuku/rish-terminal.zig} -femit-bin=nns-rish-terminal
    python3 ${../tests/test-rish-terminal.py} "$PWD/nns-rish-terminal"
    touch "$out"
  '';
  meta.license = lib.licenses.asl20;
}
