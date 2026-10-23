{ fetchurl }:
let
  # Keep shell-level download clients consistent with the project policy.
  fetch = args: fetchurl (args // {
    curlOptsList = [ "-A" "OpenAI File Downloader, XaiImageApiFetch/1.0" ];
  });
in
{
  # Upstream sources and patches are fetched by content hash; only local
  # integration fixes live in kernel/patches.
  pantah = fetch {
    name = "pantah.tar.xz";
    url = "https://github.com/yapixel/gki-build-assets/releases/download/pantah-15260412/kernel-pantah-15260412.tar.xz";
    hash = "sha256-er8MbCyqFxbC0xPf602oVSPJ6DhmzJDH34fCAKrbO/8=";
  };
  clang = fetch {
    name = "clang.tar.xz";
    url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.6/clang+llvm-17.0.6-x86_64-linux-gnu-ubuntu-22.04.tar.xz";
    hash = "sha256-iE7mfWR9d+WHQMHmRWSeKa6eim/ofBN2vg86MPPMmrM=";
  };
  sukisu = fetch {
    name = "nns-sukisu-builtin.tar.gz";
    url = "https://github.com/SukiSU-Ultra/SukiSU-Ultra/archive/b20dee702035af09cb2ecb5f35443bbc1747f3e6.tar.gz";
    hash = "sha256-lyiNrw9IEtObfyW+QT6pP/69c0teLKsu0MbQ6OobmQ0=";
  };
  sukisuManager = fetch {
    name = "SukiSU-v4.2.0.apk";
    url = "https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases/download/v4.2.0/SukiSU_v4.2.0_40900-release.apk";
    hash = "sha256-TKmBDmNV+/8Lvkv1zhWYCOZKQNhZh6EYlAMM2ZCmvfM=";
  };
  susfs = fetch {
    name = "nns-susfs.tar.gz";
    url = "https://gitlab.com/simonpunk/susfs4ksu/-/archive/273ae364c5b7c92ceb15634c9f075b6fc0501048/susfs4ksu-273ae364c5b7c92ceb15634c9f075b6fc0501048.tar.gz";
    hash = "sha256-6stwmvnzDBwAMA73KXTvDWbTvDrx1ufAbJfz/oeqp/o=";
  };
}
