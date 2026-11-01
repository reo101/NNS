#!/usr/bin/env python3
"""Operate only the authenticated, disposable Cuttlefish storage fixture."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=('prepare', 'inspect', 'mount', 'write', 'unmount', 'application'))
parser.add_argument('--adb', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--locked', action='store_true')
parser.add_argument('--baseline', type=Path)
arguments = parser.parse_args()
if arguments.output.exists():
    parser.error('Refusing to replace an observation')
if (not os.environ.get('ADB_SERVER_SOCKET', '').startswith('localfilesystem:/tmp/nns-storage-vm-')
        or os.environ.get('ADB_USB') != '0' or os.environ.get('ADB_MDNS') != '0'):
    parser.error('An isolated storage VM ADB socket with USB and mDNS disabled is required')


def adb(*command, check=True):
    return subprocess.run([arguments.adb, '-s', 'vsock:3:5555', *command], check=check,
                          capture_output=True, text=True, timeout=120)


def shell(*command):
    return adb('shell', *command).stdout.strip()


if (shell('getprop', 'ro.serialno') != 'CUTTLEFISHCVD01'
        or shell('getprop', 'ro.product.device') != 'vsoc_x86_64'
        or shell('getprop', 'ro.nns.storage.fixture') != '1'):
    raise RuntimeError('Target is not the disposable storage VM')
if shell('getenforce') != 'Enforcing' or shell('getprop', 'ro.adb.secure') != '1':
    raise RuntimeError('Enforcement and normal ADB authentication are required')
if shell('getprop', 'ro.force.debuggable') not in ('', '0'):
    raise RuntimeError('A force-debug override is not permitted')
if shell('getprop', 'ro.nns.mount.owner') != 'init':
    raise RuntimeError('The ROM does not own the canonical mount')
if 'nns-storage-lab@nns-storage-lab' not in shell('cat', '/proc/version'):
    raise RuntimeError('The prepared storage kernel is not running')
context = {
    'boot_id': shell('cat', '/proc/sys/kernel/random/boot_id'),
    'user_state': shell('am', 'get-started-user-state', '0'),
    'ce_available': shell('getprop', 'sys.user.0.ce_available'),
    'adb_uid': shell('id', '-u'), 'selinux': 'Enforcing',
    'kernel_version': shell('cat', '/proc/version'),
}
if context['adb_uid'] != '0':
    raise RuntimeError('Request authenticated adb root before operating the fixture')
if arguments.locked and (context['user_state'] != 'RUNNING_LOCKED' or context['ce_available'] == 'true'):
    raise RuntimeError('A cold boot with user 0 still credential-locked is required')

if arguments.action == 'application':
    result = adb('shell', 'am', 'broadcast', '--user', '0', '--include-stopped-packages',
                 '-n', 'org.nns.storage.fixture/.StorageReceiver', '-a', 'org.nns.storage.PROBE')
    match = re.search(r'Broadcast completed: result=-1, data="(.*)"', result.stdout)
    if not match:
        raise RuntimeError('Application receiver failed: ' + result.stdout + result.stderr)
    report = json.loads(match.group(1))
else:
    def read_report():
        result = adb('shell', 'cat', '/data/nns-storage-results/report.json', check=False)
        try:
            return json.loads(result.stdout) if result.returncode == 0 else None
        except json.JSONDecodeError:
            return None

    previous = read_report()
    adb('shell', 'setprop', 'sys.nns.storage.fixture.action', arguments.action)
    deadline = time.monotonic() + (300 if arguments.action == 'prepare' else 120)
    while True:
        report = read_report()
        fresh = report and (previous is None or report['record_time_ns'] != previous['record_time_ns'])
        expected_action = report and (report['action'] == arguments.action or
                                      arguments.action == 'mount' and report['action'] == 'runtime')
        mounted = report and report['backing_mounts'] == report['bind_mounts'] == 1
        if fresh and expected_action and (arguments.action != 'mount' or mounted):
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('No completed fixture observation: ' + json.dumps(report))
        time.sleep(0.25)

observation = {'request': arguments.action, 'context': context, 'report': report}
with arguments.output.open('x') as output:
    json.dump(observation, output, indent=2)
    output.write('\n')
if arguments.action == 'application':
    assert report['exit_code'] == 0 and report['private_image_denied'] is True, report
    assert report['device_protected'] is True, report
    assert report['uid'] >= 10000, report
    assert f'uid={report["uid"]} gid={report["uid"]} context=u:r:platform_app:' in report['output'], report
    assert 'filesystem=9123683e' in report['output'], report
    if arguments.locked:
        assert report['user_unlocked'] is False, report
else:
    assert report['domain'] == 'u:r:nns_storage_fixture:s0' and report['selinux_enforcing'], report
    assert report['directory_policy'].startswith('02') and report['directory_policy_error'] == 0, report
    assert report['image_policy_error'] == 0, report
    assert report['image_policy'] == report['directory_policy'], report
    if arguments.action in ('inspect', 'mount', 'write'):
        assert report['ready'] == '1' and report['filesystem'] == 0x9123683e, report
        assert report['backing_mounts'] == report['bind_mounts'] == 1, report
        assert report['backing_inode'] == report['target_inode'] == 256, report
        assert report['backing_device'] == report['target_device'], report
        assert report['mount_flags'] & 15 == 6, report
        assert report['marker_matches'] and report['runtime_marker_matches'], report
    if arguments.action == 'write':
        assert report['persistence_matches'], report
    if arguments.action == 'unmount':
        assert report['backing_mounts'] == report['bind_mounts'] == 0, report
if arguments.baseline:
    baseline = json.loads(arguments.baseline.read_text())
    if arguments.action == 'application':
        assert baseline['report']['uid'] == report['uid'], report
    else:
        for field in ('directory_policy', 'image_policy', 'backing_inode', 'target_inode',
                      'marker_matches', 'persistence_matches'):
            assert baseline['report'][field] == report[field], field
print('PASS: isolated storage fixture, caller identity and requested state checks')
