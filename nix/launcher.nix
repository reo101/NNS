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
  pname = "nix-enter-${target}";
  version = "3.2.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../module/src/nix-enter.zig
      ../module/src/syscall-error.zig
    ];
  };
  dontConfigure = true;
  dontFixup = true;
  nativeBuildInputs = [ zig ];
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build nix-enter --system ${dependencies} -Dtarget=${target} -Doptimize=small --prefix "$PWD/result"
  '';
  installPhase = ''
    install -Dm755 result/bin/nix-enter "$out/bin/nix-enter"
  '';
  meta = {
    mainProgram = "nix-enter";
    description = "Static identity-preserving user/mount namespace launcher for canonical /nix";
  };
}
