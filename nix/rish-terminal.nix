{
  lib,
  pkgs,
  stdenvNoCC,
  zig,
  callPackage,
  arch ? "aarch64",
}:
let
  androidPkgs = import pkgs.path {
    localSystem = pkgs.stdenv.buildPlatform.system;
    crossSystem = lib.systems.examples.aarch64-android-prebuilt;
    config.allowUnfree = true;
  };
  toolchain = androidPkgs.stdenv.cc.cc;
  dependencies = callPackage ./zig-dependencies.nix { };
  source = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../integrations/shizuku/rish-terminal.zig
      ../integrations/shizuku/rish-terminal.h
      ../tests/test-rish-terminal.py
    ];
  };
in
stdenvNoCC.mkDerivation {
  pname = "nns-rish-terminal-${arch}";
  version = "1";
  src = source;
  nativeBuildInputs = [ zig ];
  dontConfigure = true;
  dontFixup = true;
  allowedReferences = [ ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build rish-terminal --system ${dependencies} -Doptimize=small -Darch=${arch} \
      -Dandroid-sysroot=${toolchain}/toolchain/sysroot --prefix "$PWD/result"
  '';
  installPhase = ''
    install -Dm755 result/bin/nns-rish-terminal "$out/bin/nns-rish-terminal"
  '';
  passthru.tests.native =
    pkgs.runCommand "check-nns-rish-terminal"
      {
        nativeBuildInputs = [
          zig
          pkgs.python3
        ];
      }
      ''
        cp -r ${source} source
        chmod -R u+w source
        cd source
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
        zig build test-rish-terminal --system ${dependencies}
        touch "$out"
      '';
  meta.license = lib.licenses.asl20;
}
