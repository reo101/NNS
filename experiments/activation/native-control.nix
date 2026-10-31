{ pkgs }:
let
  dependencies = pkgs.callPackage ../../nix/zig-dependencies.nix { };
  source = pkgs.lib.fileset.toSource {
    root = ../..;
    fileset = pkgs.lib.fileset.unions [
      ../../build.zig
      ../../build.zig.zon
      ./service-control.zig
      ../../module/src/syscall-error.zig
    ];
  };
in
pkgs.runCommand "nns-service-control"
  {
    nativeBuildInputs = [ pkgs.zig ];
    meta.mainProgram = "nns-service-control";
  }
  ''
    cp -r ${source} source
    chmod -R u+w source
    cd source
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build service-control --system ${dependencies} \
      -Dtarget=${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl -Doptimize=safe --prefix "$out"
  ''
