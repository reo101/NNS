{
  pkgs,
  storage,
}:
storage.overrideAttrs (old: {
  pname = "nns-storage-throughput";
  postPatch = (old.postPatch or "") + ''
    mkdir -p benchmarks/storage-backends
    cp ${./throughput-probe.zig} benchmarks/storage-backends/throughput-probe.zig
    cp ${./bench-mount.zig} benchmarks/storage-backends/bench-mount.zig
  '';
  buildPhase = builtins.replaceStrings [ "zig build storage " ] [ "zig build storage-throughput-fixture " ] old.buildPhase;
  installPhase = ''
    install -Dm755 result/bin/nns-storage-throughput "$out/bin/nns-storage-throughput"
    install -Dm755 result/bin/nns-storage-bench-mount "$out/bin/nns-storage-bench-mount"
  '';
})
