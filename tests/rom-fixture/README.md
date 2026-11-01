# Enforcing ROM fixtures

A fixture is controlled test data. This module is for disposable Cuttlefish VMs only.
Do not add this module or its policy to a production device.

Copy the module to `external/nns-rom-tests`. Add `nns-fixture` to the VM product.
Add its `sepolicy` directory to `SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS` for the VM only.
The production NNS integration remains separate.

The service requires the enforcing `nns_fixture` domain, root credentials, and only the `CHOWN` and `FOWNER` capabilities.
It cannot mount filesystems or execute the NNS helper.
The `restart-mount` action asks init to run the real `nns-mount` service before inspection.

In this VM, init labels a new `/data/nix` directory as `nns_fixture_backing_file`.
Fixture writes are limited to test types. Only native init assigns encryption policies.
The NNS helper receives read and lock permissions for the test backing type.
These tests cover preservation of the test label, not creation with the production label.

Do not run `prepare-encrypted` against user data. It assigns an encryption policy and changes ownership, permissions, timestamps, and attributes.
The operation requires an empty, root-owned backing directory.
After the fixture validates the empty directory, init assigns the device-encrypted policy through `mkdir ... encryption=Require`.
The fixture then reads the policy and creates nonempty encrypted data.
An absent policy is not evidence of encryption. The service refuses absent or unsupported policies.
The request property for the encryption step is not writable from ADB shell.

Run the host commands on Jeeves from the integration export.
After the VM boots and authorizes ADB, set `ADB_SERVER_SOCKET` to its private UNIX socket.
Use the host-package ADB executable as `$adb`:

```sh
python3 tests/test-rom-fixture.py inspect --adb "$adb" --output fresh.json
python3 tests/test-rom-fixture.py prepare-encrypted --adb "$adb" --output encrypted.json
python3 tests/test-rom-fixture.py restart-mount --adb "$adb" --output retained.json --baseline encrypted.json
```

After a VM reboot, run `inspect` with `--baseline encrypted.json` and a new output path.
The comparison includes hashes, ownership, permissions, timestamps, labels, attributes, inode identity, and the encryption policy.
Device numbers can change across boots. Each report must still show matching backing and bind identities and mount flags.

## Refusal tests

Do not run these actions against user data. They temporarily unbind `/nix` and move `/data/nix`.
Only init can enter the stock toolbox domain. Toolbox moves the backing between two fixed paths.
The move runs as the fixture owner with the supplementary `system` group. It does not bypass file permissions.
The module grants no content-copy permissions to toolbox.
After the fixture confirms the move, init creates an invalid backing file.
ADB shell cannot set either protected request property.

Set `$kernel_log` to the current kernel log for the VM instance on Jeeves.
If the VM contains encrypted fixture data, run:

```sh
python3 tests/test-rom-refusal.py --adb "$adb" --kernel-log "$kernel_log" --output refusals
```

The test checks conflicting mounts, stacked mounts, and an invalid backing file.
It restores a valid bind after each refusal.
Across F2FS parents, a directory rename changes mtime (last content-change time) and ctime (last metadata-change time).
The comparison permits those timestamp changes only for the moved backing directory.
All other backing fields and all content-file metadata remain unchanged.
