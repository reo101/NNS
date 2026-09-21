{ lib, stdenvNoCC, zig, python3, androidToolchain }:
stdenvNoCC.mkDerivation {
  pname = "nns-dns";
  version = "3.0.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../module/src/dns-wire.zig
      ../module/src/dns-bridge.zig
      ../module/src/dns-resolver.zig
      ../tests/test-dns.py
    ];
  };
  nativeBuildInputs = [ zig python3 ];
  dontConfigure = true;
  dontFixup = true; # Preserve /system/bin/linker64 and the libc-neutral preload.
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build -Doptimize=ReleaseSmall \
      -Dandroid-sysroot=${androidToolchain}/toolchain/sysroot --prefix "$out"
  '';
  doCheck = true;
  checkPhase = ''
    zig build test
  '';
  dontInstall = true; # zig build installs both artifacts into the prefix.
  meta = {
    description = "Zig getaddrinfo bridge to Android's Bionic resolver";
    platforms = lib.platforms.linux;
  };
}
