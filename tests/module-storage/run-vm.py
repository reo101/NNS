#!/usr/bin/env python3
"""Exercise the Zig module handoff in the disposable, enforcing storage VM."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lab', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
arguments = parser.parse_args()
lab = arguments.lab.resolve(strict=True)
if lab.parent != Path('/home/jeeves/Builds/nns-rom/temporary/module-btrfs/storage-vm'):
    parser.error('A disposable storage VM lab is required')
arguments.output.mkdir(exist_ok=False)
output = arguments.output


def adb(*command, check=True):
    return subprocess.run(['/bin/bash', str(lab / 'export/tests/rom-storage/adb.sh'),
                           str(lab), '-s', 'vsock:3:5555', *command],
                          check=check, capture_output=True, text=True, timeout=120)


def shell(*command):
    return adb('shell', shlex.join(command)).stdout.strip()


assert shell('getprop', 'ro.serialno') == 'CUTTLEFISHCVD01'
assert shell('getprop', 'ro.product.device') == 'vsoc_x86_64'
assert shell('getprop', 'ro.nns.storage.fixture') == '1'
assert shell('getprop', 'ro.adb.secure') == '1'
assert shell('getprop', 'ro.force.debuggable') == '0'
assert shell('getenforce') == 'Enforcing'
assert shell('id', '-u') == '0'
assert 'nns-storage-lab@nns-storage-lab' in shell('cat', '/proc/version')
boot_id = shell('cat', '/proc/sys/kernel/random/boot_id')
guest = '/data/local/tmp/nns-module-storage'
shell('test', '!', '-e', guest)
shell('mkdir', '-m', '0700', guest)
for name in ('nns-storage-supervisor', 'nns-storage-module-controller', 'busybox'):
    adb('push', str(lab / 'artifacts/module-storage' / name), guest + '/' + name)
    shell('chmod', '0755', guest + '/' + name)
controller = guest + '/nns-storage-module-controller'
supervisor = guest + '/nns-storage-supervisor'
shell('chcon', 'u:object_r:nns_storage_exec:s0', controller)


def fixture(action, name):
    subprocess.run(['/bin/bash', str(lab / 'run-fixture.sh'), action,
                    '--output', str(output / (name + '.json'))], check=True, timeout=400)
    return json.loads((output / (name + '.json')).read_text())


def restricted(name, command, expected, succeeds=True):
    log = guest + '/' + name + '.log'
    result = adb('shell', command + ' </dev/null > ' + shlex.quote(log) + ' 2>&1', check=False)
    text = shell('cat', log)
    (output / (name + '.log')).write_text(text + '\n')
    assert (result.returncode == 0) == succeeds, (name, result, text)
    assert expected in text, (name, text)
    assert shell('getprop', 'sys.nns.storage.ready') == '0', 'module controller published a ROM property'


fixture('prepare', 'prepare')
fixture('unmount', 'initial-unmount')
shell('setprop', 'sys.nns.storage.ready', '0')
restricted('direct-controller-refusal', shlex.join([controller, '--check']),
           'only SYS_ADMIN may remain', succeeds=False)
shell('chcon', 'u:object_r:shell_data_file:s0', controller)
restricted('missing-transition-refusal', shlex.join([supervisor, '--check']),
           'nns_storage domain transition is required', succeeds=False)
shell('chcon', 'u:object_r:nns_storage_exec:s0', controller)
restricted('configured-mode', shlex.join([supervisor, '--mode']), 'btrfs')
restricted('unmounted-check-refusal', shlex.join([supervisor, '--check']),
           'configured Btrfs backing is not mounted', succeeds=False)
# Isolate propagation too, so a private mount cannot masquerade as an init mount.
private_command = shlex.join([guest + '/busybox', 'mount', '--make-rprivate', '/']) + ' && exec ' + shlex.quote(supervisor)
restricted('private-parent-mount', shlex.join([guest + '/busybox', 'unshare', '-m', guest + '/busybox', 'sh', '-c', private_command]),
           'Btrfs backing mounted')
assert 'module controller context=u:r:nns_storage:s0 capabilities=SYS_ADMIN' in (output / 'private-parent-mount.log').read_text()
# VM-only observation adapter: emulate the successful module caller's next stage.
shell('setprop', 'sys.nns.storage.ready', '1')
fixture('inspect', 'mounted')
fixture('write', 'written')
fixture('application', 'application')
fixture('unmount', 'unmounted')
shell('setprop', 'sys.nns.storage.ready', '0')
restricted('remount', shlex.join([supervisor]), 'Btrfs backing mounted')
shell('setprop', 'sys.nns.storage.ready', '1')
report = fixture('inspect', 'remounted')
assert report['report']['persistence_matches']
assert report['context']['boot_id'] == boot_id
assert shell('getenforce') == 'Enforcing'
(output / 'result.json').write_text(json.dumps({
    'state': 'module_handoff_passed_in_enforcing_vm', 'boot_id': boot_id,
    'scope': 'su models the root-manager caller; compiled VM policy, not KernelSU loading or phone boot',
}, indent=2) + '\n')
print('PASS: Zig supervisor, capability reduction, enforcing controller, private-parent namespace and storage I/O')
