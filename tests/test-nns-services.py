"""Exercise generated jobs with real runit in a private rootless namespace."""
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time

helper, generation = sys.argv[1:3]
if '--inside' not in sys.argv:
    with tempfile.TemporaryDirectory(prefix='nns-service-test-') as scratch:
        result = subprocess.run([
            'unshare', '--user', '--map-root-user', '--mount', '--fork', helper,
            '--store', '/nix', '--tmpdir', scratch, '--', sys.executable,
            str(Path(__file__).resolve()), helper, generation, '--inside',
        ], capture_output=True, text=True, timeout=100)
        print(result.stdout, end='')
        print(result.stderr, end='', file=sys.stderr)
        assert not list(Path(scratch).glob('nns.*')), 'scratch directory leaked'
        raise SystemExit(result.returncode)

for name in ('/data', '/system'):
    Path(name).mkdir(exist_ok=True)
    subprocess.run(['mount', '-t', 'tmpfs', '-o', 'mode=755', 'tmpfs', name], check=True)
base = Path('/data/nns-service-test')
base.mkdir()
source_generation = generation
generation = str(base / 'generation')
shutil.copytree(source_generation, generation, symlinks=True)
(base / 'bin').mkdir()
launcher = base / 'bin/launcher'
launcher.write_text('#!/bin/sh\nshift 2\nexec "$@"\n')
launcher.chmod(0o755)
system_bin = Path('/system/bin')
system_bin.mkdir()
getprop = system_bin / 'getprop'
getprop.write_text('#!/bin/sh\nif test -f /data/nns-service-test/unlocked; then echo true; else echo false; fi\n')
getprop.chmod(0o755)
stat = system_bin / 'stat'
stat.write_text('''#!/bin/sh
if test -f /data/nns-service-test/uid-drift; then
  printf '9999:9999:u:object_r:app_data_file:s0\\n'
else
  printf '0:0:u:object_r:app_data_file:s0\\n'
fi
''')
stat.chmod(0o755)
chcon = system_bin / 'chcon'
chcon.write_text('''#!/bin/sh
printf '%s %s\\n' "$1" "$(readlink "$2")" >> /data/nns-service-test/labels
''')
chcon.chmod(0o755)
services = base / 'state/services'
sv = str(Path(generation) / 'system-profile/bin/sv')


def activate(mode='switch'):
    result = subprocess.run([str(Path(generation) / 'activate'), mode],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr


def wait_for(predicate, description):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(description + '\n' + (base / 'state/supervisor.log').read_text())


def completed(name):
    return (services / name / 'completed').exists()


def stopped(name):
    return subprocess.check_output([sv, 'status', str(services / name)], text=True).startswith('down:')


def failure(name):
    path = services / name / 'exit-status'
    return path.exists() and path.read_text().split()[0] != '0'


try:
    activate()
    wait_for(lambda: failure('prepare'), 'failed job did not report its status')
    assert not completed('prepare')
    assert not (base / 'consumer-ready').exists(), 'dependency started before successful completion'
    assert not completed('unlocked')
    assert not (base / 'labeled').exists(), 'unlock-gated directory appeared before unlock'
    wait_for(lambda: completed('directory-shared') and stopped('directory-shared'),
             'directory job did not complete without a resident process')
    assert (base / 'shared').stat().st_mode & 0o7777 == 0o710

    (base / 'release').touch()
    wait_for(lambda: completed('prepare') and stopped('prepare'), 'failed job did not retry successfully')
    wait_for(lambda: (base / 'consumer-ready').exists(), 'dependent long-running process did not start')
    count = len((base / 'attempts').read_text().splitlines())
    assert count >= 2
    time.sleep(1.2)
    assert len((base / 'attempts').read_text().splitlines()) == count, 'successful job restarted'

    (base / 'unlocked').touch()
    wait_for(lambda: completed('unlocked') and completed('directory-labeled'), 'unlock jobs did not complete')
    assert 'u:object_r:app_data_file:s0 /data/nns-service-test/labeled' in (base / 'labels').read_text()

    (base / 'shared').chmod(0o777)
    activate()
    wait_for(lambda: completed('directory-shared') and (base / 'shared').stat().st_mode & 0o7777 == 0o710,
             'activation did not reapply directory metadata')
    wait_for(lambda: completed('prepare'), 'activation did not rerun finite jobs')
    assert len((base / 'attempts').read_text().splitlines()) > count

    (base / 'uid-drift').touch()
    (base / 'labeled').rmdir()
    activate()
    wait_for(lambda: failure('directory-labeled'), 'account identity mismatch did not fail')
    assert not completed('directory-labeled') and not (base / 'labeled').exists()
    (base / 'uid-drift').unlink()
    wait_for(lambda: completed('directory-labeled'), 'directory job did not recover after identity correction')

    (base / 'shared').rmdir()
    victim = base / 'victim'
    victim.mkdir(mode=0o755)
    victim.chmod(0o777)
    (base / 'shared').symlink_to(victim)
    activate()
    wait_for(lambda: failure('directory-shared'), 'symlink directory was accepted')
    assert victim.stat().st_mode & 0o7777 == 0o777, 'resource job changed the symlink target'
    (base / 'shared').unlink()
    wait_for(lambda: completed('directory-shared'), 'directory job did not recover after removing symlink')

    base.chmod(0o777)
    subprocess.run([sv, 'up', str(services / 'directory-shared')], check=True)
    wait_for(lambda: failure('directory-shared'), 'writable parent directory was accepted')
    base.chmod(0o755)
    wait_for(lambda: completed('directory-shared'), 'directory job did not recover after securing parent')

    # Changing kind must replace the finish handler and the requested state.
    prepare = Path(generation) / 'services/prepare'
    original_run = (prepare / 'run').readlink()
    original_finish = (prepare / 'finish').readlink()
    (prepare / 'oneshot').unlink()
    (prepare / 'finish').unlink()
    (prepare / 'run').unlink()
    (prepare / 'run').write_text('#!/bin/sh\nexec sleep 3600\n')
    (prepare / 'run').chmod(0o755)
    activate()
    assert not (services / 'prepare/oneshot').exists()
    assert not (services / 'prepare/finish').exists()
    assert not (services / 'prepare/down').exists()
    assert not completed('prepare')
    assert not stopped('prepare')
    (prepare / 'run').unlink()
    (prepare / 'run').symlink_to(original_run)
    (prepare / 'finish').symlink_to(original_finish)
    (prepare / 'oneshot').touch()
    activate()
    wait_for(lambda: completed('prepare') and stopped('prepare'), 'longrun-to-oneshot transition failed')

    (base / 'unlocked').unlink()
    activate('boot')
    assert not completed('unlocked'), 'boot reused stale unlock completion'
    (base / 'unlocked').touch()
    wait_for(lambda: completed('unlocked'), 'boot did not dispatch unlock job')
    print('PASS: real runit completion, retry, dependencies, unlock, reapplication, UID drift, and symlink rejection')
finally:
    if services.exists():
        for service in services.iterdir():
            subprocess.run([sv, '-w', '3', 'force-shutdown', str(service)], capture_output=True)
    pidfile = base / 'state/supervisor.pid'
    if pidfile.exists():
        try:
            os.kill(int(pidfile.read_text()), signal.SIGTERM)
        except ProcessLookupError:
            pass
