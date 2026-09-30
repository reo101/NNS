{ stdenvNoCC, androidSdk, jdk17, kotlin, zip }:
stdenvNoCC.mkDerivation {
  pname = "nns-avf-client";
  version = "2";
  preferLocalBuild = true;
  src = ../integrations/avf/VirtualMachineClient.kt;
  nativeBuildInputs = [ jdk17 kotlin zip ];
  dontUnpack = true;
  dontConfigure = true;
  dontFixup = true;
  buildPhase = ''
    sdk=${androidSdk}/libexec/android-sdk
    tools="$sdk/build-tools/35.0.0"
    android="$sdk/platforms/android-35/android.jar"
    mkdir dex
    # kotlinc emits a jar; d8 dexes it together with the stdlib the
    # runtime does not provide.
    kotlinc -classpath "$android" -d client.jar "$src"
    "$tools/d8" --min-api 34 --lib "$android" --output dex \
      client.jar ${kotlin}/lib/kotlin-stdlib.jar
  '';
  installPhase = ''
    mkdir -p "$out"
    zip -j "$out/avf-client.jar" dex/classes.dex
  '';
}
