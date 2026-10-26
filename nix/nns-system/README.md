# NNS service managers

NNS selects one service manager for the whole system. Android init remains PID 1.

```nix
system.serviceManager = "runit"; # Default. Alternatives: "s6-rc", "dinit".
```

`system.serviceManagers.<name>` defines the implementations that `system.serviceManager` can select.

```nix
system.serviceManagers.<name> = {
  controller = ./managers/<name>/controller.sh; # Required. Sourced by the runtime.
  policy = ./managers/<name>/policy.sh; # Required. Sourced by the policy process.
  render = import ./managers/<name>/definitions.nix; # Optional. Manager definitions.
  runtimePackages = [ ]; # Optional. Supervision and control tools.
};
```

Each built-in manager lives in `nix/nns-system/managers/<name>/`. The directory holds the controller, the policy, and the optional definitions renderer. A manager needs no other files outside its directory.

`render` receives `{ pkgs, lib, services, modules }` and returns the manager definitions package. Runit keeps the default `null`, because it supervises the published run tree directly. The module builds `services/<name>/` for every manager from one shared action wrapper, which carries the environment, the working directory, and the finite-action body. The wrapper never waits for a dependency. Ordering belongs to the manager or to the policy process.

## Generation contents

The generation supplies these files to the runtime.

| File | Purpose |
| --- | --- |
| `service-manager` | Selected manager name |
| `service-manager-controller.sh` | Controller sourced by the runtime |
| `service-manager-policy.sh` | Policy sourced by the policy process |
| `service-definitions` | Manager definitions, when the manager renders them |
| `boot-services` | Services in the boot closure |
| `all-services` | Every service |
| `services/<name>/` | Run tree, finite markers, finish script, dependency list |

## Controller contract

The runtime sources `service-manager-controller.sh`. A controller defines five shell functions.

| Function | Purpose |
| --- | --- |
| `manager_preflight` | Refuse an unusable candidate before publication |
| `manager_prepare` | Publish the service tree and change intent |
| `manager_activate` | Reconcile the running manager with the generation |
| `manager_stop` | Stop supervision for shutdown or handoff |
| `manager_resume_after_failure` | Restore the policy process after an aborted reconciliation |

The runtime owns locking, state validation, supervisor registration, and generation publication. A controller owns manager state under `state/managers/<name>/`.

## Policy contract

The policy process sources `service-manager-policy.sh`. A policy defines two shell functions.

| Function | Purpose |
| --- | --- |
| `manager_apply` | Apply one selection file, which lists service identifiers |
| `manager_complete` | Act after the full startup transition succeeds |

`manager_apply` sets `successful=false` when the selection is not yet complete. The policy process then retries the same selection on its next pass. `manager_complete` either keeps the process resident or stops it, depending on what the manager can support.

## Service declarations

`system.services.<name>` declares services for the selected manager. Built-in services and generated directory actions use this collection too. Higher-level options such as `services.openssh` remain separate.

| Declaration | Behavior |
| --- | --- |
| `nns.type = "longrun"` | Supervise a persistent process. |
| `nns.type = "oneshot"` | Run a finite action. Retry failure and retain success without a process for that job. |
| `nns.after` | Wait for successful finite prerequisites or longrun startup. |
| `nns.startAt = "unlock"` | Defer startup until Android reports that user 0 storage is available. |
| `system.directories` | Apply directory metadata through generated finite actions. Never remove application data when a declaration disappears. |

Every activation invalidates prior finite results and reapplies finite actions. Within one manager, unchanged independent longruns retain their processes. Changed programs restart. Service removal and changes between longrun and oneshot are supported.

## Policy process

One dispatcher supplies the NNS retry and unlock policy for every manager. Before unlock, it requests only the boot dependency closure. A dependency on an unlock service also defers its dependent. Independent daemon startup does not wait for unlock.

Runit has no dependency engine. Its policy treats a running process as ready for a longrun and a completion record as ready for a finite action. It starts every service whose dependencies are ready in the same pass, so a failing branch never blocks an independent one. Its dispatcher stays resident, because runit has no native operator channel, but it does not repeat a completed phase.

s6-rc and Dinit own dependency ordering and finite state. Their policies call the native control tool. Their dispatchers stop after the full startup transition succeeds, so an operator stop stays stopped.

## Manager behavior

Runit publishes its own service tree and keeps supervisors under `state/services/<name>/supervise/`. Removed directories move to hidden `.retiring-<name>` paths under `state/services/`, which the scanner ignores. The controller deletes them after shutdown succeeds. If shutdown fails, the directories and ownership records remain available for retry. A failed shutdown prevents a manager handoff.

s6-rc compiles a database on the target with the target's compiler. Preflight does this before configuration publication. This supports ARM cross builds without embedding build-host helper paths. Protected databases remain separate from immutable definitions and live supervisor state. NNS supplies a ten-second stop wait for s6 longruns.

Dinit uses milestone dependencies. It has a processless internal `nns-runtime` service, which keeps the subordinate manager available when startup work finishes or an operator stops application services. If Dinit disappears unexpectedly during the same boot, activation fails rather than starting another manager over unknown surviving children.

## Failure handling

Each manager stops or pauses its dispatcher during reconciliation. On failure, cleanup attempts to restore that process before the controller exits. If restoration also fails, the controller reports it and retains the original failure status. The s6-rc database update waits for a lock that a dispatcher child still holds.

A `pending-update` marker retains unfinished changes. Retrying the same generation repeats reconciliation rather than treating its intended command as already active. A failed stop keeps ownership records and restart intent.

Runit activation waits up to ten seconds for a live dispatcher supervisor, then up to ten seconds for the dispatcher to start. A stale control FIFO does not satisfy this check. Activation does not wait for finite actions or Android unlock. Successful control commands are quiet. Failed commands report the operation, service, exit status, and captured output.

## Runtime boundaries

Manager packages enter the immutable administrative profile, not application profiles. The registration child records process ownership while it holds the activation lock. It closes that descriptor before namespace entry. The selected manager enters the existing root namespace launcher. Service commands inherit that namespace and use the same authoritative accounts and staged configuration. User services start in their NNS status directory. Manager helper lookup uses the immutable administrative profile.

`service-control` is the generation's internal service-only entry point. Use the generation's `activate` entry point for normal activation. Direct service activation does not publish configuration, profiles, or keys. For a coordinated manager shutdown, run the active generation's `service-control stop`. Direct manager termination can require recovery.

## Rollback

A manager handoff stops the current manager before starting its replacement. A failed stop aborts the handoff. The protected `manager-generation` link identifies the controller for the current or partially applied generation. Rollback uses that controller before restoring another manager.

Generation activation publishes configuration and profiles, then applies services. If activation fails after publication, the deployment tool must activate the previous supported generation. This remains the deployment tool's transaction, not an automatic transaction inside a service manager.

## Local tests

From the repository root, run:

```sh
nix run --builders '' --impure --file tests/nns-service-managers/default.nix tests -L
```

The suite runs real managers inside private user, mount, and PID namespaces. It checks retry, success retention, unlock closure, directory metadata, UID drift, changed programs, type changes, and removal. It also checks failed preflight, failed handoff, every manager pair, rollback, and cancellation of pending finite children.

The suite also checks that completed startup leaves native operator stops intact. Evaluation covers the default selector, rejected declarations, and ARM cross-generation evaluation. These tests do not access a device or deploy NNS. Android runtime validation remains a separate step.

## Device validation

Live activation passed on cheetah with Android 16 and SELinux Enforcing.

- All six directed handoffs between runit, s6-rc, and Dinit passed.
- Reapplying either native manager preserved all three independent longrun PIDs and reapplied the finite directory action.
- Each handoff retained one Nix daemon, SSH listener, and bridge. Root and both application UIDs could reach the daemon.
- An injected deployment failure after Dinit startup triggered automatic rollback to runit.
- Application PIDs, terminal properties, account ownership, directory permissions, and SELinux labels remained unchanged. The final manager was runit.

The phone rejects PID namespace creation. The isolated manager suite therefore ran only on the host. UID probes inherited adbd's SELinux domain, not the applications' domains. Reboot, locked-boot startup, and application-domain client execution were not tested.
