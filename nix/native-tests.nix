{ pkgs }:
let
  dependencies = pkgs.callPackage ./zig-dependencies.nix { };
  source = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.unions [
      ../build.zig
      ../build.zig.zon
      ../module/src/nix-enter.zig
      ../module/src/dns-bridge.zig
      ../module/src/dns-wire.zig
      ../integrations/shizuku/rish-terminal.zig
      ../integrations/shizuku/rish-terminal.h
      ../experiments/activation/service-control.zig
      ../experiments/activation/service-control.h
      ../tests/test-dns.py
      ../tests/test-rish-terminal.py
      ../experiments/activation/test-service-control.py
    ];
  };
in
pkgs.runCommand "check-nns-native"
  {
    nativeBuildInputs = [
      pkgs.zig
      pkgs.python3
      pkgs.runit
    ];
  }
  ''
    cp -r ${source} source
    chmod -R u+w source
    cd source
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build test --system ${dependencies}
    touch "$out"
  ''
