#!/usr/bin/env python3
"""Exercise init-controlled mount refusal fixtures in the disposable ROM VM."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb', required=True)
parser.add_argument('--kernel-log', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
arguments = parser.parse_args()
if not os.environ.get('ADB_SERVER_SOCKET', '').startswith('localfilesystem:/tmp/nns-cuttlefish-runtime-'):
    parser.error('An isolated NNS VM ADB server is required')
arguments.output.mkdir(mode=0o700)


def adb(*command, check=True):
    result = subprocess.run([arguments.adb, '-s', 'vsock:3:5555', *command],
                            text=True, capture_output=True, timeout=15)
    if check and result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result


assert adb('get-state').stdout.strip() == 'device'
assert adb('shell', 'getprop', 'ro.serialno').stdout.strip() == 'CUTTLEFISHCVD01'
assert adb('shell', 'getenforce').stdout.strip() == 'Enforcing'


def report():
    result = adb('shell', 'cat', '/data/nns-fixture/report.json', check=False)
    return json.loads(result.stdout) if result.returncode == 0 else None


def action(name, exit_status, observation=True, record_name=None):
    record_name = record_name or name
    previous = report()
    offset = arguments.kernel_log.stat().st_size
    adb('shell', 'setprop', 'sys.nns.fixture.action', name)
    deadline = time.monotonic() + 30
    while True:
        with arguments.kernel_log.open('rb') as stream:
            stream.seek(offset)
            kernel = stream.read().decode(errors='replace')
        observed = report() if observation else None
        exited = re.search(r"Service 'nns-mount'.*exited with status " + str(exit_status) + r'\b', kernel)
        updated = not observation or (observed and
            (previous is None or observed['record_time_ns'] != previous['record_time_ns']))
        if exited and updated:
            break
        if time.monotonic() >= deadline:
            (arguments.output / (record_name + '.log')).write_text(kernel)
            raise RuntimeError('Missing expected init service outcome for ' + name + '\n' + kernel)
        time.sleep(0.25)
    (arguments.output / (record_name + '.log')).write_text(kernel)
    if observed:
        (arguments.output / (record_name + '.json')).write_text(json.dumps(observed, indent=2) + '\n')
        assert observed['domain'] == 'u:r:nns_fixture:s0'
        assert observed['selinux_enforcing'] is True
    return observed


def same_backing(expected, actual, renamed=False):
    for name in ('backing', 'fixture_file'):
        ignored = {'device', 'mtime_ns', 'ctime_ns'} if renamed and name == 'backing' else {'device'}
        before, after = expected[name], actual[name]
        assert {key: value for key, value in before.items() if key not in ignored} == {
            key: value for key, value in after.items() if key not in ignored}, name


def valid_bind(observed):
    assert observed['mount_count'] == 1
    assert observed['backing'] == observed['target']
    assert adb('shell', 'getenforce').stdout.strip() == 'Enforcing'


baseline = report()
assert baseline and baseline['backing']['fscrypt_policy_hex'] and baseline['fixture_file']
valid_bind(baseline)
assert adb('shell', 'setprop', 'sys.nns.fixture.moved', '1', check=False).returncode != 0, \
    'ADB shell must not request creation of the invalid backing fixture'

conflict = action('conflicting-mount', 1)
assert conflict['mount_count'] == 1
assert conflict['backing']['inode'] != conflict['target']['inode']
same_backing(baseline, conflict)
restored = action('restore-mount', 0, record_name='conflicting-mount-restored')
valid_bind(restored)
same_backing(baseline, restored)

stacked = action('stacked-mount', 1)
assert stacked['mount_count'] == 2
assert stacked['backing'] == stacked['target']
same_backing(baseline, stacked)
restored = action('restore-mount', 0, record_name='stacked-mount-restored')
valid_bind(restored)
same_backing(baseline, restored)

action('invalid-backing', 1, observation=False)
restored = action('restore-backing', 0)
valid_bind(restored)
# Cross-parent F2FS directory renames change mtime and ctime through the '..' entry.
# These fixture operations must retain all other backing fields and all file fields.
same_backing(baseline, restored, renamed=True)
print('PASS: enforcing init rejects conflicting, stacked and invalid-backing fixtures without repairing the store')
