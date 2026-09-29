{ lib, stdenvNoCC, zig, python3, androidToolchain, arch ? "aarch64" }:
stdenvNoCC.mkDerivation {
  pname = "nns-dns-${arch}";
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
  dontBuild = true; # The Zig install phase builds both artifacts.
  dontFixup = true; # Preserve /system/bin/linker64 and the libc-neutral preload.
  allowedReferences = [ ];
  dontSetZigDefaultFlags = true; # The hook's host CPU and optimization flags do not apply.
  zigBuildFlags = [
    "-Doptimize=ReleaseSmall"
    "-Darch=${arch}"
    "-Dandroid-sysroot=${androidToolchain}/toolchain/sysroot"
  ];
  doCheck = true;
  meta = {
    description = "Zig getaddrinfo bridge to Android's Bionic resolver";
    platforms = lib.platforms.linux;
  };
}
