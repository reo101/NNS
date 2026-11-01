"""Exercise mount ownership and runtime preparation in isolated paths."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP_ID = 'org.example.nns'


def prepare_fixture(directory, helper=True, namespace_match=True):
    root = Path(directory)
    module = root / 'module'
    module.mkdir()
    (root / 'bin').mkdir()
    (root / 'log').mkdir()
    (root / 'tmp').mkdir()
    (root / 'self-ns').write_text('mnt:[42]')
    (root / 'init-ns').write_text('mnt:[42]' if namespace_match else 'mnt:[99]')
    replacements = {
        '/data/adb/ksu/bin:/system/bin:/system/xbin': f'{root / "bin"}:/bin:/usr/bin',
        '/data/adb/modules/nix': str(module),
        '/data/local/tmp': str(root / 'log'),
        '/data/data/@APP_ID@': str(root / 'data/app'),
        '/proc/sys/kernel/seccomp_bypass_paths': str(root / 'seccomp-bypass-paths'),
        '/system/bin/nns-mount': str(root / 'nns-mount'),
        '/proc/self/ns/mnt': str(root / 'self-ns'),
        '/proc/1/ns/mnt': str(root / 'init-ns'),
        '/data/nix': str(root / 'data/nix'),
        '/system/bin/sh': '/bin/sh',
        '/tmp': str(root / 'tmp'),
        '@APP_UID@': str(os.getuid()),
        '@APP_GID@': str(os.getgid()),
        '@APP_ID@': APP_ID,
        '@ARCH@': 'arm64',
    }
    pattern = re.compile('|'.join(re.escape(key) for key in sorted(replacements, key=len, reverse=True)))

    def relocate(text):
        return pattern.sub(lambda match: replacements[match.group()], text)

    for name in ('mount-ownership.sh', 'prepare-runtime.sh', 'post-fs-data.sh',
                 'service.sh', 'customize.sh'):
        text = relocate((ROOT / 'module' / name).read_text())
        (module / name).write_text(text)

    # Supply only the payload needed to exercise publication, plus inert stage scripts.
    for relative in ('bin/nix-enter', 'bin/nns-resolver', 'bin/nns-rish-terminal',
                     'bin/rish', 'bin/su', 'bin/sudo', 'bin/rish-probe',
                     'lib/libnns-dns.so', 'lib/rish.dex', 'etc/nix/nix.conf', 'etc/profile'):
        target = module / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f'fixture payload: {relative}\n')
    (module / 'bin/nns-storage').write_text(
        '#!/bin/sh\n'
        'if [ "${NNS_TEST_STORAGE_MODE:-directory}" = directory ]; then\n'
        '  [ "$1" != --mode ] || printf "directory\\n"\n'
        '  exit 0\n'
        'fi\n'
        'printf "storage %s\\n" "${1:-mount}" >> "$NNS_TEST_TRACE"\n'
        'case "$1" in --mode) printf "btrfs\\n";; '
        '--check) exit "${NNS_TEST_STORAGE_CHECK_STATUS:-0}";; '
        '*) exit "${NNS_TEST_STORAGE_MOUNT_STATUS:-0}";; esac\n')
    (module / 'bin/nns-storage').chmod(0o755)
    (module / 'system-generation.sh').write_text('nns_system_selected() { return 1; }\n')
    for name in ('stage-android-runtime.sh', 'stage-etc.sh'):
        (module / name).write_text(
            f'printf "{name}\\n" >> "$NNS_TEST_TRACE"\n')

    (root / 'bin/getprop').write_text(
        '#!/bin/sh\n[ "${NNS_TEST_GETPROP_STATUS:-0}" = 0 ] || exit "$NNS_TEST_GETPROP_STATUS"\nprintf "%s" "$NNS_TEST_OWNER"\n')
    (root / 'bin/readlink').write_text(
        '#!/bin/sh\ncase "$1" in */self/ns/mnt|*/self-ns) printf "mnt:[42]\\n";; '
        '*/1/ns/mnt|*/init-ns) printf "%s\\n" "$NNS_TEST_INIT_NS";; '
        '*) exec /bin/readlink "$@";; esac\n')
    (root / 'bin/mkdir').write_text(
        '#!/bin/sh\nprintf "mkdir %s\\n" "$*" >> "$NNS_TEST_TRACE"\nexec /bin/mkdir "$@"\n')
    (root / 'bin/chown').write_text(
        '#!/bin/sh\nprintf "chown %s\\n" "$*" >> "$NNS_TEST_TRACE"\nexit 0\n')
    (root / 'bin/chcon').write_text(
        '#!/bin/sh\nprintf "chcon %s\\n" "$*" >> "$NNS_TEST_TRACE"\nexit 0\n')
    (root / 'bin/ls').write_text(
        '#!/bin/sh\nif [ "$1" = -Zd ]; then printf "u:object_r:app_data_file:s0 fixture\\n"; '
        'else exec /bin/ls "$@"; fi\n')
    if helper:
        (root / 'nns-mount').write_text(
            '#!/bin/sh\nprintf "helper %s\\n" "$*" >> "$NNS_TEST_TRACE"\n'
            '[ "$1" = --check ] || exit 8\nexit "${NNS_TEST_HELPER_STATUS:-0}"\n')
        (root / 'nns-mount').chmod(0o755)
    for executable in (root / 'bin').iterdir():
        executable.chmod(0o755)
    return module, root


def run(script, root, owner='init', **environment):
    env = os.environ | {
        'PATH': f'{root / "bin"}:/bin:/usr/bin',
        'NNS_TEST_OWNER': owner,
        'NNS_TEST_INIT_NS': (root / 'init-ns').read_text(),
        'NNS_TEST_TRACE': str(root / 'trace'),
    } | environment
    return subprocess.run(['/bin/sh', str(script)], env=env, capture_output=True, text=True)


def trace(root):
    path = root / 'trace'
    return path.read_text() if path.exists() else ''


def make_backing(root):
    for relative in ('data/nix', 'data/nix/store', 'data/nix/var'):
        path = root / relative
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o711)
    config = root / 'data/nix/etc/nix/nix.conf'
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('before\n# >>> nns.nix.settings\ncustom-setting = true\n'
                      '# <<< nns.nix.settings\nafter\n')


def assert_backing_untouched(root):
    for relative in ('data/nix', 'data/nix/store', 'data/nix/var'):
        assert (root / relative).stat().st_mode & 0o777 == 0o711, relative
    protected = {str(root / path) for path in
                 ('data/nix', 'data/nix/store', 'data/nix/var')}
    for line in trace(root).splitlines():
        if line.startswith(('chown ', 'chcon ')):
            assert protected.isdisjoint(line.split()), line


def run_customize(module, root, owner='init', **environment):
    installer = root / 'installer.sh'
    installer.write_text(
        'abort() { printf "abort\\n"; exit 90; }\n'
        'ui_print() { :; }\nset_perm() { :; }\nset_perm_recursive() { :; }\n'
        f'BOOTMODE=true\nARCH=arm64\nMODPATH="{module}"\n. "{module / "customize.sh"}"\n')
    return run(installer, root, owner, **environment)


def main():
    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        make_backing(root)
        result = run(module / 'post-fs-data.sh', root)
        assert result.returncode == 0
        assert not trace(root), 'native post-fs must not invoke the helper or runtime commands'
        assert not (root / 'data/nix/bin').exists(), 'native post-fs must defer runtime preparation'
        result = run(module / 'service.sh', root)
        assert result.returncode == 0, result.stderr
        operations = trace(root).splitlines()
        assert operations[0] == 'helper --check', 'service must check before preparation'
        assert operations.index('helper --check') < next(i for i, item in enumerate(operations)
                                                          if item.startswith('mkdir '))
        assert operations.count('helper --check') == 2, 'prepare-runtime must recheck the mount'
        assert_backing_untouched(root)
        for relative in ('bin/nix-enter', 'bin/nns-resolver', 'lib/libnns-dns.so',
                         'bin/nns-rish-terminal', 'lib/rish.dex',
                         'var/nns/bin/rish', 'var/nns/bin/su',
                         'var/nns/bin/sudo', 'var/nns/bin/rish-probe'):
            payload = relative.removeprefix('var/nns/')
            assert (root / 'data/nix' / relative).read_bytes() == (module / payload).read_bytes(), relative
        assert not list((root / 'data/nix').rglob('*.new'))
        config = (root / 'data/nix/etc/nix/nix.conf').read_text()
        assert '# >>> nns.nix.settings' in config and '# <<< nns.nix.settings' in config
        assert 'custom-setting = true' in config
        assert 'stage-android-runtime.sh' in operations
        assert 'stage-etc.sh' in operations

    for options in (
        {'NNS_TEST_HELPER_STATUS': '1'},
        {'NNS_TEST_INIT_NS': 'mnt:[99]'},
        {'NNS_TEST_GETPROP_STATUS': '1'},
    ):
        with tempfile.TemporaryDirectory() as temporary:
            module, root = prepare_fixture(temporary)
            make_backing(root)
            result = run(module / 'service.sh', root, **options)
            assert result.returncode != 0, options
            assert not (root / 'data/nix/bin').exists(), options
            assert_backing_untouched(root)
            if 'NNS_TEST_HELPER_STATUS' in options:
                assert trace(root).splitlines() == ['helper --check']
            else:
                assert not trace(root)

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        make_backing(root)
        result = run(module / 'service.sh', root, owner='invalid')
        assert result.returncode != 0
        assert not (root / 'data/nix/bin').exists()
        assert_backing_untouched(root)
        assert not trace(root)

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary, helper=False)
        make_backing(root)
        result = run(module / 'service.sh', root)
        assert result.returncode != 0
        assert not (root / 'data/nix/bin').exists()
        assert_backing_untouched(root)
        assert not trace(root)

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        result = run(module / 'post-fs-data.sh', root, owner='invalid')
        assert result.returncode != 0, 'unknown ownership mode must fail closed'

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary, helper=False)
        make_backing(root)
        result = run(module / 'post-fs-data.sh', root, owner='')
        assert result.returncode == 0, result.stderr
        assert all((root / path).stat().st_mode & 0o777 == 0o755
                   for path in ('data/nix', 'data/nix/store', 'data/nix/var'))
        operations = trace(root)
        assert ['chown', '0:0', str(root / 'data/nix')] in [line.split() for line in operations.splitlines()]
        assert ['chcon', 'u:object_r:system_data_file:s0', str(root / 'data/nix')] in [
            line.split() for line in operations.splitlines()]
        assert (root / 'data/nix/bin/nns-resolver').is_file()
        result = run(module / 'service.sh', root, owner='')
        assert result.returncode == 0, result.stderr
        assert 'helper ' not in trace(root)
        assert 'chcon -h u:object_r:system_data_file:s0' in trace(root)

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        result = run_customize(module, root, owner='invalid')
        assert result.returncode == 90
        assert not (root / 'data/nix').exists(), 'failed installer gate must precede mkdir/config seed'
        assert 'helper --check' not in trace(root)

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        result = run_customize(module, root, NNS_TEST_HELPER_STATUS='1')
        assert result.returncode == 90
        assert not (root / 'data/nix').exists()
        assert trace(root).splitlines() == ['helper --check']

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        backing = root / 'data/nix'
        backing.mkdir(parents=True)
        backing.chmod(0o711)
        result = run_customize(module, root)
        assert result.returncode == 0, result.stderr
        assert (root / 'data/nix/etc/nix/nix.conf').is_file()
        assert backing.stat().st_mode & 0o777 == 0o711
        assert not (root / 'data/nix/store').exists(), 'installer must not provision the store'
        operations = trace(root).splitlines()
        assert operations[0] == 'helper --check'
        assert operations.index('helper --check') < next(i for i, item in enumerate(operations)
                                                          if item.startswith('mkdir '))

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        result = run_customize(module, root, owner='')
        assert result.returncode == 0, result.stderr
        assert (root / 'data/nix/etc/nix/nix.conf').is_file()
        assert 'helper ' not in trace(root), 'legacy installer does not require the ROM helper'

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        make_backing(root)
        options = {'NNS_TEST_STORAGE_MODE': 'btrfs'}
        result = run(module / 'post-fs-data.sh', root, owner='', **options)
        assert result.returncode == 0
        assert trace(root).splitlines() == ['storage --mode']
        assert not (root / 'data/nix/bin').exists()
        result = run(module / 'service.sh', root, owner='', **options)
        assert result.returncode == 0, result.stderr
        operations = trace(root).splitlines()
        assert operations.index('storage mount') < operations.index('storage --check')
        assert operations.index('storage --check') < next(i for i, line in enumerate(operations)
                                                         if line.startswith('mkdir '))
        assert (root / 'data/nix/bin/nix-enter').is_file()

    for script, settings in (
        ('service.sh', {'NNS_TEST_STORAGE_MOUNT_STATUS': '1'}),
        ('prepare-runtime.sh', {'NNS_TEST_STORAGE_CHECK_STATUS': '1'}),
        ('service.sh', {'NNS_TEST_STORAGE_CHECK_STATUS': '1'}),
    ):
        with tempfile.TemporaryDirectory() as temporary:
            module, root = prepare_fixture(temporary)
            result = run(module / script, root, owner='', NNS_TEST_STORAGE_MODE='btrfs', **settings)
            assert result.returncode != 0
            assert not (root / 'data/nix').exists(), 'failed backing gate must precede writes'

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        result = run_customize(module, root, owner='', NNS_TEST_STORAGE_MODE='btrfs',
                               NNS_TEST_STORAGE_CHECK_STATUS='1')
        assert result.returncode == 90
        assert not (root / 'data/nix').exists()
        assert 'storage mount' not in trace(root)

    with tempfile.TemporaryDirectory() as temporary:
        module, root = prepare_fixture(temporary)
        make_backing(root)
        result = run(module / 'service.sh', root, NNS_TEST_STORAGE_MODE='btrfs',
                     NNS_TEST_STORAGE_CHECK_STATUS='1')
        assert result.returncode != 0
        assert 'storage mount' not in trace(root), 'ROM mode must never mount backing late'
        assert not (root / 'data/nix/bin').exists()

    print('PASS: native/legacy/Btrfs ownership gates, preparation and installer ordering')


if __name__ == '__main__':
    main()
