#!/usr/bin/env python3
"""Run signing-state fixtures only through an isolated Cuttlefish ADB server."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

PACKAGES = ('org.nns.signing.system', 'org.nns.signing.application')
SERIAL = 'vsock:3:5555'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--phase', choices=('seed', 'verify'), required=True)
    parser.add_argument('--application-apk', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.phase == 'seed' and (not arguments.application_apk or not arguments.application_apk.is_file()):
        parser.error('The ordinary fixture APK is required for seeding')
    if not os.environ.get('ADB_SERVER_SOCKET', '').startswith('localfilesystem:/tmp/nns-signing-lab-'):
        parser.error('An isolated signing-lab ADB socket is required')
    if os.environ.get('ADB_USB') != '0' or os.environ.get('ADB_MDNS') != '0':
        parser.error('USB and mDNS discovery must be disabled')
    context_path = arguments.output.with_suffix('.context.json')
    logs = [arguments.output.with_name(arguments.output.stem + '.' + package + '.txt') for package in PACKAGES]
    if any(path.exists() for path in [arguments.output, context_path, *logs]):
        parser.error('Refusing to replace prior observations')

    def adb(*command, check=True, timeout=30):
        return subprocess.run([arguments.adb, '-s', SERIAL, *command], check=check,
                              capture_output=True, text=True, timeout=timeout)

    def shell(*command):
        return adb('shell', *command).stdout.strip()

    def require_device():
        if shell('getprop', 'ro.serialno') != 'CUTTLEFISHCVD01' or shell('getprop', 'ro.product.device') != 'vsoc_x86_64':
            raise RuntimeError('Target is not the signing-lab Cuttlefish device')
        if shell('getenforce') != 'Enforcing' or shell('getprop', 'sys.boot_completed') != '1':
            raise RuntimeError('An enforcing, fully booted guest is required')
        if shell('getprop', 'ro.adb.secure') != '1' or shell('getprop', 'ro.force.debuggable') != '0':
            raise RuntimeError('Normal ADB authentication must remain enabled without a force-debug override')

    require_device()
    root_result = adb('root', check=False)
    for _ in range(30):
        subprocess.run([arguments.adb, 'connect', SERIAL], capture_output=True, timeout=15)
        if adb('shell', 'id', '-u', check=False).stdout.strip() == '0':
            break
        time.sleep(1)
    else:
        raise RuntimeError('Lab adbd did not restart as root: ' + root_result.stdout + root_result.stderr)
    require_device()
    for _ in range(120):
        if (shell('am', 'get-started-user-state', '0') == 'RUNNING_UNLOCKED'
                and shell('getprop', 'sys.user.0.ce_available') == 'true'):
            break
        time.sleep(1)
    else:
        raise RuntimeError('Lab user 0 did not unlock credential-encrypted storage')
    if shell('getprop', 'ro.nns.mount.owner') != 'init':
        raise RuntimeError('Updated ROM mount ownership declaration is missing')
    current_namespace = shell('readlink', '/proc/self/ns/mnt')
    if not current_namespace or current_namespace != shell('readlink', '/proc/1/ns/mnt'):
        raise RuntimeError('Lab shell is not in the init mount namespace')
    adb('shell', '/system/bin/nns-mount', '--check')
    if adb('shell', 'setprop', 'ro.nns.mount.owner', 'init', check=False).returncode == 0:
        raise RuntimeError('The ownership property unexpectedly accepted a write')
    if shell('getprop', 'ro.nns.mount.owner') != 'init':
        raise RuntimeError('Ownership declaration changed')
    context = {'serial': SERIAL, 'boot_id': shell('cat', '/proc/sys/kernel/random/boot_id'),
               'selinux': shell('getenforce'), 'mount_owner': 'init',
               'system_fingerprint': shell('getprop', 'ro.system.build.fingerprint'),
               'build_incremental': shell('getprop', 'ro.build.version.incremental'),
               'user_state': 'RUNNING_UNLOCKED',
               'adb_secure': shell('getprop', 'ro.adb.secure'),
               'force_debuggable': shell('getprop', 'ro.force.debuggable'),
               'adbd_uid': shell('id', '-u'),
               'read_only_property_write_refused': True}
    if arguments.phase == 'seed':
        if 'package:' + PACKAGES[1] in shell('pm', 'list', 'packages', PACKAGES[1]).splitlines():
            raise RuntimeError('Ordinary fixture already exists; do not reseed userdata')
        adb('install', '-t', '--no-streaming', str(arguments.application_apk), timeout=120)
        adb('shell', 'pm', 'grant', PACKAGES[1], 'android.permission.POST_NOTIFICATIONS')
    reports = {}
    for package, log in zip(PACKAGES, logs):
        result = adb('shell', 'am', 'instrument', '-w', '-r', '-e', 'phase', arguments.phase,
                     package + '/org.nns.signing.SigningStateInstrumentation', timeout=120)
        with log.open('x') as stream:
            stream.write(result.stdout + result.stderr)
        prefix = 'INSTRUMENTATION_RESULT: nns.signing.state='
        lines = [line[len(prefix):] for line in result.stdout.splitlines() if line.startswith(prefix)]
        if len(lines) != 1 or 'INSTRUMENTATION_CODE: -1' not in result.stdout:
            raise RuntimeError('Instrumentation did not complete: ' + package)
        report = json.loads(lines[0])
        if report.get('passed') is not True or report.get('package') != package or report.get('phase') != arguments.phase:
            raise RuntimeError('Fixture failed: ' + json.dumps(report))
        reports[package] = report
    with arguments.output.open('x') as stream:
        stream.write(json.dumps(reports, indent=2) + '\n')
    with context_path.open('x') as stream:
        stream.write(json.dumps(context, indent=2) + '\n')
    print('PASS: lab identity, enforcing boot, ROM ownership checks and fixture state')


if __name__ == '__main__':
    main()
