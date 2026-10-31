{
  lib,
  stdenvNoCC,
  zig,
  pkgsCross,
  callPackage,
  target ? "aarch64-linux-musl",
}:
let
  headers =
    (if lib.hasPrefix "aarch64-" target then pkgsCross.aarch64-multiplatform else pkgsCross.gnu64)
    .linuxHeaders;
  dependencies = callPackage ./zig-dependencies.nix { };
in
stdenvNoCC.mkDerivation {
  pname = "nns-native-probes-${target}";
  version = "1";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../module/src/storage-linux.h
      ../module/src/syscall-error.zig
      ../tests/android/bind-remount.zig
      ../tests/android/fscrypt-policy.zig
      ../tests/android/storage-execution.zig
    ];
  };
  nativeBuildInputs = [ zig ];
  dontConfigure = true;
  dontFixup = true;
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build native-probes --system ${dependencies} -Dtarget=${target} -Doptimize=small \
      -Dlinux-headers=${headers}/include --prefix "$PWD/result"
  '';
  installPhase = ''
    mkdir -p "$out/bin"
    cp result/bin/* "$out/bin/"
  '';
}
