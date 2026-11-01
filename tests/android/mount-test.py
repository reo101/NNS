"""Disposable Android test of the ROM mount helper; never selects a phone."""
from concurrent.futures import ThreadPoolExecutor
import atexit
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time

spec = json.loads(Path(sys.argv[1]).read_text())
sdk = Path(spec['sdk'])
integration = Path(spec['integration'])
work = Path(tempfile.mkdtemp(prefix='nns-android-mount-'))
print('Android mount artifacts:', work, flush=True)


def cleanup_images():
    # Also runs when preparation fails before the emulator's try/finally.
    for directory in ('avd', 'partitions'):
        shutil.rmtree(work / directory, ignore_errors=True)
    for name in ('system.img', 'super.img'):
        (work / name).unlink(missing_ok=True)


atexit.register(cleanup_images)
env = os.environ.copy()
env.update(ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk),
           ANDROID_AVD_HOME=str(work / 'avd'), ANDROID_EMULATOR_HOME=str(work / 'home'),
           ANDROID_ADB_SERVER_PORT='15039', ADB_SERVER_PORT='15039',
           ADB_VENDOR_KEYS=str(work / 'keys'), HOME=str(work / 'home'),
           ANDROID_PREFS_ROOT=str(work / 'home'), JAVA_HOME=spec['java'])
env['PATH'] = spec['java'] + '/bin:' + env.get('PATH', '')
for directory in ('avd', 'home', 'keys'):
    (work / directory).mkdir()
adb_base = [str(sdk / 'platform-tools/adb'), '-P', '15039', '-s', 'emulator-5584']


def run(arguments, *, check=True, timeout=120, input=None):
    result = subprocess.run([str(arg) for arg in arguments], env=env, input=input,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{arguments}: exit {result.returncode}\n{result.stdout}')
    return result


def adb(*arguments, **options):
    return run(adb_base + list(arguments), **options)


def shell(command, **options):
    # Android's bootstrap/default namespaces can differ while sharing /. Keep
    # destructive test fixtures and repeated invocations in PID 1's namespace.
    return adb('shell', 'nsenter -t 1 -m -- /system/bin/sh',
               input='set -e\n' + command + '\nexit\n', **options).stdout.strip()


def wait_boot():
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        if emulator.poll() is not None:
            raise RuntimeError('emulator exited: ' + (work / 'emulator.log').read_text()[-12000:])
        result = adb('shell', 'getprop sys.boot_completed', check=False, timeout=10)
        if result.returncode == 0 and result.stdout.strip() == '1':
            root_result = adb('root', check=False)
            if root_result.returncode:
                time.sleep(1)
                continue
            adb('wait-for-device', timeout=30)
            assert shell('getenforce') == 'Enforcing'
            return
        time.sleep(2)
    raise RuntimeError('Android boot timeout')


def mounts():
    return [line for line in shell('cat /proc/1/mountinfo').splitlines()
            if line.split()[4] == '/nix']


def metadata():
    return shell('stat -c %d:%i:%u:%g:%a:%C /data/nix')


def invoke(*, success=True):
    result = adb('shell', 'nsenter -t 1 -m -- runcon u:r:nns_mount:s0 /system/bin/nns-mount',
                 check=False)
    with (work / 'invocations.log').open('a') as stream:
        stream.write(result.stdout + '\n')
    assert (result.returncode == 0) == success, result.stdout
    return result.stdout


# Runtime policy injection is an emulator adapter, not compiled ROM policy.
# Keep grants derived from the production .te file rather than a second policy.
def runtime_policy():
    statements = []
    for line in (integration / 'sepolicy/nns_mount.te').read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        if line == 'init_daemon_domain(nns_mount)':
            statements.extend([
                'allow init nns_mount_exec file { getattr open read execute map }',
                'allow init nns_mount process { transition siginh rlimitinh }',
                'dontaudit init nns_mount process noatsecure',
                'allow nns_mount nns_mount_exec file { entrypoint getattr open read execute map }',
                'allow nns_mount init process sigchld',
                'type_transition init nns_mount_exec process nns_mount',
            ])
        elif line.startswith('type '):
            fields = line.rstrip(';').removeprefix('type ').split(', ')
            statements.append('type ' + fields[0] + ' { ' + ' '.join(fields[1:]) + ' }')
        else:
            line = line.replace(' nns_mount self:', ' nns_mount nns_mount:')
            statements.append(re.sub(r'(\w+|\}):(\w+)', r'\1 \2', line.rstrip(';')))
    return '\n'.join(statements) + '\n'


assert os.access('/dev/kvm', os.R_OK | os.W_OK), 'KVM required; no software fallback'
avdmanager, = sdk.glob('cmdline-tools/*/bin/avdmanager')
run([avdmanager, 'create', 'avd', '--force', '--name', 'nns-mount-test',
     '--package', 'system-images;android-35;google_apis;x86_64', '--device', 'pixel'], input='no\n')
config = work / 'avd/nns-mount-test.avd/config.ini'
config.write_text(config.read_text() + '\ndisk.dataPartition.size=2G\nhw.ramSize=2048\n')

# Supply the ROM's empty root mountpoint and real init service in a private image.
stock_image = sdk / 'system-images/android-35/google_apis/x86_64/system.img'
image = work / 'system.img'
with stock_image.open('rb') as stream:
    sparse = struct.unpack('<I', stream.read(4))[0] == 0xed26ff3a
if sparse:
    run(['simg2img', stock_image, image])
else:
    shutil.copyfile(stock_image, image)
# The emulator resolves the encryption seed beside an explicit -system image.
# It copies this immutable SDK seed into the private AVD before writing keys.
(work / 'encryptionkey.img').symlink_to(stock_image.parent / 'encryptionkey.img')


def copy_region(source, destination, source_offset, destination_offset, length):
    with source.open('rb') as reader, destination.open('r+b' if destination.exists() else 'w+b') as writer:
        reader.seek(source_offset)
        writer.seek(destination_offset)
        while length:
            block = reader.read(min(length, 4 * 1024 * 1024))
            assert block, 'truncated disk image'
            writer.write(block)
            length -= len(block)


# SDK r09 is a GPT disk containing vbmeta and a dynamic super partition.
# Preserve its metadata/layout and change only the single system extent.
partition_table = json.loads(run(['sfdisk', '--json', image]).stdout)['partitiontable']
assert partition_table['label'] == 'gpt'
assert partition_table['sectorsize'] == 512
super_partition, = [entry for entry in partition_table['partitions'] if entry['name'] == 'super']
vbmeta_partition, = [entry for entry in partition_table['partitions'] if entry['name'] == 'vbmeta']
super_image = work / 'super.img'
copy_region(image, super_image, super_partition['start'] * 512, 0, super_partition['size'] * 512)
layout = run(['lpdump', super_image]).stdout
(work / 'partition-layout.log').write_text(layout)
extent, = re.findall(r'^super: (\d+) \.\. (\d+): system \((\d+) sectors\)$', layout, re.MULTILINE)
start, end, sectors = map(int, extent)
assert end - start == sectors
partitions = work / 'partitions'
partitions.mkdir()
run(['lpunpack', '-p', 'system', super_image, partitions])
system_image = partitions / 'system.img'
assert system_image.stat().st_size == sectors * 512


def debugfs(command):
    output = run(['debugfs', '-w', '-R', command, system_image]).stdout
    # debugfs often returns zero even when the command fails.
    if any(error in output for error in ('File not found', 'while ', 'Usage:', 'No free ')):
        raise RuntimeError(output)
    return output


# This test must exercise system-as-root, not manufacture /nix in a private view.
assert 'Inode:' in debugfs('stat /system/bin/init'), 'SDK system image is not system-as-root'
debugfs('mkdir /nix')
for source, target, mode in (
    (spec['helper'], '/system/bin/nns-mount', '0100755'),
    (integration / 'init.nns-mount.rc', '/system/etc/init/init.nns-mount.rc', '0100644'),
):
    debugfs(f'write {source} {target}')
    debugfs(f'set_inode_field {target} mode {mode}')
    context = work / 'image-context'
    context.write_bytes(b'u:object_r:nns_mount_exec:s0\0' if target == '/system/bin/nns-mount'
                        else b'u:object_r:system_file:s0\0')
    debugfs(f'ea_set -f {context} {target} security.selinux')
context = work / 'image-context'
context.write_bytes(b'u:object_r:system_data_file:s0\0')
debugfs(f'ea_set -f {context} /nix security.selinux')
# This SDK ramdisk has no ksud init integration. Its kernel notices zygote
# only after post-fs-data, too late for the native helper. Order the test-only
# policy adapter before the unmodified production fragment.
policy_adapter = work / 'init.nns-mount-adapter.rc'
policy_adapter.write_text('service nns-mount-test-policy /data/adb/ksud post-fs-data\n'
                          '    user root\n    group root system\n'
                          '    seclabel u:r:ksu:s0\n    disabled\n    oneshot\n    stdio_to_kmsg\n'
                          'on post-fs-data\n    exec_start nns-mount-test-policy\n')
debugfs(f'write {policy_adapter} /system/etc/init/init.nns-mount-adapter.rc')
context.write_bytes(b'u:object_r:system_file:s0\0')
debugfs(f'ea_set -f {context} /system/etc/init/init.nns-mount-adapter.rc security.selinux')
encryption_fixture = work / 'init.nns-mount-encryption-test.rc'
encryption_fixture.write_text('on property:sys.nns_mount_test.encrypted=1\n'
                              '    mkdir /data/nix 0700 root root encryption=Require\n'
                              '    setprop sys.nns_mount_test.encryption_done 1\n')
debugfs(f'write {encryption_fixture} /system/etc/init/init.nns-mount-encryption-test.rc')
context.write_bytes(b'u:object_r:system_file:s0\0')
debugfs(f'ea_set -f {context} /system/etc/init/init.nns-mount-encryption-test.rc security.selinux')

copy_region(system_image, image, 0, super_partition['start'] * 512 + start * 512, sectors * 512)
# The test changes hashed system blocks. Disable AVB verification only in this
# disposable emulator image, retaining its descriptors and partition layout.
vbmeta_image = work / 'vbmeta-original.img'
copy_region(image, vbmeta_image, vbmeta_partition['start'] * 512, 0, vbmeta_partition['size'] * 512)
vbmeta_test = work / 'vbmeta-test.img'
run(['avbtool', 'make_vbmeta_image', '--flags', '3', '--include_descriptors_from_image',
     vbmeta_image, '--padding_size', str(vbmeta_partition['size'] * 512), '--output', vbmeta_test])
assert vbmeta_test.stat().st_size == vbmeta_partition['size'] * 512
copy_region(vbmeta_test, image, 0, vbmeta_partition['start'] * 512, vbmeta_partition['size'] * 512)
super_image.unlink()
shutil.rmtree(partitions)

adb('start-server')
emulator_log = (work / 'emulator.log').open('w')
emulator = subprocess.Popen([str(sdk / 'emulator/emulator'), '-avd', 'nns-mount-test',
    '-kernel', spec['kernel'], '-system', str(image), '-writable-system',
    '-no-window', '-no-snapshot', '-no-audio', '-no-boot-anim', '-gpu', 'swiftshader',
    '-no-metrics', '-accel', 'on', '-memory', '2048', '-cores', '2', '-port', '5584',
    '-show-kernel'], env=env, stdout=emulator_log, stderr=subprocess.STDOUT)
try:
    wait_boot()
    assert shell('id -u') == '0'
    shell('auditctl -r 0')
    assert not mounts()
    shell('test ! -e /data/nix')
    adb('push', spec['ksud'], '/data/local/tmp/ksud')
    shell('chmod 755 /data/local/tmp/ksud; /data/local/tmp/ksud install')
    module = work / 'module'
    module.mkdir()
    (module / 'module.prop').write_text('id=nns-mount-test\nname=NNS mount test\nversion=1\nversionCode=1\nauthor=NNS\ndescription=Disposable mount policy adapter\n')
    (module / 'skip_mount').touch()
    (module / 'sepolicy.rule').write_text(runtime_policy())
    (module / 'post-fs-data.sh').write_text('#!/system/bin/sh\n'
        'exec >/data/local/tmp/nns-mount-adapter.log 2>&1\nset -ex\n'
        'ls -Z /system/bin/nns-mount\n')
    adb('push', str(module), '/data/adb/modules/nns-mount-test')
    adb('reboot')
    wait_boot()

    assert len(mounts()) == 1, 'fresh init mount absent'
    assert shell('stat -c %u:%g:%a:%C /data/nix') == '0:0:755:u:object_r:system_data_file:s0'
    initial_mount = mounts()
    initial_metadata = metadata()
    for _ in range(3):
        assert 'existing bind retained' in invoke()
        assert mounts() == initial_mount
        assert metadata() == initial_metadata
    shell('umount /nix')
    with ThreadPoolExecutor(max_workers=8) as executor:
        list(executor.map(lambda _: invoke(), range(8)))
    assert len(mounts()) == 1
    assert metadata() == initial_metadata
    print('PASS: fresh backing directory, repeat, and concurrent invocation', flush=True)

    flag_options = ['ro', 'nosuid', 'nodev', 'noexec']
    initial_flags = set(mounts()[0].split()[5].split(','))
    adb('push', spec['bindRemount'], '/data/local/tmp/nns-bind-remount')
    shell('chmod 755 /data/local/tmp/nns-bind-remount')
    initial_mask = sum(1 << index for index, restricted in enumerate(flag_options)
                       if restricted in initial_flags)
    for index, restricted in enumerate(flag_options):
        shell(f'/data/local/tmp/nns-bind-remount {initial_mask ^ (1 << index)}')
        mismatching = mounts()
        changed_flags = set(mismatching[0].split()[5].split(','))
        assert (restricted in changed_flags) != (restricted in initial_flags)
        invoke(success=False)
        assert mounts() == mismatching
        assert metadata() == initial_metadata
        shell(f'/data/local/tmp/nns-bind-remount {initial_mask}')
        invoke()
    print('PASS: read-only, nosuid, nodev, and noexec mismatches refused unchanged', flush=True)

    shell('printf "global-store\\n" > /data/nix/mount-proof; chmod 644 /data/nix/mount-proof; '
          'chcon u:object_r:shell_data_file:s0 /data/nix/mount-proof')
    adb('install', spec['apk'])
    result = adb('shell', 'am instrument -w -e mode global-mount xyz.reo101.nnstest/.Probe')
    (work / 'app.log').write_text(result.stdout)
    assert 'NNS-GLOBAL-MOUNT-PASS' in result.stdout, result.stdout
    print('PASS: ordinary filtered app sees global bind and cannot write backing directory', flush=True)

    shell('chmod 0711 /data/nix')
    populated_metadata = metadata()
    adb('reboot')
    wait_boot()
    assert len(mounts()) == 1
    assert metadata() == populated_metadata
    assert shell('cat /nix/mount-proof') == 'global-store'
    print('PASS: populated store and metadata survive reboot', flush=True)

    shell('umount /nix; mount -t tmpfs tmpfs /nix')
    conflict = mounts()
    invoke(success=False)
    assert mounts() == conflict
    assert metadata() == populated_metadata
    shell('umount /nix')
    # The SDK system filesystem uses shared_blocks and cannot be remounted
    # writable. Nonempty unmounted targets are covered by the native suite.
    invoke()
    shell('mount --bind /data/nix /nix')
    stacked = mounts()
    assert len(stacked) == 2
    invoke(success=False)
    assert mounts() == stacked
    shell('umount /nix; umount /nix')
    print('PASS: conflicting and stacked mountpoints refused unchanged', flush=True)

    shell('chmod 0000 /data/nix')
    inaccessible_metadata = metadata()
    invoke(success=False)
    assert metadata() == inaccessible_metadata
    assert not mounts()
    shell('chmod 0711 /data/nix')
    print('PASS: inaccessible backing refused without DAC bypass or metadata repair', flush=True)

    shell('mv /data/nix /data/nix-retained; ln -s /data/nix-retained /data/nix')
    invoke(success=False)
    shell('test -L /data/nix; rm /data/nix; ln -s /data/nix-missing /data/nix')
    invoke(success=False)
    shell('test -L /data/nix; rm /data/nix; touch /data/nix')
    invoke(success=False)
    shell('test -f /data/nix; rm /data/nix; mv /data/nix-retained /data/nix')
    invoke()
    assert shell('cat /nix/mount-proof') == 'global-store'
    assert shell('getenforce') == 'Enforcing'
    print('PASS: symlink, dangling-symlink, and nondirectory backing paths refused', flush=True)

    # Request encryption only on a new, empty fixture. Never use Require on
    # populated storage: Android init may request a data wipe on failure.
    adb('push', spec['fscryptPolicy'], '/data/local/tmp/fscrypt-policy')
    shell('chmod 755 /data/local/tmp/fscrypt-policy')
    assert shell('/data/local/tmp/fscrypt-policy') == 'none'
    shell('umount /nix; mv /data/nix /data/nix-retained; '
          'setprop sys.nns_mount_test.encrypted 1')
    deadline = time.monotonic() + 20
    while shell('getprop sys.nns_mount_test.encryption_done') != '1':
        assert time.monotonic() < deadline, 'encryption fixture timed out'
        time.sleep(1)
    encryption_policy = shell('/data/local/tmp/fscrypt-policy')
    assert encryption_policy != 'none', 'SDK did not create an encrypted fixture'
    encrypted_metadata = metadata()
    shell('printf "encrypted-store\\n" > /data/nix/encrypted-proof')
    for _ in range(2):
        invoke()
        assert metadata() == encrypted_metadata
        assert shell('/data/local/tmp/fscrypt-policy') == encryption_policy
        assert len(mounts()) == 1
    adb('reboot')
    wait_boot()
    assert len(mounts()) == 1
    assert metadata() == encrypted_metadata
    assert shell('/data/local/tmp/fscrypt-policy') == encryption_policy
    assert shell('cat /nix/encrypted-proof') == 'encrypted-store'
    assert shell('getenforce') == 'Enforcing'
    print('PASS: existing fscrypt policy and encrypted contents retained across repeat and reboot', flush=True)
finally:
    for name, command in {'logcat': 'logcat -d', 'dmesg': 'dmesg',
                          'adapter': 'cat /data/local/tmp/nns-mount-adapter.log'}.items():
        try:
            (work / (name + '.log')).write_text(shell(command, check=False, timeout=10))
        except Exception as error:
            print('diagnostic collection:', error)
    try:
        adb('emu', 'kill', check=False, timeout=10)
        emulator.wait(timeout=15)
    except subprocess.TimeoutExpired:
        emulator.kill()
        emulator.wait(timeout=10)
    emulator_log.close()
    adb('kill-server', check=False, timeout=10)
    # Retain diagnostics, not multi-GB disposable disk images.
    cleanup_images()
    print('Android mount logs:', work, flush=True)
