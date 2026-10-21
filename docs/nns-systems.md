# NNS systems and package profiles

## Status

The standalone NNS generation runs on cheetah through deploy-rs. Root and NoD SSH reconnection work. Native Android Emacs runs Git, Bash, asynchronous commands, and SSH without changing its UID or HOME.

Module 3.2.0 boots the selected generation on cheetah. Root SSH and the Nix daemon work before Android unlock. All four supervised services remain running after unlock. Historical and deploy-rs rollback tests pass.

Native Emacs loads its full configuration without warnings. Its synchronous commands, asynchronous PTY commands, daemon access, and direct loopback SSH work. An earlier persistent-shell TRAMP probe stalled after authentication. That probe was not repeated after the Emacs configuration repair.

Initial migration requires a separate, approved administrative action. The legacy listener does not provide the new root administration account. Keep ADB and an independent bootstrap connection until the new listener works. The first NNS profile has no previous generation for automatic rollback.

Build isolation is unchanged. Nix builds still run without a sandbox or build-user pool. See [Build isolation on Android](build-isolation.md).

## Ownership

An NNS system generation is an immutable directory with its activation program. The module uses `_class = "nns"`, not NixOS. Its constructor uses `lib.evalModules` and returns `config.system.build.toplevel`.

NNS owns the daemon configuration, root services, administrative SSH keys, and published package profiles. NoD owns its login files and Home Manager activation. Android Emacs retains its Android UID and HOME.

Selecting a package profile changes tools. Consumers can also load its declared environment variables. It does not change UID, HOME, services, daemon configuration, or Home Manager activation. NoD and Emacs do not share their private home directories.

## Module API

```nix
nns.lib.nnsSystem {
  system = "aarch64-linux";
  modules = [ ({ pkgs, ... }: {
    environment.profiles.development = {
      packages = [ pkgs.git pkgs.bashInteractive pkgs.nil ];
      variables.EDITOR = "emacsclient -t";
    };
    services.openssh = {
      enable = true;
      port = 8022;
      authorizedRootKeys = [ "ssh-ed25519 REPLACE_WITH_ADMIN_PUBLIC_KEY" ];
    };
    accounts.nix-on-droid = {
      uid = 10578;
      gid = 10578;
      home = "/data/data/com.termux.nix/files/home";
      shell = "${pkgs.zsh}/bin/zsh";
      authorizedKeysFiles = [
        "/data/data/com.termux.nix/files/home/.ssh/authorized_keys"
      ];
    };
  }) ];
}
```

The UID and GID in this example are device-specific. They must match the installed app. Root SSH uses only `authorizedRootKeys`. It does not read the app's key file. App-owned key files are read after dropping to that account's UID and GID.

`nix.package` selects Nix for the daemon and administrative system profile. It defaults to `pkgs.nix`. Set `nix.package = pkgs.nixVersions.latest` to select the latest package.

`nix.settings` supplies daemon configuration. `services.runit.<name>` accepts nixpkgs portable service modules with `process.argv` and `process.environment`. Its NNS options are `nns.enable`, `nns.startAt = "boot" | "unlock"`, and `nns.after`.

Service executables use store paths or Android system binaries. Root service PATH never includes an app profile. Nested services, `configData`, reload commands, notification protocols, and service PATH overrides are rejected. Dependencies must be enabled and acyclic.

Each published profile contains `bin` and `etc/nns/environment`. The environment file contains quoted exports and CA certificate defaults. Identity and runtime variables such as HOME, USER, PATH, BASH_ENV, NNS_PROFILE, and NIX_REMOTE are rejected.

## Generation activation

A generation contains `activate`, `system-profile`, `etc`, `profiles`, and `services`. Mutable state stays under `/data/nix/var/nns`. The daemon's staged directory stays at `/data/nix/var/daemon-etc`.

Activation requires root and a serialized lock. It rejects app-owned administrative directories rather than adopting them. It updates staged files without replacing the directory inode. Existing `/etc` bind mounts therefore retain the updated files. Android's `/etc` and `/var` remain unchanged.

Profile publication uses `nix-env --profile ... --set ...` against already-realized store paths. It uses the local store as root, so boot does not require an existing daemon. Standard per-user profile directories are delegated to declared accounts. NNS retains ownership of their administrative parent.

Runit reconciles the service directories. Changed supervised services restart. Daemon and SSH configuration dependencies are included in their run scripts, so configuration changes also trigger a restart. The daemon and SSH master receive signals directly, without an extra launcher monitor. The supervisor enters the staged namespace through the native launcher.

The launcher supplies a fresh `/var/empty` in its private tmpfs root. It preserves the other `/var` entries through directory bind mounts and file references. OpenSSH runs unchanged. No binary copies, byte patches, or host `/var` writes are needed. The `sshd` account uses Android's existing nobody identity, UID/GID 9999, not a new app UID.

The boot module selects `/nix/var/nix/profiles/nns-system`. It checks root ownership of the administrative paths and selected store directory. If selected, it does not run legacy `stage-etc.sh`, daemon startup, or app-derived service startup. If no generation is selected, legacy boot remains available with a warning.

## NoD consumer mode

```nix
imports = [ inputs.nns.nixOnDroidModules.nns ];
nns.enable = true;
nns.systemManaged = true;
```

Remove the legacy `nns-sshd` import and move `nns.services` and `nns.nix.settings` into the NNS host. Consumer mode rejects daemon configuration and enabled root service materialization.

NoD activation reports the selected client version and the running daemon version. A successful daemon connection is required. Different versions produce a warning, not an activation failure. A successful connection does not guarantee that every feature is available.

NoD retains its login, app HOME, terminal files, package installation, and Home Manager activation. Its existing CLI is patched to use the delegated generation profile. Its generation profile uses `/nix/var/nix/profiles/per-user/<account>/nix-on-droid`. This device-encrypted directory stays visible to garbage collection before unlock. NoD cannot write NNS's root service directory.

The rix101 example lives in `hosts/nns/cheetah`. Its deploy node contains `nns` and `nod` profiles, in that order. Both copy store paths through root SSH. The NNS profile uses `/nix/var/nix/profiles/nns-system`.

Before NoD activation, an immutable helper drops to the app's UID and GID. It clears supplementary groups and sets the app's HOME. The NoD deployment profile and confirmation files stay in app-writable directories. NoD remains an untrusted daemon client. Root transport permits unsigned local outputs without granting that trust to the app.

Both profiles use deploy-rs `activate.custom`. The NNS command is `$PROFILE/activate switch`.

After bootstrap, `deploy .#cheetah.nod` selects only NoD. `deploy .#cheetah` selects both profiles. These commands do not replace the initial ownership and SSH migration.

Existing `/data/nix/etc/profile` files are preserved during module upgrades. Bootstrap must review that file and install the new client profile code if needed. Root builder credentials also need separate provisioning in the new administrative HOME. They are not inherited from NoD or Emacs.

The new SSH host key is root-owned state. Existing Emacs known-host entries require an explicit host-key migration. Do not silently accept a changed host key or copy an app-owned host key into administrative trust.

## Consumer selection and retention

```sh
nix-enter --profile development -- git --version
nix-enter --profile development --generation 2 -- bash
nix-enter --profile /nix/store/HASH-environment -- git --version
```

The launcher sets PATH and NNS_PROFILE. It does not source shell exports for raw commands. Emacs loads the profile's exports before each subprocess. Android's interactive shell can load them through the module client profile.

Without `--etc`, the launcher creates private `passwd` and `group` files for the caller's actual UID and GID. HOME and SHELL supply the account fields. Missing values use `/` and `/bin/sh`. The account name uses USER, or `uid<UID>` when USER is absent or empty. UID 0 keeps the name `root`. Fields cannot contain colons or newlines.

Other `/etc` entries still reference the original tree. The host name-service cache is hidden so it cannot override these records. Explicit `--etc` remains authoritative for NoD and supervised services. Neither form changes Android's account files or the kernel identity.

Explicit selection resolves inside the namespace. Missing profiles, invalid generations, and targets outside the store fail. If `--profile` is omitted, namespace-only bootstrap commands remain available without an installed infrastructure profile.

Emacs defaults to `development`. `M-x nns-select-profile` selects a buffer's profile. With a prefix argument, it also prompts for a generation. Re-selecting the current name resolves its latest target. Existing processes retain their prior environment.

For a global Emacs default, use `setq-default`. For a project, use buffer-local or directory-local `nns-profile` and `nns-profile-generation`. `nns-shell` starts the selected Bash without NoD login files or another app's HOME.

A cached target is not a garbage-collection root. Named profiles retain all generations until the administrator removes them. This retention protects pinned Emacs buffers across ordinary configuration updates. This implementation does not prune generations automatically.

If an administrator deletes old profile generations, active consumers can lose their pinned environment during later garbage collection. Explicit store paths also need a retained profile or a separate ordinary Nix root. Removing a profile declaration does not delete its retained generations.

## Local validation

The launcher tests use real rootless user namespaces. Emacs tests run synchronous and asynchronous commands through those namespaces. Activation tests use temporary directories, a mapped root UID, and a mock profile writer. Boot tests isolate `/data` in a private mount and run stock `sshd -t`. They do not exercise phone SSH, SELinux, UID transitions between app accounts, or network rollback.

```sh
nix build --builders '' .#checks.x86_64-linux.nns-system
nix build --builders '' .#checks.x86_64-linux.nns-generation
nix run .#test-userns
nix run .#test-emacs
nix run .#test-nns-activation
nix run .#test-nns-boot
```

The first command evaluates the module contract. The second builds a test generation, not a deployable device configuration. Its test SSH key is deliberately not usable for administration.

## Device validation

`tests/device-profile-smoke.py` tests existing phone store paths through a temporary profile tree. It requires root ADB and a running daemon. It does not replace the installed launcher, start listeners, or activate a generation.

```sh
python3 tests/device-profile-smoke.py --serial DEVICE --launcher AARCH64_NIX_ENTER
```

The test covers root and numeric app identities, named generations, immutable targets, HOME, working directories, daemon access, and stock `sshd -t`. Numeric UID probes retain adbd's SELinux domain. Separate native Emacs probes confirm execution in `nns_app`, zero effective capabilities, and `NoNewPrivs=1`.

Phone migration exposed world-writable configuration and profile parents, stale supervisor pipes, and a malformed legacy `nix.conf`. The approved migration backed up the legacy files, secured the administrative directories, and retained the old service tree. Android `mksh` also required permission checks that do not depend on leading-zero octal arithmetic.

The device passed these rollback tests:

- Switch NNS generation 2 to generation 1, reconnect through SSH, then restore generation 2.
- Activate a disposable NNS candidate that exits with an error after publishing a changed package environment. deploy-rs restores the previous generation.
- Move administrative SSH from port 8022 to port 8023 and withhold activation confirmation. The 15-second timeout restores port 8022 without ADB recovery.
- Confirm a changed NNS generation, then fail NoD activation under UID 10578. With `--rollback-succeeded true`, deploy-rs restores both deployment profiles.

All tests restore the original deployment targets and development profile. The shared `nix.conf` hash also matches its starting value. Independent ADB recovery guards remain available during each failure test but do not run. Post-test SSH, daemon access, and native Emacs checks pass.
