# Activation language and service-manager experiments

This experiment compares the original runit-only activation. The later [selectable manager integration](../../nix/nns-system/README.md) retains production shell activation and adds native backends. These language rewrites do not implement its migration protocol. They remain comparison programs, not production replacements. The recorded experiment involved no device access, deployment, or commit.

## Run the experiments

From the repository root, run:

```sh
nix run --impure --file experiments/activation/default.nix tests -L
```

`--impure` permits the standalone expression to resolve this checkout and its pinned flake inputs. The experiment does not add flake outputs or change the lock file. Tests run on the host, including rootless user/mount namespaces. They require Linux user namespaces, not sudo.

The runner executes:

| Test group | Coverage |
|---|---|
| Shared activation contract | 28 cases per language, 84 passing cases across shell, Nushell, and Babashka. |
| Real runit lifecycle | Three passing runs of the existing service-resource fixture, one per implementation. |
| Native control client | Nine passing cases: finite exits, longrun control, readiness, and unsafe FIFO paths. |
| s6-rc state transitions | Three passing cases: cycles, finite outcomes, independent branches, and explicit readiness. |

The shared tests cover failed preflight, SSH configuration and host-key persistence, configuration inode preservation, profile publication, stale keys and services, kind transitions, lock serialization, descriptor inheritance, canonical links, and unsafe launcher links. [results.json](results.json) records versions, source hashes, and the result summary.

The real lifecycle fixture also covers retry, unlock, directory reapplication, simulated UID drift, and directory symlink rejection. Its Android properties and label operations are simulated. It is not a phone test. The runner adds a private PID namespace so fixture descendants cannot survive the test.

`default.nix` exposes `versions`, `fixtures`, and `native-control` as separate attributes. The full source rewrites are [activate.nu](activate.nu) and [activate.clj](activate.clj).

## What changed structurally

The original shell script had 227 lines. Validation, publication, supervision, and service policy shared one execution stream. Variables such as `directory` and `entry` change meaning between phases. Several invariants depend on the position of a loop rather than the name of an operation.

The alternatives name those operations. Their common shape is:

```text
validate generation and administrative paths
acquire activation lock and revalidate
prepare state and validate SSH
publish configuration without replacing live directory inodes
publish profiles and keys
remove obsolete services
invalidate all finite results
publish service definitions and reconcile kind changes
start supervision and dispatch finite jobs
wait for the Nix daemon's application-level probe
```

Both implementations retain external `install`, Nix profile operations, and `sv`. A rewrite does not justify replacing reliable platform tools with custom filesystem code.

Both use [process-boundary.sh](process-boundary.sh), a 22-line POSIX adapter for lock descriptor inheritance and detached process creation. It contains no activation or dependency logic. `flock --close` owns the lock outside the interpreter. A detached supervisor gets no activation lock and no SSH input/output descriptors. Retaining flock also preserves lock interoperability with the current shell activation. On a local Linux filesystem, a Java FileChannel lock is not an interchangeable replacement for flock.

Nushell's `job spawn` is not used as a substitute for an independently surviving supervisor. Babashka's subprocess API is not used to invent a new process-launch contract. The adapter makes the Unix boundary explicit and common to both comparisons.

Neither alternative is shorter than the original. Named phases, explicit command failure handling, and revalidation around lock acquisition add source. The improvement is local reasoning, not fewer lines.

## Nushell

Nushell is a good fit for orchestration. Arguments are values, records hold paths and configuration, and a pipeline can filter observations without converting everything through grep. Its syntax remains close to command-oriented work:

```nu
prepare-state $c
publish-configuration $c
publish-profiles $c
publish-keys $c
reconcile-services $c
start-services $c
```

Its useful properties here are typed command parameters, immutable `let` bindings, explicit mutation with `mut`, structured subprocess results, record/table operations, and no shell word splitting. Its built-in argument parser also supplies the entry point's help and mode arguments.

The limits are semantic, not interpreter size:

- External exit status still needs an explicit policy. This prototype captures every command result and checks required operations. A bare external call is not a substitute for that contract.
- Environment mutation has scope. `publish-profiles` uses `def --env` because later phases must inherit the published Nix configuration.
- Value parsing also affects external argument lists. Bare `-0` is numeric zero. The kill probe must use the string `'-0'`. Tests caught the incorrect form during development.
- Filesystem identity and descriptor lifetime remain Unix concerns. A structured pipeline does not make a checked path immune to later replacement.
- Nushell's command language changes. `run` was rejected as a custom command name by the development interpreter. Pin the interpreter and test the exact version.

For a human-facing status command, Nushell is the clear preference. For activation that remains a sequence of external operations, it is also credible. For an expanding graph/state engine, its command-oriented model offers less advantage than it does at the operator interface.

## Babashka

Babashka is a good fit for activation modeled as a program. Configuration is explicit data, functions take that data, and filesystem predicates use `babashka.fs` rather than text output from stat. Service publication uses NIO atomic moves through that library.

The phase calls are ordinary Clojure functions:

```clojure
(prepare-state context)
(publish-generated-etc context)
(publish-profiles context)
(publish-authorized-keys context)
(remove-obsolete-services context)
(invalidate-oneshots context)
(publish-services context)
```

Clojure's immutable maps, sets, vectors, destructuring, and regular function semantics suit graph validation and transition planning. Pure planning can return data before any effect occurs. That separation is a potential next step, not something this faithful rewrite already implements.

The limits are also semantic:

- Subprocesses need a library boundary and an explicit failure policy. This prototype uses `babashka.process`, not shell command strings.
- The language is dynamically typed. A missing map key or unexpected native value still fails at runtime.
- Lazy collections are useful for data, but effects need explicit realization. The prototype uses `doseq` for filesystem effects.
- Java/NIO operations can hide filesystem details unless options are explicit. Link following and atomic replacement require the same care as shell operations.
- Babashka is not the full JVM. Verify the native-image runtime's available classes instead of assuming every Java API exists.
- Macros can improve a real abstraction or create another private service language. The latter is not a maintainability improvement.

The Babashka rewrite is more verbose than the Nushell rewrite. Part of that comes from explicit context and filesystem operations. It does not establish a language-wide code-size result. My preference for a growing activation program is still Babashka: ordinary data transformation and a separate effect boundary fit the problem better.

## What the tests found

A review found a real regression in both initial rewrites: filesystem helpers followed a launcher symlink that the shell script rejected through its permission check. Both alternatives now explicitly reject a symlink launcher, with a regression test.

The contract also tests that profile and service links point to canonical targets, not just equivalent symlink chains. It tests that interpreter reexecution works after PATH is reduced to the immutable system profile. That matches the generated production entry point's environment.

Both alternatives check the exit status of `find`. The original shell pipeline can hide a failing `find` because it does not enable pipefail. A regression case reproduces that difference. The real lifecycle fixture also has a teardown race: runsvdir can replace a supervisor while the fixture stops its children. The experimental runner contains that race with a private PID namespace. Neither observation changes production files in this experiment.

These are parity tests, not a proof of complete security or atomic activation. They do not cover every signal, storage failure, ACL, or concurrent filesystem replacement.

## The service-manager decision is separate

Changing language does not remove distributed lifecycle policy. A nicer `activate` implementation still has to agree with generated `run` and `finish` scripts about completion, retries, and definition changes.

[service-manager-research.md](service-manager-research.md) contains the primary sources, existing projects, control interfaces, and Android constraints. The short conclusion is:

1. Runit already has `once` and executable `check` hooks. Use them before adding another imitation of either.
2. They do not supply graph transitions, generation-specific finite results, or dependency failure policy.
3. s6-rc already supplies much of that state machinery. The local experiment proves finite failure gating and readiness below another init.
4. Dinit is another coherent replacement candidate, with fewer separate tools and explicit dependency types. Its lifetime-coupled dependencies differ from s6-rc's transition model. It was not executed here.
5. A Zig client for runit's FIFO is small. A correct generation-aware dependency coordinator is a separate maintenance commitment.

The implemented [service-control.zig](service-control.zig) is only that small client. It does not parse binary status, supervise processes itself, or claim that a request write means a transition completed.

## Proposed direction

Keep the production backend until a replacement has the same tests and a separate Android trial. If changing the activation language, use Babashka for the state/publication program and Nushell for inspection and operator commands. This is a preference, not an implemented migration.

Before writing a native manager, trial an s6-rc backend generated from the existing Nix service declarations. Its immutable compiled database matches Nix well. Keep the namespace launcher, account trust model, staged configuration, directory resources, and deploy-rs boundary independent of that experiment.

Define boot and unlock targets separately. Define application readiness independently of process existence. Define whether `after` means ordering, successful prerequisite completion, or continued dependency. Those contracts determine maintainability more than the surface syntax does.

If runit must remain, bound a coordinator's responsibilities before implementing it. One component must own service publication and finite-result state. Do not add a second writer beside activation and call the resulting races orchestration.
