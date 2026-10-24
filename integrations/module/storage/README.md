# Module storage handoff candidate

This candidate keeps the installed ROM and uses a root-manager supervisor. It is
not included in the default module ZIP. It does not install or apply a SELinux
policy. The caller must supply and verify the enforcing policy before use.

Both programs are static Zig executables. The existing storage engine and its
configuration format remain unchanged.

## Handoff

`nns-storage-supervisor` requires root and accepts the storage engine's existing
arguments. It closes inherited descriptors above standard error, opens PID 1's
mount namespace, and reserves descriptor 3 for that reference. It opens the
sibling `nns-storage-module-controller` without following a symlink. The file
must be root-owned, have one hard link, and have no group or other write access.

The supervisor enters the referenced namespace, clears supplementary groups and
ambient capabilities, and retains only `SYS_ADMIN` in the capability and bounding
sets. It then executes the pinned controller file with an empty environment.
The executable label must select the enforcing `nns_storage` domain.

The controller requires that domain, the reduced capability sets, and no
supplementary groups. It sets `no_new_privs` (prevents privilege gain on exec).
The storage engine compares descriptor 3 with its current namespace before it
reads storage configuration. Missing or incorrect handoffs fail without mounting.

The root manager is the trusted caller. Descriptor 3 is an internal handoff, not
a caller-selectable namespace option. The controller receives no `SYS_PTRACE`
capability and does not reopen PID 1's namespace. Successful process exit, not an
Android property, is the module caller's completion signal.

## Checks

`tests/module-storage/handoff.nix` tests the supervisor in a Linux VM with a Zig
replacement controller. It checks namespace entry, capability reduction,
descriptor and environment isolation, and unsafe-file refusals. It also confirms
that the child cannot regain `SYS_PTRACE`.

`nix build .#nns-storage .#nns-storage-host` builds the ARM64 and host executables.
The Zig `storage` step builds the engine, supervisor and module controller.
`test-storage-namespace` checks namespace identity with a native Linux target.
`storage-handoff-fixture` builds the Zig replacement controller for the Linux test.

These Linux tests do not establish KernelSU policy loading or Android boot timing.
Hardware testing needs a separate policy decision and checks of the actual loaded
permissions. Parser acceptance alone does not prove that a rule is active.
