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
  pname = "nns-storage-${target}";
  version = "1";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../module/src/nns-storage.zig
      ../module/src/syscall-error.zig
      ../module/src/storage-linux.h
      ../integrations/module/storage/supervisor.zig
      ../integrations/module/storage/controller.zig
      ../tests/module-storage/handoff.zig
    ];
  };
  dontConfigure = true;
  dontFixup = true;
  nativeBuildInputs = [ zig ];
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build storage --system ${dependencies} -Dtarget=${target} -Doptimize=small \
      -Dlinux-headers=${headers}/include --prefix "$PWD/result"
  '';
  installPhase = ''
    install -Dm755 result/bin/nns-storage "$out/bin/nns-storage"
    install -Dm755 result/bin/nns-storage-supervisor "$out/bin/nns-storage-supervisor"
    install -Dm755 result/bin/nns-storage-module-controller "$out/bin/nns-storage-module-controller"
  '';
  meta = {
    mainProgram = "nns-storage";
    description = "Validated file-backed Btrfs mount for the Android Nix store";
    platforms = lib.platforms.linux;
  };
}
