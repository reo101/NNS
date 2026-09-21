# Executed by the NixOS test driver; spec and the cache machine are injected.
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

sdk = Path(spec['sdk'])
work = Path(tempfile.mkdtemp(prefix='nns-android-'))
print('Android test artifacts:', work)
env = os.environ.copy()
env.update(ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk),
           ANDROID_AVD_HOME=str(work / 'avd'), ANDROID_EMULATOR_HOME=str(work / 'home'),
           ANDROID_ADB_SERVER_PORT='15038', ADB_SERVER_PORT='15038',
           ADB_VENDOR_KEYS=str(work / 'keys'),
           # The nix build sandbox sets HOME to a nonexistent path; adb and the
           # emulator both mkdir under it. Reuse the emulator home directory.
           HOME=str(work / 'home'), ANDROID_PREFS_ROOT=str(work / 'home'))
# avdmanager needs java; provide it explicitly so the test also runs in the
# nix build sandbox (android-vm-test), not just the interactive driver.
if spec.get('java'):
    env['JAVA_HOME'] = spec['java']
    env['PATH'] = spec['java'] + '/bin:' + env.get('PATH', '')
for name in ('avd', 'home', 'keys'):
    (work / name).mkdir()
adb_base = [str(sdk / 'platform-tools/adb'), '-P', '15038', '-s', 'emulator-5582']


def run(args, *, check=True, timeout=120, input=None):
    r = subprocess.run([str(a) for a in args], env=env, input=input, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(f'{args}: exit {r.returncode}\n{r.stdout}')
    return r


def adb(*args, **kwargs):
    return run(adb_base + list(args), **kwargs)


def shell(command, **kwargs):
    return adb('shell', 'set -e\n' + command, **kwargs).stdout.strip()


def ksu(command):
    # adb root is already UID 0, but in AOSP's su domain. Enter the real KSU
    # domain for setup/daemon sockets; do not ask KSU to grant root to an
    # unapproved UID/domain. App test commands never use this route.
    return adb('shell', 'runcon u:r:ksu:s0 /system/bin/sh',
               input='set -e\n' + command + '\nexit\n').stdout


def wait_boot():
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        if emulator.poll() is not None:
            raise RuntimeError('emulator exited: ' + (work / 'emulator.log').read_text()[-12000:])
        r = adb('shell', 'getprop sys.boot_completed', check=False, timeout=10)
        if r.returncode == 0 and r.stdout.strip() == '1':
            return
        time.sleep(2)
    raise RuntimeError('Android boot timeout')


start_all()
cache.wait_for_unit('nix-serve.service')
cache.wait_for_unit('dnsmasq.service')
public_key = cache.succeed('cat /run/nns-cache.pub').strip()
assert os.access('/dev/kvm', os.R_OK | os.W_OK), 'KVM is required; no TCG fallback'
avdmanager, = sdk.glob('cmdline-tools/*/bin/avdmanager')
run([avdmanager, 'create', 'avd', '--force', '--name', 'nns-test',
     '--package', 'system-images;android-35;google_apis;x86_64', '--device', 'pixel'], input='no\n')
config = work / 'avd/nns-test.avd/config.ini'
config.write_text(config.read_text() + '\ndisk.dataPartition.size=4G\nhw.ramSize=2048\n')
adb('start-server')
emulator_log = (work / 'emulator.log').open('w')
emulator = subprocess.Popen([str(sdk / 'emulator/emulator'), '-avd', 'nns-test',
    '-kernel', spec['kernel'], '-no-window', '-no-snapshot', '-no-audio', '-no-boot-anim',
    '-gpu', 'swiftshader', '-no-metrics', '-accel', 'on', '-memory', '2048', '-cores', '2',
    '-port', '5582', '-dns-server', '127.0.0.1', '-show-kernel'],
    env=env, stdout=emulator_log, stderr=subprocess.STDOUT)
try:
    with subtest('boot patched Android with enforcing SELinux'):
        wait_boot()
        adb('root')
        adb('wait-for-device', timeout=30)
        assert shell('id -u') == '0'
        assert shell('getenforce') == 'Enforcing'
        shell('auditctl -r 0')
        assert 'CONFIG_USER_NS=y' in shell('zcat /proc/config.gz | grep CONFIG_USER_NS')
        shell('test -w /proc/sys/kernel/seccomp_bypass_paths')
        # Only inside this disposable Android VM. Route netd DNS to the sibling
        # fixture through high host ports, without requiring host root or KVM nesting.
        shell('settings put global private_dns_mode off')
        for proto in ('udp', 'tcp'):
            # Leave glibc's missing-resolv.conf fallback (127.0.0.1) alone.
            shell(f'iptables -t nat -A OUTPUT -d 10.0.2.3 -p {proto} --dport 53 -j DNAT --to-destination 10.0.2.2:31553')

    with subtest('install the real module and register a canonical store'):
        adb('push', spec['ksud'], '/data/local/tmp/ksud')
        shell('chmod 755 /data/local/tmp/ksud; /data/local/tmp/ksud install')
        assert ksu('id -u').strip() == '0'
        assert 'u:r:ksu:s0' in ksu('id -Z')
        adb('push', str(Path(spec['module']).parent / 'nns-module.zip'), '/data/local/tmp/nns-module.zip')
        ksu('/data/adb/ksud module install /data/local/tmp/nns-module.zip')
        adb('push', str(Path(spec['seed']) / 'store.tar.gz'), '/data/local/tmp/nns-store.tar.gz')
        adb('push', str(Path(spec['seed']) / 'registration'), '/data/local/tmp/nns-registration')
        ksu('tar -xzf /data/local/tmp/nns-store.tar.gz -C /data; '
            'mkdir -p /data/nix/var/nix/profiles; '
            f'ln -s {shlex.quote(spec["bootstrap"])} /data/nix/var/nix/profiles/profile; '
            '/data/adb/ksud post-fs-data')
        shell('test -x /data/nix/bin/nix-enter; test -f /data/nix/lib/libnns-dns.so')
        # Keep normal signature checking: the only trusted key is this VM's.
        config_text = ('build-users-group =\nsandbox = false\n'
                       'experimental-features = nix-command flakes\n'
                       'substituters = http://nns-cache.test:31080\n'
                       f'trusted-public-keys = {public_key}\n')
        local_config = work / 'nix.conf'
        local_config.write_text(config_text)
        adb('push', str(local_config), '/data/nix/etc/nix/nix.conf')
        ksu('/data/nix/bin/nix-enter --tmpdir /data/nix/tmp -- '
            'env NIX_CONF_DIR=/data/nix/etc/nix NIX_REMOTE=local '
            f'{spec["nix"]}/bin/nix-store --load-db < /data/local/tmp/nns-registration')
        ksu('/data/nix/bin/nix-enter --tmpdir /data/nix/tmp -- '
            'env NIX_CONF_DIR=/data/nix/etc/nix NIX_REMOTE=local '
            f'{spec["nix"]}/bin/nix-store --verify --check-contents')
        assert shell(f'test ! -e /data{spec["hello"]}; echo absent') == 'absent'
        adb('push', spec['appFlow'], '/data/nix/etc/test-app.sh')
        ksu('chmod 644 /data/nix/etc/test-app.sh; '
            'chcon u:object_r:system_file:s0 /data/nix/etc/test-app.sh; '
            '/data/adb/ksud services')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if adb('shell', 'test -S /data/nix/var/nix/daemon-socket/socket', check=False).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError('daemon did not start:\n' + shell('cat /data/local/tmp/nix-service.log /data/local/tmp/nix-daemon.log', check=False))

    with subtest('real app fails without seccomp bypass'):
        adb('install', spec['apk'])
        ksu('printf "\\n" > /proc/sys/kernel/seccomp_bypass_paths')
        r = adb('shell', 'am instrument -w -e mode blocked xyz.reo101.nnstest/.Probe', timeout=150)
        (work / 'blocked.log').write_text(r.stdout)
        assert 'NNS-BLOCKED-PASS' in r.stdout, r.stdout

    with subtest('real app userns, Bionic DNS, daemon substitution and profile'):
        ksu('echo /data/nix/bin/nix-enter > /proc/sys/kernel/seccomp_bypass_paths')
        for attempt in range(2):
            r = adb('shell', 'am instrument -w -e mode full xyz.reo101.nnstest/.Probe', timeout=150)
            (work / f'app-{attempt}.log').write_text(r.stdout)
            assert 'NNS-INSTRUMENTATION-PASS' in r.stdout, r.stdout
        assert shell('getenforce') == 'Enforcing'
        shell('test ! -e /nix')
        cache.succeed('journalctl -u dnsmasq --no-pager | grep nns-cache.test')
finally:
    for name, command in {'logcat': 'logcat -d', 'dmesg': 'dmesg',
                          'daemon': 'cat /data/local/tmp/nix-daemon.log',
                          'service': 'cat /data/local/tmp/nix-service.log'}.items():
        try:
            (work / (name + '.log')).write_text(shell(command, check=False, timeout=10))
        except Exception as exc:
            print('diagnostic collection:', exc)
    try:
        adb('emu', 'kill', check=False, timeout=10)
    except subprocess.TimeoutExpired:
        emulator.terminate()
    try:
        emulator.wait(timeout=15)
    except subprocess.TimeoutExpired:
        emulator.kill()
        emulator.wait(timeout=10)
    emulator_log.close()
    try:
        adb('kill-server', check=False, timeout=10)
    except subprocess.TimeoutExpired:
        print('private adb shutdown timed out')
    shutil.rmtree(work / 'avd', ignore_errors=True)
    if os.environ.get('out'):
        shutil.copytree(work, Path(os.environ['out']) / 'android', dirs_exist_ok=True)
    print('Android logs:', work)
