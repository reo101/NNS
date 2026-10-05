# Build isolation on Android

## Status

NNS does not provide a verified security boundary for builds today. The current Nix configuration disables the Nix sandbox. Do not treat builds from untrusted inputs as safe on this device.

This document separates checked repository facts from design hypotheses and open questions. It records no implementation decision.

## Checked repository facts

- `module/etc/nix/nix.conf` sets `sandbox = false` and leaves `build-users-group` empty.
- Nix runs as root in the current phone setup. The Nix manual says that an empty build-user group runs builds as the Nix process UID. With the daemon, that is the daemon UID. The manual warns against this setup when untrusted clients can use the daemon.
- The NNS `nix-enter` launcher creates a mount namespace. For non-root callers, it also creates a user namespace and maps the caller identity. The launcher gives child processes a private mount view of `/nix`; it does not create the Nix build sandbox.
- The AVF guest currently forwards Nix requests to the phone's daemon. Its shared store is read-only, but the guest remains a trusted client of that daemon. This path does not isolate builds.
- The repository's Jujutsu history does not establish that the initial root bootstrap attempted Nix sandboxing and failed. The reason for `sandbox = false` remains unverified.

## Identity boundaries

A build UID identifies a Unix user. Its GID identifies a group. Both affect discretionary access control (DAC). A Linux Nix sandbox is a set of process and resource restrictions that Nix applies to a build. An SELinux domain is a mandatory access-control label on a process. These are separate controls.

A distinct build UID does not, by itself, create a Linux namespace or an SELinux domain. A setuid operation changes credentials only when the kernel and policy permit it. It does not create an Android app sandbox or cause an SELinux domain transition.

NNS launcher namespaces mirror the host's Android identity rather than the Nix build identity. They must not be described as a build sandbox.

## Options and unresolved questions

A root-run daemon could potentially allocate native UIDs and GIDs for builds through a daemon-private name service switch (NSS) configuration. This is a design hypothesis, not a tested implementation or a security claim. Any such pool must avoid collisions with Android identities. Do not guess Android UID or GID ranges.

Nix 2.34 adds `nix-nswrapper` for running the daemon in an unprivileged Linux user namespace. Nix requires subordinate UID and GID delegation in `/etc/subuid` and `/etc/subgid`. A stock rootless Android APK cannot grant these mappings or the namespace capabilities required to create them. Whether a rooted Android environment can provide the required delegation safely is unknown.

A companion APK could act as a controller, but it is not required to define the build identity. Android's `isolatedProcess` service mode would need an execution and I/O adapter, plus a reliable lifecycle for dynamically allocated identities. Its suitability for hosting Nix builds is not established.

Possible future execution modes include native root with a verified UID/GID pool, a VM, or a remote builder. A mode must report whether its isolation setup succeeded. It must fail closed when setup fails. It must not silently run without the requested sandbox.

## Proposed negative tests

These tests are requirements for a future implementation. They do not describe tests that NNS currently passes.

- Reject an untrusted-build request when `sandbox = false` or when no isolated build identity is available.
- Fail a requested Linux sandbox when namespace setup or UID/GID mapping fails. Do not continue the build without isolation.
- Reject a proposed build UID/GID that overlaps a reserved Android identity. Confirm that the allocation source is authoritative before enabling a pool.
- Confirm that setuid alone changes neither the Android application identity nor the SELinux domain.
- Confirm that an `isolatedProcess` service cannot build until the required adapter, daemon access, store I/O, and identity cleanup are in place.
- Confirm that the existing AVF forwarding path still reaches the phone daemon and is not reported as build isolation.
- Confirm that remote or VM mode reports the selected execution boundary and fails when that boundary is unavailable.

## References

- [Nix 2.34 release notes](https://nix.dev/manual/nix/2.34/release-notes/rl-2.34), including `nix-nswrapper` and its subordinate UID/GID requirement.
- [Nix configuration reference](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html#conf-build-users-group), including `build-users-group` and build-user behavior.
- [Linux user namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html), including UID and GID mappings.
- [Android application sandbox](https://source.android.com/docs/security/app-sandbox), including per-app identity boundaries.
- [Android SELinux concepts](https://source.android.com/docs/security/features/selinux/concepts), including process domains and object types.
- [Android service manifest element](https://developer.android.com/guide/topics/manifest/service-element), including the `isolatedProcess` attribute.
