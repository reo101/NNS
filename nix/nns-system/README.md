# NNS service managers

NNS selects one service manager for the whole system. Android init remains PID 1.

```nix
system.serviceManager = "runit"; # Default. Alternatives: "s6-rc", "dinit".
```

`system.serviceManagers.<name>` defines the implementations that `system.serviceManager` can select. A built-in entry supplies two values.

```nix
system.serviceManagers.<name> = {
  controller = ./service-<name>.sh; # Required. Sourced by the runtime.
  runtimePackages = [ ]; # Optional. Supervision and control tools.
};
```

The runtime sources the controller of the selected generation. A controller defines five shell functions.

| Function | Purpose |
| --- | --- |
| `backend_preflight` | Refuse an unusable candidate before publication |
| `backend_prepare` | Publish the service tree and change intent |
| `backend_activate` | Reconcile the running manager with the generation |
| `backend_stop` | Stop supervision for shutdown or handoff |
| `backend_resume_after_failure` | Restore the policy process after an aborted reconciliation |

The runtime owns locking, state validation, supervisor registration, and generation publication. A controller owns manager-specific state under `state/managers/<name>/`.

Rendering still follows the selected name. A new name needs a matching renderer. The controller hook removes backend names from the runtime, not from the renderer.

`system.services.<name>` declares services for the selected backend. Built-in services and generated directory actions use this collection too. Higher-level options such as `services.openssh` remain separate.

The old `services.runit` option is removed. Rename it to `system.services`. Old declarations fail evaluation with a migration message. Existing built generations remain usable.

## Migration and rollback

A backend-aware generation recognizes every supported manager. If an installed generation only knows runit, first deploy a backend-aware generation with `system.serviceManager = "runit"`.

1. Keep runit selected for the first deployment.
2. Confirm that this runit deployment succeeds and remains the fallback for the next deployment.
3. Select s6-rc or Dinit for a later deployment.

A live switch from an unversioned runit tree is rejected before configuration or profile publication. Fresh installations do not need a runit bootstrap.

Do not activate a legacy generation while a native backend runs. Its old activation script cannot stop that backend. It can start duplicate daemon or SSH processes. The protocol guard recognizes runtime state, not every generation in deployment history. Keep live rollback targets within the backend-aware release boundary.

Backend-aware generations stop the current manager before starting its replacement. A failed stop aborts the handoff. The protected `manager-generation` link identifies the controller for the current or partially applied generation. Rollback uses that controller before restoring another backend. A `pending-update` marker retains unfinished native changes. Retrying the same generation repeats reconciliation rather than treating its intended command as already active.

Generation activation publishes configuration and profiles, then applies services. If activation fails after publication, the deployment tool must activate the previous supported generation. This remains the deployment tool's transaction, not an automatic transaction inside a service manager.

## Service behavior

| Declaration | Behavior |
|---|---|
| `nns.type = "longrun"` | Supervise a persistent process. |
| `nns.type = "oneshot"` | Run a finite action. Retry failure and retain success without a process for that job. |
| `nns.after` | Wait for successful finite prerequisites or longrun startup. |
| `nns.startAt = "unlock"` | Defer startup until Android reports that user 0 storage is available. |
| `system.directories` | Apply directory metadata through generated finite actions. Never remove application data when a declaration disappears. |

Every activation invalidates prior finite results and reapplies finite actions. Within one backend, unchanged independent longruns retain their processes. Changed programs restart. Service removal and changes between longrun and oneshot are supported.

Native dependency ordering and successful finite state belong to s6-rc or Dinit. NNS does not use completion files as their dependency engine. The files under `state/services/<name>/` retain diagnostic completion and exit status. Native exit status records contain the shell command status, not runit's raw signal fields. Service output and dispatcher diagnostics append to `state/supervisor.log`.

One internal dispatcher supplies the NNS retry and unlock policy that these backends do not provide. Before unlock, it requests only the boot dependency closure. A dependency on an unlock service also defers its dependent. Independent daemon startup does not wait for unlock. After the full startup transition succeeds, the dispatcher stops itself. It does not continually undo native operator stops.

During a pending s6-rc transition, its live database remains locked. A finite action that does not return can delay other native graph commands. Activation cancels the pending transition before updating the database. Finite actions must not detach from their native process group. Actions must tolerate interruption and retry.

s6-rc stops changed services and resets finite state before switching databases. The asynchronous dispatcher starts their replacements. A failed replacement action does not block activation or abort independent daemon startup. This can also restart longruns that depend on those finite services. Dinit uses milestone dependencies and does not impose the same reverse-stop behavior. Neither backend equates process startup with application health. NNS still checks the Nix daemon with an application ping.

## Runtime boundaries

Manager packages enter the immutable administrative profile, not application profiles. The registration child records process ownership while it holds the activation lock. It closes that descriptor before namespace entry. The selected manager enters the existing root namespace launcher. Service commands inherit that namespace and use the same authoritative accounts and staged configuration as runit. User services start in their NNS status directory. Manager helper lookup uses the immutable administrative profile.

For s6-rc, the generation supplies source definitions. Preflight compiles a database with the target's compiler before configuration publication. This supports ARM cross builds without embedding build-host helper paths. Protected databases remain separate from immutable definitions and live supervisor state. NNS supplies a ten-second stop wait for s6 longruns, matching the existing runit wait.

For s6-rc cancellation, NNS freezes and terminates the dispatcher's process group, then the native oneshot runner's process group. It does not assume that terminating the `s6-rc` client cancels its finite actions. The native updater then switches databases. For Dinit, scripted startup is interruptible and native stop waits for completion or process-group termination.

A failed native reconciliation restores the policy process before it exits. The dispatcher is re-enabled for s6-rc and Dinit, so the retry starts from a running manager instead of a stopped policy process. The s6-rc database update waits for a lock that a dispatcher child still holds, because a transient lock is not a failed update.

Dinit has a processless internal `nns-runtime` service. It keeps the subordinate manager available when startup work finishes or an operator stops application services. It is not a worker for a finite action.

If Dinit disappears unexpectedly during the same boot, activation fails rather than starting another manager over unknown surviving children. Reboot or account for those children before recovery. s6 retains per-service supervisors that its control tools can stop after scanner failure.

`service-control` is the generation's internal service-only entry point. Use the generation's `activate` entry point for normal activation. Direct service activation does not publish configuration, profiles, or keys. For a coordinated manager shutdown, run the active generation's `service-control stop`. Direct manager termination can require recovery.

## Local tests

From the repository root, run:

```sh
nix run --builders '' --impure --file tests/nns-service-managers/default.nix tests -L
```

The suite runs real managers inside private user, mount, and PID namespaces. It checks retry, success retention, unlock closure, directory metadata, UID drift, changed programs, type changes, and removal. It also checks failed preflight, failed handoff, all backend pairs, rollback, and cancellation of pending finite children.

The suite also checks that completed startup leaves native operator stops intact. Evaluation covers the default selector, rejected declarations, and ARM cross-generation evaluation. These tests do not access a device or deploy NNS. Android runtime validation remains a separate step.

## Device validation

Live activation passed on cheetah with Android 16 and SELinux Enforcing. The installed legacy runit scanner was first adopted by a backend-aware runit generation.

- All six directed handoffs between runit, s6-rc, and Dinit passed.
- Reapplying either native backend preserved all three independent longrun PIDs and reapplied the finite directory action.
- Each handoff retained one Nix daemon, SSH listener, and bridge. Root and both application UIDs could reach the daemon.
- An injected deployment failure after Dinit startup triggered automatic rollback to backend-aware runit.
- Application PIDs, terminal properties, account ownership, directory permissions, and SELinux labels remained unchanged. The final backend was runit.

The phone rejects PID namespace creation. The isolated manager suite therefore ran only on the host. UID probes inherited adbd's SELinux domain, not the applications' domains. Reboot, locked-boot startup, and application-domain client execution were not tested.
