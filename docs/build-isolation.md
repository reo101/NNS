# Build isolation on Android

## Status

NNS now builds in the AVF guest with the Nix sandbox. The guest store is a
writable overlay: the phone store and state directory are the read-only
lower layers, and a writable partition is the upper layer. The phone store
is the lower layer and the publication target. Publication imports into the
phone daemon as a trusted client, so the VM is a build-execution boundary,
not a store-write boundary. The phone's own daemon still runs with
`sandbox = false`.

This document separates checked repository facts from design hypotheses and open questions. It records no implementation decision.

## Checked repository facts

- `module/etc/nix/nix.conf` sets `sandbox = false` and leaves `build-users-group` empty.
- Nix runs as root in the current phone setup. The Nix manual says that an empty build-user group runs builds as the Nix process UID. With the daemon, that is the daemon UID. The manual warns against this setup when untrusted clients can use the daemon.
- The NNS `nix-enter` launcher creates a mount namespace. For non-root callers, it also creates a user namespace and maps the caller identity. The launcher gives child processes a private mount view of `/nix`; it does not create the Nix build sandbox.
- The AVF guest builds in an overlay store with `sandbox = true` and `build-users-group = nixbld`. The phone's `/data/nix` is exported read-only as the lower layer; the writable build partition is the upper layer. Publication copies outputs back through the vsock bridge, which proxies to the supervised phone daemon socket. The daemon sees a root client, so it accepts `--no-check-sigs` imports from the guest. This path is not build isolation for untrusted inputs.
- The repository's Jujutsu history does not establish that the initial root bootstrap attempted Nix sandboxing and failed. The reason for `sandbox = false` remains unverified.

## Identity boundaries

A build UID identifies a Unix user. Its GID identifies a group. Both affect discretionary access control (DAC). A Linux Nix sandbox is a set of process and resource restrictions that Nix applies to a build. An SELinux domain is a mandatory access-control label on a process. These are separate controls.

A distinct build UID does not, by itself, create a Linux namespace or an SELinux domain. A setuid operation changes credentials only when the kernel and policy permit it. It does not create an Android app sandbox or cause an SELinux domain transition.

NNS launcher namespaces mirror the host's Android identity rather than the Nix build identity. They must not be described as a build sandbox.

## Options and unresolved questions

A root-run daemon could potentially allocate native UIDs and GIDs for builds through a daemon-private name service switch (NSS) configuration. This is a design hypothesis, not a tested implementation or a security claim. Any such pool must avoid collisions with Android identities. Do not guess Android UID or GID ranges.

Nix 2.34 adds `nix-nswrapper` for running the daemon in an unprivileged Linux user namespace. Nix requires subordinate UID and GID delegation in `/etc/subuid` and `/etc/subgid`. A stock rootless Android APK cannot grant these mappings or the namespace capabilities required to create them. Whether a rooted Android environment can provide the required delegation safely is unknown.

A companion APK could act as a controller, but it is not required to define the build identity. Android's `isolatedProcess` service mode would need an execution and I/O adapter, plus a reliable lifecycle for dynamically allocated identities. Its suitability for hosting Nix builds is not established.

The AVF guest is the implemented VM mode. Native root with a verified UID/GID pool and a remote builder remain alternatives. A mode must report whether its isolation setup succeeded. It must fail closed when setup fails. It must not silently run without the requested sandbox.

## Proposed negative tests

These tests are requirements for a future implementation. They do not describe tests that NNS currently passes.

- Reject an untrusted-build request when `sandbox = false` or when no isolated build identity is available.
- Fail a requested Linux sandbox when namespace setup or UID/GID mapping fails. Do not continue the build without isolation.
- Reject a proposed build UID/GID that overlaps a reserved Android identity. Confirm that the allocation source is authoritative before enabling a pool.
- Confirm that setuid alone changes neither the Android application identity nor the SELinux domain.
- Confirm that an `isolatedProcess` service cannot build until the required adapter, daemon access, store I/O, and identity cleanup are in place.
- Confirm that the guest build path uses the guest daemon and sandbox, and that publication is reported as a separate trusted import, not as build isolation.
- Confirm that remote or VM mode reports the selected execution boundary and fails when that boundary is unavailable.

## References

- [Nix 2.34 release notes](https://nix.dev/manual/nix/2.34/release-notes/rl-2.34), including `nix-nswrapper` and its subordinate UID/GID requirement.
- [Nix configuration reference](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html#conf-build-users-group), including `build-users-group` and build-user behavior.
- [Linux user namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html), including UID and GID mappings.
- [Android application sandbox](https://source.android.com/docs/security/app-sandbox), including per-app identity boundaries.
- [Android SELinux concepts](https://source.android.com/docs/security/features/selinux/concepts), including process domains and object types.
- [Android service manifest element](https://developer.android.com/guide/topics/manifest/service-element), including the `isolatedProcess` attribute.
