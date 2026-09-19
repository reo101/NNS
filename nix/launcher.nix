{ lib, stdenvNoCC, zig, target ? "aarch64-linux-musl" }:
stdenvNoCC.mkDerivation {
  pname = "nix-enter-${target}";
  version = "3.0.0";
  src = ../module/src/nix-enter.zig;
  dontUnpack = true;
  dontConfigure = true;
  dontFixup = true;
  nativeBuildInputs = [ zig ];
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build-exe "$src" -target ${target} -O ReleaseSmall -fstrip -femit-bin=nix-enter
  '';
  installPhase = ''
    install -Dm755 nix-enter "$out/bin/nix-enter"
  '';
  meta.description = "Static identity-preserving user/mount namespace launcher for canonical /nix";
}
