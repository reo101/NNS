{ lib, stdenvNoCC, zig, target ? "aarch64-linux-musl" }:
stdenvNoCC.mkDerivation {
  pname = "nix-enter-${target}";
  version = "3.2.0";
  src = ../module/src/nix-enter.zig;
  dontUnpack = true;
  dontFixup = true;
  nativeBuildInputs = [ zig ];
  allowedReferences = [ ];
  buildPhase = ''
    zig build-exe "$src" -target ${target} -O small -fstrip -femit-bin=nix-enter
  '';
  installPhase = ''
    install -Dm755 nix-enter "$out/bin/nix-enter"
  '';
  meta = {
    mainProgram = "nix-enter";
    description = "Static identity-preserving user/mount namespace launcher for canonical /nix";
  };
}
