# NixOS guest with a writable overlay store

The guest mounts the phone's `/data/nix` read-only at `/nix`. That share
contains the phone store and the phone Nix state directory. At boot the
guest formats a second writable partition (`nix-upper`) and mounts
overlays over `/nix/store` and `/nix/var`: the phone's store and state are
the lower layers, the build partition is the upper layer. The guest
nix-daemon then builds into the upper layer with the Nix sandbox and
`nixbld` users. The phone store and database stay read-only; the guest's
builds and database writes land on the build partition.

The writable partition is a sparse 16 GiB file the deploy script creates
on the phone. The guest formats it on first boot; later boots reuse it.
The root image stays at 512 MiB.

Android's crosvm filesystem backend rejects symlink text that does not
start with its exported host directory. That rejects both absolute
`/nix/store/...` links and relative links such as `bin/sh -> bash` when
exporting `/data/nix/store`. The runner instead starts Nix-packaged
`virtiofsd` with a chroot sandbox, backend-enforced read-only access, and
`--tag=nix-store` (required for crosvm's vhost-user CONFIG requests). It
exports `/data/nix`, not just the store, so the guest sees the phone
database and state directory as the lower overlay layer.

The client converts its image configuration to raw AVF configuration,
attaches the connected backend socket through `SharedPath.socketFd`, and
sets `appDomain=true` on that raw share so virtmgr does not start a second
filesystem backend. It bypasses `VirtualMachine.run`: setting
`appDomain=true` in the high-level image configuration would still cause
Android's Java framework to spawn crosvm fs.

The runner uses the existing root, mount-only `nix-enter` session. Neither
ROM changes nor a global `/nix` mount are needed. The client selects
Android's `virtualizationmanager` execution domain while the framework
starts the manager. This uses the existing policy for memory-lock limits
and restores the caller's previous execution context afterward. The client
retains the manager until VM cleanup completes.

Payload files retain Android's `shell_data_file` labels from deployment
staging. The deploy script labels the writable build partition the same
way; `system_data_file` is rejected by `virtualizationmanager`. Symlinks
to Nix-store image files are not compatible: the manager cannot receive
those file descriptors under the existing policy.

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
switch-root. At boot it formats the build partition and mounts the
overlay store. The guest daemon then builds with `sandbox = true` and no
builders.

Boot verification also:

- Realises `hello` from the guest's substituter, proving guest networking
  and substitution. Its output path deliberately has no Nix string
  context, so deployment does not seed the test package.
- Builds a tiny derivation through the guest daemon with substitution
  disabled and no builders. The build runs as a `nixbld` user in the Nix
  sandbox and writes to the upper layer. The guest boot ID makes the
  derivation distinct each boot.
- Publishes the output into the phone store with `nix copy --no-check-sigs
  --to daemon` through the bridge, then reads it back with `nix path-info
  --store daemon`.
- Gets an address and DNS configuration using networkd DHCP and resolved,
  then fetches `https://cache.nixos.org/nix-cache-info` directly from the
  guest.

## Publication

```sh
nns-publish /nix/store/<path>
```

`nns-publish` copies paths from the guest overlay to the phone daemon over
the bridge. It sends the output closure, not `.drv` files unless
`--derivation` is passed. The phone daemon registers the paths in the
phone store. `--no-check-sigs` is required: guest build outputs are
input-addressed and carry no signature, and the client-side default is to
ask the daemon to verify them.

The phone bridge proxies each connection to the supervised daemon socket,
`/data/nix/var/nix/daemon-socket/socket`. The daemon sees the proxy as
uid 0, which `trusted-users` accepts, so it honours `--no-check-sigs`. A
fresh `nix-daemon --stdio` per connection is untrusted: the daemon forces
signature checks on those clients and rejects unsigned guest outputs.
It is a publication path, not the build path. **The bridge runs as root
and imports whatever NARs the guest sends.** The VM is a build-execution
boundary, not a store-write boundary. If builds are untrusted, the phone
should pull and verify instead of accepting guest pushes.

Guest-local profiles and the guest database live in the overlay upper
layer on the build partition. They are not phone-side retention roots:
the phone daemon cannot resolve paths inside the guest partition. Publish
and root outputs on the phone if the phone must retain them.
