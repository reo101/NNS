# Service management above a supervisor

This report separates process supervision from service policy. A supervisor keeps a process running and delivers signals. A service manager decides when services can start, what completion means, and which transitions to request.

The experiments do not replace Android init or change the production runit deployment. [README.md](README.md) contains the language comparison and the test command.

## What NNS implements now

`nix/nns-system/module.nix` and `activate.sh` distribute policy across three places:

| Location | Current responsibility |
|---|---|
| Activation | Publish definitions, remove obsolete services, invalidate finite results, change service kinds, restart changed longruns, launch the supervision tree, probe the Nix daemon. |
| Generated `run` | Wait for Android unlock, wait for dependencies, clear previous finite results, set the environment, execute the command. |
| Generated `finish` | Record exit code and signal, record success, suppress restart after successful completion. |

A longrun is a process intended to remain running. A oneshot is a finite action with a completion result. Oneshots currently retry after failure and run again on activation. Successful oneshots stop without a resident worker.

Nix already rejects invalid service references and dependency cycles. At runtime, the generated per-service waits implement the graph's startup constraints.

This is service-manager policy, not merely service supervision. It is a subset of what systemd implements, not an attempt to duplicate its whole architecture. NNS has no general readiness protocol, dependency-failure propagation, reverse dependency shutdown, socket activation, resource accounting, or general service transition engine.

The current `after` relation waits for a longrun's `run:` status or a oneshot's successful completion. It is not equivalent to systemd's ordering-only `After=`. It also does not bind the later lifetime of an already-running dependent to its dependency.

A waiting wrapper already counts as `run:`. A wrapper waiting for unlock or another service is not evidence that its eventual daemon is ready. The separate Nix daemon ping is a real application readiness probe.

## Existing runit mechanisms worth using

[runit's dependency guidance](https://smarden.org/runit/dependencies.html) recommends waits in dependent run scripts. NNS follows that architecture, then adds durable finite-job results and activation reconciliation.

[`sv once`](https://smarden.org/runit/sv.8.html) starts a service without restarting it after exit. It stops after both successful and unsuccessful exits. It does not record a persistent successful result or retry a failed action. Replacing the current `up`/`finish` policy with `once` therefore moves retry policy into a coordinator. It does not remove that policy.

An executable `check` file defines service availability for `sv check` and waiting start operations. This is a useful readiness contract without replacing runit. Plain `sv status` does not run that check.

The native-control tests demonstrate both properties against actual runsv: `once` does not repeat either exit status, and `run:` can coexist with a failed `check`.

## Related projects

| Project | What it contributes | Relevance to NNS |
|---|---|---|
| [Void runit conventions](https://docs.voidlinux.org/config/services/index.html) | Service enablement through links, service scripts, `down` files, and runit administration. | Useful operational conventions. Not a general graph and completion engine. |
| [rsv](https://github.com/JojiiOfficial/rsv) | Rust client with status, signals, enablement, and start/stop commands. | Better operator interface, not evidence of readiness-aware dependency coordination. |
| [RSM](https://github.com/Sbatushe/Runit-Service-Manager) | Python TUI for selecting services to start or stop. Its README points to a Codeberg successor. | A verified runit frontend, not the service state engine sought here. The successor was not fetchable in this research. |
| [svm](https://github.com/keesvv/svm) | A Go runit manager. Its README leaves usage documentation as a TODO. | Not enough documented behavior to justify adoption as a dependency manager. |
| [nosh](https://jdebp.uk/Softwares/nosh/) | A daemontools-family toolkit with dependency and ordering metadata, separate service/system managers, restart policy, targets, and filesystem control. | Direct architectural precedent for extending the supervision model. It is its own toolkit, not a small runit plugin. Android compatibility was not tested. |
| [s6 with s6-rc](https://skarnet.org/software/s6-rc/) | Explicit oneshot/longrun types, graph compilation, readiness-aware transitions, live state, and live database updates. | The closest tested match to the missing state machinery. Adopting it also adopts s6 supervision. |
| [anopa](https://jjacky.com/anopa/) | An s6 manager with `needs`, `wants`, `after`, `before`, finite start/stop actions, and readiness support. | A useful design reference, especially its distinction between ordering and requirement. Its site documents version 0.5.0 and older examples. Not tested here. |
| [66](https://framagit.org/Obarun/66) | A higher-level service-management suite in the s6 ecosystem. | Relevant to an s6 deployment, not an add-on that preserves the runit backend. Detailed compatibility was not verified. |
| [Dinit](https://davmac.org/projects/dinit/) | A single manager with scripted and process services, multiple dependency relations, readiness, restart controls, and a control socket. | A serious replacement candidate, not a runit extension. It can run below another init. It was researched, not executed here. |
| [OpenRC](https://github.com/OpenRC/openrc) and [Finit](https://github.com/finit-project/finit) | Existing dependency-based service and embedded-init designs. | More host integration than NNS needs to adopt merely to improve its private service tree. Not tested here. |

The distinction is not cosmetic: a TUI over `sv` does not remove lifecycle policy from activation scripts.

The newer [s6-frontend](https://skarnet.org/software/s6-frontend/) combines s6 administration under one command. Its documented prerequisites include s6-rc 0.8, newer than the 0.7 package tested here. It is an operator frontend, not a required component of an s6-rc experiment.

## What the s6-rc experiment proves

`test-s6-rc.py` executes s6-rc 0.7.0.0 and s6 2.15.1.0 as an ordinary host user. The supervision tree is subordinate to the test process, not PID 1.

The tests establish:

- Compilation rejects a dependency cycle.
- A failed oneshot blocks its dependent while an independent branch completes.
- A later explicit transition retries the failed action.
- Another up transition does not repeat successful actions.
- A running longrun does not release its dependent until it sends readiness through its notification descriptor.

This is not a full NNS backend or an Android compatibility test. Automatic retry, Android unlock observation, directory ownership and labels, and update rollback remain NNS integration work.

s6-rc is a transition engine, not a continuously running dependency-policy daemon. Do not assume that a later daemon failure automatically stops every dependent. Dinit explicitly distinguishes lifetime-coupled `depends-on`, startup-only `depends-ms`, and best-effort `waits-for` relations. That distinction matters if NNS requires ongoing failure propagation.

The [s6-rc FAQ](https://skarnet.org/software/s6-rc/faq.html) also documents gradual migration through oneshot wrappers around another manager's start and stop commands. A bridge to runit is therefore possible: use a checked start action and a stop action while s6-rc tracks the graph. Such a bridge does not give a runit longrun s6-native readiness events or a new lifetime contract. It still needs s6 infrastructure for the oneshot runner.

[`s6-rc-update`](https://skarnet.org/software/s6-rc/s6-rc-update.html) reconciles compiled database changes, including removals and service changes. Its documentation also describes limits and partial failures. It is not an ACID transaction or automatic rollback of arbitrary oneshot effects. This task did not execute live database updates.

Nix is a suitable place to generate and compile an immutable service database. Writable live state stays outside the store. This preserves the existing distinction between generated definitions and runtime state.

Boot and unlock need separate target sets. A transition that includes an unlock-blocked prerequisite can wait indefinitely. Do not put such a transition on the synchronous boot activation path.

## Runit's native interface

The documented interface is files and commands, not a supported C library ABI. [`runsv(8)`](https://smarden.org/runit/runsv.8.html) documents `supervise/control`, a named pipe. Single-byte requests include:

| Byte | Request |
|---|---|
| `u` | Run and restart after exit. |
| `d` | Stop and do not restart. |
| `o` | Run once without restarting after exit. |
| `x` | Exit the supervisor after its services are down. |

`service-control.zig` submits these requests without invoking `sv`. It opens the FIFO without blocking, rejects a final symlink, inspects the opened descriptor, rejects non-FIFO files, and writes one byte. It uses POSIX/Linux interfaces, not runit implementation internals.

A successful write is not an acknowledgement that the service reached its requested state. A manager still needs observation, timeouts, and a completion contract. A native client is not automatically a native service manager.

Runit's binary status has daemontools compatibility and runit-specific state. That is not the same as a supported general C API. A new client can use the documented control requests without decoding binary status. If decoding becomes necessary, isolate it and test it against the exact packaged runit version. Calling `sv` is a reasonable compatibility boundary; its human-readable output is also not a typed IPC protocol.

Dinit exposes a Unix control socket used by `dinitctl`. Its source includes client helpers and protocol declarations. That does not establish a separately supported C library ABI. Use the public CLI first unless an external protocol or library contract is verified.

Unlike runit, s6 documents a [libs6 C interface](https://skarnet.org/software/s6/libs6/), including event subscription through `ftrigr`. That is useful for a native client in the s6 ecosystem. It is not evidence that the complete s6-rc transition engine is available as a supported embeddable library.

## A bounded native coordinator

A native coordinator is reasonable only if its policy remains smaller than the existing alternatives. Its useful ownership boundary is:

1. Read one immutable service manifest.
2. Validate references and cycles before mutation.
3. Observe an Android unlock condition as an external event.
4. Reconcile requested service state under one lock.
5. Track finite results by boot and definition generation.
6. Request runit operations and bound their observation time.

Do not let activation and a coordinator independently publish the same service directories. Pick one writer. Do not add new completion files to the generated run scripts while also making a coordinator authoritative over completion.

Readiness, retry limits, interrupted transitions, generation changes, reverse-order stop, and dependent failure policy turn this into a real state machine. A small executable does not imply a small maintenance obligation. If those semantics are required, trial s6-rc or Dinit before implementing them in Zig.

The Zig prototype only tests the control boundary. It is intentionally not the coordinator described above.

## Android constraints and evidence

All runtime evidence here is from Linux host tests. The existing NNS lifecycle fixture uses a rootless user/mount namespace and simulated Android unlock and label operations. It does not establish SELinux or seccomp compatibility for a new manager on cheetah.

Android init remains PID 1. A candidate manager must run inside NNS's namespace and service scope. It must not require taking ownership of Android's mounts, cgroups, boot targets, or host `/etc`. Root execution does not bypass SELinux policy.

Primary references include the project pages above, [runit's FAQ](https://smarden.org/runit/faq.html), [s6 readiness](https://skarnet.org/software/s6/notifywhenup.html), [s6-rc initialization](https://skarnet.org/software/s6-rc/s6-rc-init.html), and [Dinit's service description manual](https://davmac.org/projects/dinit/man-pages-html/dinit-service.5.html). Live project documentation can describe newer releases than the pinned packages used in tests.

Web search was unavailable. Direct upstream pages and GitHub APIs supplied the research. A [free Brave Search API key](https://brave.com/search/api/) can restore general search access.
