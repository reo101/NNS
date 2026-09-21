{ lib, stdenvNoCC, androidSdk, jdk17, zip }:
stdenvNoCC.mkDerivation {
  pname = "nns-android-probe";
  version = "1";
  preferLocalBuild = true;
  src = lib.fileset.toSource {
    root = ../tests/android;
    fileset = lib.fileset.unions [ ../tests/android/Probe.java ../tests/android/AndroidManifest.xml ];
  };
  nativeBuildInputs = [ jdk17 zip ];
  dontConfigure = true;
  dontFixup = true;
  buildPhase = ''
    sdk=${androidSdk}/libexec/android-sdk
    tools="$sdk/build-tools/35.0.0"
    android="$sdk/platforms/android-35/android.jar"
    mkdir classes dex
    javac -source 8 -target 8 -bootclasspath "$android" -d classes Probe.java
    "$tools/d8" --min-api 29 --lib "$android" --output dex classes/xyz/reo101/nnstest/Probe.class
    "$tools/aapt2" link -I "$android" --manifest AndroidManifest.xml -o probe-unsigned.apk
    zip -j probe-unsigned.apk dex/classes.dex
    "$tools/zipalign" -p 4 probe-unsigned.apk probe-aligned.apk
    # Test-only signing identity. No external Gradle/Maven downloads.
    keytool -genkeypair -keystore test.keystore -storepass android -keypass android \
      -alias test -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=NNS test only'
    "$tools/apksigner" sign --ks test.keystore --ks-pass pass:android \
      --out nns-probe.apk probe-aligned.apk
    "$tools/apksigner" verify nns-probe.apk
  '';
  installPhase = ''
    mkdir -p "$out"
    cp nns-probe.apk "$out/"
  '';
}
