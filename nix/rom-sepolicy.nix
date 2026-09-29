{
  lib,
  fetchurl,
  runCommand,
  payload-dumper-go,
  e2fsprogs,

  phone ? "cheetah",
  rom-version ? {
    major = 16;
    minor = 0;
  },
  rom-release ? {
    major = 11;
    minor = 10;
  },
  rom-date ? {
    year = 2026;
    month = 08;
    day = 08;
  },
  rom-sha256 ? "dc362df5f1e229b80fed958d6e3ab35a257fe1e62365c8735dd8087c9d884e67",
  policy-sha256 ? "ddf13058afe318ba74368c8a296fda22148c00710c6a08b7dbdb46557a99817c",
}:
let
  date = "${builtins.toString rom-date.year}${lib.fixedWidthNumber 2 rom-date.month}${lib.fixedWidthNumber 2 rom-date.day}";
  version = "${builtins.toString rom-version.major}.${builtins.toString rom-version.minor}";
  release = "${builtins.toString rom-release.major}.${builtins.toString rom-release.minor}";
  ota = fetchurl {
    url = "https://cdn.evolution-x.org/${phone}/${builtins.toString rom-version.major}/EvolutionX-${version}-${date}-${phone}-${release}-Official.zip/download";
    sha256 = rom-sha256;
    # curlOptsList = [
    #   "-A"
    #   "OpenAI File Downloader, XaiImageApiFetch/1.0"
    # ];
  };
in
runCommand "nns-rom-sepolicy"
  {
    outputHash = policy-sha256;
    outputHashAlgo = "sha256";
    outputHashMode = "flat";
    nativeBuildInputs = [
      payload-dumper-go
      e2fsprogs.bin
    ];
  }
  ''
    mkdir vendor
    payload-dumper-go -p vendor -o vendor ${ota}
    debugfs -R "dump /etc/selinux/precompiled_sepolicy $out" vendor/vendor.img
  ''
