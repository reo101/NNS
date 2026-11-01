{
  lib,
  stdenvNoCC,
  zig,
  callPackage,
  target ? "aarch64-linux-musl",
}:
let
  dependencies = callPackage ./zig-dependencies.nix { };
in
stdenvNoCC.mkDerivation {
  pname = "nns-mount-${target}";
  version = "1";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../integrations/rom/nns-mount.c
      ../integrations/rom/nns-backing.c
      ../integrations/rom/nns-backing.h
      ../tests/rom-prepare-backing.c
      ../tests/rom-mount-race.c
    ];
  };
  outputs = [
    "out"
    "tests"
  ];
  dontConfigure = true;
  dontFixup = true;
  nativeBuildInputs = [ zig ];
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build mount mount-fixtures --system ${dependencies} -Dtarget=${target} -Doptimize=small --prefix "$PWD/result"
  '';
  installPhase = ''
    install -Dm755 result/bin/nns-mount "$out/bin/nns-mount"
    install -Dm755 result/bin/nns-prepare-backing "$tests/bin/nns-prepare-backing"
    install -Dm755 result/bin/nns-mount-race "$tests/bin/nns-mount-race"
  '';
  meta = {
    mainProgram = "nns-mount";
    description = "Idempotent Android init bind mount for the canonical Nix store";
    platforms = lib.platforms.linux;
  };
}
