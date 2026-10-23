{
  lib,
  stdenvNoCC,
  zig,
  python3,
  androidToolchain,
  callPackage,
  arch ? "aarch64",
}:
let
  dependencies = callPackage ./zig-dependencies.nix { };
in
stdenvNoCC.mkDerivation {
  pname = "nns-dns-${arch}";
  version = "3.0.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../module/src/dns-wire.zig
      ../module/src/dns-bridge.zig
      ../module/src/dns-resolver.zig
      ../module/src/dns-resolver.h
      ../tests/test-dns.py
    ];
  };
  nativeBuildInputs = [
    zig
    python3
  ];
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true; # Preserve /system/bin/linker64 and the libc-neutral preload.
  allowedReferences = [ ];
  doCheck = true;
  checkPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build test-dns --system ${dependencies}
  '';
  installPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build dns --system ${dependencies} -Doptimize=small -Darch=${arch} \
      -Dandroid-sysroot=${androidToolchain}/toolchain/sysroot --prefix "$out"
  '';
  meta = {
    description = "Zig getaddrinfo bridge to Android's Bionic resolver";
    platforms = lib.platforms.linux;
  };
}
