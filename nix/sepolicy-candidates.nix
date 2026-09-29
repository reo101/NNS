{ runCommand, fetchzip, python3 }:
let
  source = owner: repository: revision: hash: fetchzip {
    url = "https://codeload.github.com/${owner}/${repository}/tar.gz/${revision}";
    extension = "tar.gz";
    inherit hash;
    curlOptsList = [ "-A" "OpenAI File Downloader, XaiImageApiFetch/1.0" ];
  };
  # Latest public commits before the official OTA timestamp (2026-08-08 08:07:18 UTC).
  # These revisions are candidates, not a published build manifest.
  platform = source "Evolution-X" "system_sepolicy" "e631d35d7bd7b7993e84f3d49eeb34ec87dd1a27" "sha256-jO5cdJX2T2L1XdM7/l950Tjm2hRqeQyiVfMHLRGnvqA=";
  evolution = source "Evolution-X" "device_evolution_sepolicy" "c6e972cf4ff9bd472052b29cf8eae7bc3e70d378" "sha256-XNFAoSq3Nen7MIWoYb894kbJoW4IElnHhRprBvJBd5A=";
  pantah = source "Evolution-X-Devices" "device_google_pantah" "ddbe96d217dfc7a217311a6ef1b2fd43b3fd4f6a" "sha256-kZFROmi0j3RozSfQjANbPA48c+dUcT67/qfe+rypLA0=";
  gs201 = source "Evolution-X-Devices" "device_google_gs201" "3fdd30fee0fa02628a77e9fa5416a8be2ff3adec" "sha256-yByQvHZPDvxJcHTexh10aCNtTruNiljyuVlnY6VNa/I=";
in
runCommand "nns-sepolicy-candidates" { nativeBuildInputs = [ python3 ]; } ''
  python3 ${../tests/test-sepolicy-candidates.py} ${../tools/sepolicy-candidates.py}
  mkdir -p "$out"
  python3 ${../tools/sepolicy-candidates.py} \
    Evolution-X/system_sepolicy@e631d35d7bd7b7993e84f3d49eeb34ec87dd1a27 ${platform} \
    Evolution-X/device_evolution_sepolicy@c6e972cf4ff9bd472052b29cf8eae7bc3e70d378 ${evolution} \
    Evolution-X-Devices/device_google_pantah@ddbe96d217dfc7a217311a6ef1b2fd43b3fd4f6a ${pantah} \
    Evolution-X-Devices/device_google_gs201@3fdd30fee0fa02628a77e9fa5416a8be2ff3adec ${gs201} \
    > "$out/sepolicy-candidates.txt"
''
