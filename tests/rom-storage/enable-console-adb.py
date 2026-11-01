#!/usr/bin/env python3
"""Enable normal authenticated ADB through the disposable VM's serial console."""
import argparse
import json
import os
from pathlib import Path
import re
import select
import time
import tty

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lab', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
arguments = parser.parse_args()
lab = arguments.lab.resolve(strict=True)
if lab.parent != Path('/home/jeeves/Builds/nns-rom/temporary/module-btrfs/storage-vm'):
    parser.error('A disposable storage VM lab is required')
if arguments.output.exists():
    parser.error('Refusing to replace an observation')
console = lab / 'runtime/cuttlefish/instances/cvd-1/console'
descriptor = os.open(console, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)


def exchange(command):
    boundary = 'NNS_STORAGE_CONSOLE_DONE'
    os.write(descriptor, ('\n' + command + "; printf '\\n" + boundary + "\\n'\n").encode())
    output = b''
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        readable, _, _ = select.select([descriptor], [], [], 1)
        if readable:
            output += os.read(descriptor, 65536)
            if boundary in output.decode(errors='replace').replace('\r', '').splitlines():
                return output.decode(errors='replace')
    raise RuntimeError('No console response: ' + output.decode(errors='replace'))


probe = (
    'printf "NNS_FIXTURE=%s\\n" "$(getprop ro.nns.storage.fixture)"; '
    'printf "NNS_DEVICE=%s\\n" "$(getprop ro.product.device)"; '
    'printf "NNS_SERIAL=%s\\n" "$(getprop ro.serialno)"; '
    'printf "NNS_ENFORCE=%s\\n" "$(getenforce)"; '
    'printf "NNS_AUTH=%s\\n" "$(getprop ro.adb.secure)"; '
    'printf "NNS_FORCE=%s\\n" "$(getprop ro.force.debuggable)"; '
    'printf "NNS_BOOT=%s\\n" "$(getprop sys.boot_completed)"; '
    'printf "NNS_ADB=%s\\n" "$(settings get global adb_enabled)"; '
    'printf "NNS_UID=%s\\n" "$(id -u)"; '
    'printf "NNS_CONTEXT=%s\\n" "$(cat /proc/self/attr/current)"'
)
try:
    tty.setraw(descriptor)
    before = exchange(probe)
    fields = dict(re.findall(r'^NNS_(\w+)=(.*)$', before.replace('\r', ''), re.MULTILINE))
    expected = {'FIXTURE': '1', 'DEVICE': 'vsoc_x86_64', 'SERIAL': 'CUTTLEFISHCVD01',
                'ENFORCE': 'Enforcing', 'AUTH': '1', 'BOOT': '1'}
    if any(fields.get(name) != value for name, value in expected.items()) or fields.get('FORCE') not in ('', '0'):
        raise RuntimeError('Console is not the ready, enforcing, authenticated VM: ' + before)
    action = exchange('settings put global adb_enabled 1; '
                      'printf "NNS_RESULT=%s\\n" "$?"')
    if not re.search(r'^NNS_RESULT=0\r?$', action, re.MULTILINE):
        raise RuntimeError('Normal ADB enablement failed: ' + action)
    after = exchange(probe)
    fields = dict(re.findall(r'^NNS_(\w+)=(.*)$', after.replace('\r', ''), re.MULTILINE))
    if fields.get('ADB') != '1' or fields.get('AUTH') != '1' or fields.get('ENFORCE') != 'Enforcing':
        raise RuntimeError('ADB, authentication or enforcement did not retain the expected state: ' + after)
finally:
    # Leave echo disabled so forwarded console output cannot become guest input.
    os.close(descriptor)
with arguments.output.open('x') as stream:
    json.dump({'before': before, 'action': action, 'after': after}, stream, indent=2)
    stream.write('\n')
print('PASS: enabled normal ADB without changing authentication, enforcement or force-debug state')
