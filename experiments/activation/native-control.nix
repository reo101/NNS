{ pkgs }:

pkgs.runCommand "nns-service-control" {
  nativeBuildInputs = [ pkgs.zig ];
  meta.mainProgram = "nns-service-control";
} ''
  export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
  export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
  mkdir -p "$out/bin"
  zig translate-c -lc -target ${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl \
    ${./service-control.h} > service-control-c.zig
  zig build-exe -target ${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl \
    -O safe -lc --dep c -Mroot=${./service-control.zig} \
    -target ${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl -Mc=service-control-c.zig \
    -femit-bin="$out/bin/nns-service-control"
''
