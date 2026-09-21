# Android app-path VM test

`nix run .#test-android` runs the NixOS Python test driver. For the sandboxed
check derivation, use `nix build .#android-vm-test` on an x86_64 builder with KVM.
The first build includes an Android kernel and SDK. Allow several GB of disk.

The layout follows `SteamlessLink/nix/tests/android-emulator-link.nix`: Android
and NixOS run as **sibling VMs**, not Android nested inside NixOS. No nested KVM,
physical device, host root, or existing adb server is required. Test adb uses
port 15038 and emulator serial `emulator-5582`; ports 31080 and 31553 are reserved
for the fixture. Fail rather than silently falling back to software emulation.

## Components

- Android 35 Google APIs x86_64 image (rootable, not a Play Store image).
- Its exact ACK revision, `8adecb593e9b745427da9d61c3cc8bc4857de209`, rebuilt
  with `CONFIG_USER_NS=y` and the pinned SukiSU implementation.
- The phone's seccomp bypass implementation, extracted directly from the
  existing patch rather than maintained as a second implementation. The
  emulator uses ordinary built-in KSU hooks, without unrelated SuSFS hiding.
- x86_64 builds of the same launcher, bridge, resolver and module scripts.
- A non-debuggable instrumentation APK. It starts through zygote as an actual
  `untrusted_app` UID with seccomp enabled, not `adb shell` or `run-as`.
- A NixOS fixture with a signed Nix binary cache and private DNS name. Guest-only
  iptables rules route Android DNS to its sibling through unprivileged host
  ports. Public DNS and caches are not required during the test.

## Assertions

1. Android boots with enforcing SELinux, USER_NS and the seccomp sysctl.
2. The real module is installed through ksud and its boot/service hooks run.
3. A canonical `/nix/store` closure is seeded without rewriting symlinks. Its
   `closureInfo` registration is loaded with `nix-store --load-db`, then contents
   are verified. The initial closure deliberately excludes `hello`.
4. The ordinary app cannot launch NNS with the seccomp bypass disabled.
5. With the bypass enabled, the app retains its UID, enters a distinct user
   namespace and `nns_app` domain, has no effective capabilities after exec,
   and has `NoNewPrivs=1`, `Seccomp=0` in its namespace subprocess.
6. The shared launcher, library, config and store remain unwritable by the app.
7. Glibc cannot resolve the fixture name without the bridge, but succeeds
   through Bionic with the bridge. No `resolv.conf` is supplied.
8. The app contacts the root daemon, substitutes the signed `hello` closure,
   verifies registration, creates a profile and executes `hello`.
9. A second app session works; neither session changes its parent's namespace
   or exposes a global `/nix`. SELinux stays enforcing throughout.

Logs are retained in the printed `nns-android-*` directory and copied under
`$out/android` for the sandboxed test. Private adb/emulator processes are stopped
on exit. This tests the Android app security/runtime path, not Cheetah boot-image
packing, hardware drivers, or ARM64 instruction behavior.

## Useful build targets

```
nix build .#kernel-android-test
nix build .#android-test-apk
nix build .#nns-module-x86_64
```

The production module still defaults to ARM64. Kernel module CRC checks remain
strict; the test does not force-load incompatible vendor modules. An SDK kernel
revision change is rejected until the pinned source is updated to match.
