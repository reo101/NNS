# NixOS guest with an external filesystem backend

The guest mounts the phone's existing `/data/nix/store` at `/nix/store`,
read-only. There is no store mirror, symlink rewriting, or guest closure
image. The writable root image is a 512 MiB mountpoint skeleton with the
init symlinks required for systemd's switch-root check.

Android's crosvm filesystem backend rejects symlink text that does not
start with its exported host directory. That rejects both absolute
`/nix/store/...` links and relative links such as `bin/sh -> bash` when
exporting `/data/nix/store`. The runner instead starts Nix-packaged
`virtiofsd` with a chroot sandbox, backend-enforced read-only access, and
`--tag=nix-store` (required for crosvm's vhost-user CONFIG requests).

The client converts its image configuration to raw AVF configuration,
attaches the connected backend socket through `SharedPath.socketFd`,
and sets `appDomain=true` on that raw share so virtmgr does not start a
second filesystem backend. It bypasses `VirtualMachine.run`: setting
`appDomain=true` in the high-level image configuration would still cause
Android's Java framework to spawn crosvm fs.

The runner uses the existing root, mount-only `nix-enter` session. Neither
ROM changes nor a global `/nix` mount are needed. The client selects Android's
`virtualizationmanager` execution domain while the framework starts the
manager. This uses the existing policy for memory-lock limits and restores
the caller's previous execution context afterward. The client retains the
manager until VM cleanup completes.

Payload files retain Android's `shell_data_file` labels from deployment
staging. Symlinks to Nix-store image files are not compatible: the manager
cannot receive those file descriptors under the existing policy.

The backend exits with the runner. After ten minutes, the client stops the
VM and returns failure. Backend output is written to
`/data/nix/var/avf/virtiofsd.log`.

## Deploy and verify

```sh
nix run .#nns-avf-deploy-guest -- <adb-serial> <ssh-host> 8022
adb -s <adb-serial> shell su -c \
  'sh /data/nix/var/avf/run-guest.sh /data/nix/var/avf/payload'
```

For a detached run, redirect the runner's output to a console log, then
pull it and check the boot proofs:

```sh
adb -s <adb-serial> pull /data/local/tmp/nns-avf-console.log /tmp/nns-avf-console.log
python3 tests/test-avf-console.py /tmp/nns-avf-console.log
```

The guest verifies absolute and relative store symlink reads before
switch-root. Its daemon bridge accepts clients at
`/nix/var/nix/daemon-socket/socket` and opens a separate vsock connection
to host CID 2, port 15555, for each client. The phone must already run the
NNS `nix-bridge` service. The guest's own Nix daemon is disabled, and
`NIX_REMOTE=daemon` is set for guest login sessions, including root.

Boot verification also:

- Realises `hello` through the phone daemon, installs it into a guest-local
  profile, and executes it from the shared store. Its output path deliberately
  has no Nix string context, so deployment does not seed the test package.
  The first run logs `PACKAGE ABSENT BEFORE REALISATION` and cache substitution;
  later runs reuse the registered package.
- Builds a tiny derivation through the daemon with substitution disabled.
  The guest boot ID makes the derivation distinct each boot. Both its tools
  are existing store inputs; no compiler closure is needed. The guest reads
  the resulting file through virtiofs, and attempts a direct write which
  must fail with `Read-only file system`.
- Gets an address and DNS configuration using networkd DHCP and resolved,
  then fetches `https://cache.nixos.org/nix-cache-info` directly from the guest.
  This tests guest networking separately from daemon-side substitution,
  which uses the phone's network. No host routing rules are added by NNS;
  Android manages the AVF TAP and tethering. Network-online waiting is
  disabled so a guest without a NIC can still boot.

The checks leave a verification profile under `/var/lib/nns-avf-verification`
and one small build output per boot in the phone store. **Guest-local profiles
are not valid phone-side retention roots:** the daemon cannot resolve paths
inside the guest root image. A profile installation proves execution, not
persistent retention. Long-lived guest workloads need a separate phone-visible
root strategy; this experiment does not implement one.

**Guest root is a trusted client of the phone's Nix daemon.** Read-only
filesystem sharing does not make this a sandbox for untrusted workloads.
The client currently relays console output but does not provide console
input in the external-backend path.
