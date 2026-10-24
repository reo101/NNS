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
      ../tests/android/fscrypt-policy.c
      ../tests/android/storage-execution.c
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
