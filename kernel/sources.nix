{ fetchurl }:
let
  # Keep shell-level download clients consistent with the project policy.
  fetch = args: fetchurl (args // {
    curlOptsList = [ "-A" "OpenAI File Downloader, XaiImageApiFetch/1.0" ];
  });
in
{
  # All three integration archives were compared against the boot-tested tree.
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
  ksu = fetch {
    name = "nns-ksu.tar.gz";
    url = "https://github.com/backslashxx/KernelSU/archive/1d867429705d0aec7051667913c22d16237db312.tar.gz";
    hash = "sha256-dniKSQFJnf8y41buPCxFb3XNfpL0XmzmIG4S9r293fI=";
  };
  workflow = fetch {
    name = "nns-workflow.tar.gz";
    url = "https://github.com/yapixel/cheetah_ksu_workflow/archive/b600233157d6ee9e6c8d35d1c79a65c1fdba265f.tar.gz";
    hash = "sha256-Lf63Z8Op2wDXuTt/dhx97cX29C7ZYdxe2cox/Ow4BkM=";
  };
  susfs = fetch {
    name = "nns-susfs.tar.gz";
    url = "https://gitlab.com/simonpunk/susfs4ksu/-/archive/273ae364c5b7c92ceb15634c9f075b6fc0501048/susfs4ksu-273ae364c5b7c92ceb15634c9f075b6fc0501048.tar.gz";
    hash = "sha256-6stwmvnzDBwAMA73KXTvDWbTvDrx1ufAbJfz/oeqp/o=";
  };
}
