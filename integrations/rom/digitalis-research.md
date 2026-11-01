# Digitalis ARM64 translation investigation

Read-only investigation. No Digitalis checkout, build, runtime integration or
EvolutionX source-lock replacement has been performed.

## Candidate revisions

| Project | Revision |
| --- | --- |
| `DigitalisX64/manifest` | `3969040d9ea562e8c874a57f545beeaf88975bc9` |
| `DigitalisX64/digitalis` | `11062cb09097c47a7d2b9ee292aa05626a821f10` |
| `DigitalisX64/platform_frameworks_libs_binary_translation` | `f5f1c90b17d0c1df9e9be41534c653a3e74bfc64` |
| `DigitalisX64/device_generic_goldfish` | `bbc2f1e4237016e744be8de59b7b6b310f2cc242` |
| `DigitalisX64/sample_hello_digitalis` | `ce9aa11646b0e16a7901388ae6ac4cc42e0b5c90` |

Jeeves stores downloaded manifests, configuration files and candidate revisions
under `temporary/digitalis-research/`. This is **not a complete build lock**:
Digitalis's AOSP base is the moving `android16-qpr2-release` branch and would need
full per-project resolution before a separate build.

## Integration evidence

- The manifest replaces only Goldfish and `frameworks/libs/binary_translation`,
  adding the entry repository and sample application. Do not import its root
  `CLAUDE.md`/`.claude` linkfiles into this repository or the active ROM checkout.
- `enable_arm64_to_x86_64.mk` requests `libberberis_arm64`, proxy libraries,
  program runners and ARM64 guest libraries. It sets the native-bridge library,
  ARM64-to-x86_64 ISA mapping and native execution property.
- The canonical distribution lists 74 paths, not just one translator library.
  These include ARM64 `app_process64`/`linker64`, guest libraries, host proxies,
  linker configuration and binfmt/init configuration.
- A binary consumer bundle is documented. Its packaging script requires a full
  existing product output for guest artifacts, or a full build before collection.
  Docker is optional: the same script supports the host build environment.
- The bundle verifier checks file hashes, host/guest ELF machines and the exported
  `NativeBridgeItf` symbol. These checks do not establish FaceUnlock compatibility.

## Boundaries and unresolved checks

The active Cuttlefish image already owns some canonical guest paths, including
`system/lib64/arm64/libc++.so`. Blindly inheriting the bundle would risk duplicate
install rules and replacing guest libraries with a different platform revision.
Its generated Makefile also copies ELF files directly; integration must preserve
Android's ELF-copy and artifact checks rather than enable broad bypasses.

A safe next experiment needs an isolated, pinned build or source-compatibility
assessment, followed by an explicit per-path ownership/dependency check. No second
memory-heavy Android build should run alongside the active ROM build. Keep the
kernel prebuilts unchanged.

Before testing FaceUnlock, verify a small ARM64 JNI application, linker/proxy
resolution and the selected process ABI. FaceUnlock declares `android.uid.system`
and no `jni_libs`; native-bridge library generation alone does not make its process
ARM64. PackageManager reconciles ABIs across shared-UID packages. Do not change the
shared UID or permission model without a separate decision.

## References

- [Pinned manifest include](https://github.com/DigitalisX64/manifest/blob/3969040d9ea562e8c874a57f545beeaf88975bc9/digitalis.xml)
- [Pinned distribution documentation](https://github.com/DigitalisX64/digitalis/blob/11062cb09097c47a7d2b9ee292aa05626a821f10/docker/README.md)
- [Pinned ARM64 enablement](https://github.com/DigitalisX64/platform_frameworks_libs_binary_translation/blob/f5f1c90b17d0c1df9e9be41534c653a3e74bfc64/enable_arm64_to_x86_64.mk)
