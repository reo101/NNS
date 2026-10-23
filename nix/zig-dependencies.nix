{
  lib,
  zig,
  runCommand,
  gnutar,
  gzip,
}:
let
  archives = zig.fetchDeps {
    pname = "nns";
    version = "3.2.0";
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../build.zig
        ../build.zig.zon
      ];
    };
    hash = "sha256-aiE65pHswSG8K5MYtoNiSv0vwWB3A+q7tt2giqurCCg=";
  };
in
# Zig 0.17 stores compressed archives globally; --system needs unpacked packages.
runCommand "nns-zig-dependencies"
  {
    nativeBuildInputs = [
      gnutar
      gzip
    ];
  }
  ''
    mkdir -p "$out"
    for archive in ${archives}/*.tar.gz; do
      tar -xzf "$archive" -C "$out"
    done
  ''
