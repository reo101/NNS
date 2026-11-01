# Android module handoff validation

This Android harness depends on the disposable ROM storage lab under
`tests/rom-storage/`. The standalone Linux handoff check is `handoff.nix`.

`controller.te` is a disposable userdebug VM policy fragment. It uses `su` to
represent the privileged root-manager caller and reuses the existing enforcing
controller domain. It does not add mount or ioctl permissions. It is not a phone
policy file and does not test the KernelSU policy loader.

The enforcing Android run rejects direct controller execution with excess
capabilities and execution without the expected domain transition. The supervisor
mounts from a parent with a private namespace and isolated mount propagation.
Encrypted-image reads, writes, application execution, private-image access denial
and unmount/remount persistence pass. The fixture's caller publishes the ROM
readiness property only after the module controller returns successfully. The
module controller does not publish that property itself. The separate ROM
controller retains its init-provided descriptor path.

The phone's read-only inspection found a different root-shell mount namespace
from init. Its `ksud` parser accepts the required rule syntax, but parser success
does not prove that a rule reached the live policy. Hardware testing needs a
separate policy decision and checks of the actual loaded permissions. The phone
remained unchanged during these VM checks.
