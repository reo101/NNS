#!/usr/bin/env python3
"""Native helper regression in a rootless private user/mount/PID namespace."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def run(*arguments, success=True):
    result = subprocess.run(arguments, text=True, capture_output=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result.stdout


def exercise(root):
    assert os.geteuid() == 0
    run('mount', '--bind', str(root), str(root))
    run('mount', '-t', 'tmpfs', 'tmpfs', str(root / 'data'))
    run('mount', '-t', 'proc', 'proc', str(root / 'proc'))
    source, target = root / 'data/nix', root / 'nix'

    def set_root_writable(writable):
        run('mount', '-o', 'remount,bind,' + ('rw' if writable else 'ro'), str(root))

    set_root_writable(False)

    def prepare(success=True):
        return run('chroot', str(root), '/bin/nns-prepare-backing', success=success)

    def invoke(success=True):
        assert os.statvfs(root).f_flag & os.ST_RDONLY
        if success:
            prepare()
        else:
            # Preparation may retain existing backing; the service still rejects
            # conflicting mounts/flags. Neither phase may repair existing state.
            subprocess.run(['chroot', str(root), '/bin/nns-prepare-backing'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return run('chroot', str(root), '/bin/nns-mount', success=success)

    def mounts():
        return [line for line in Path('/proc/self/mountinfo').read_text().splitlines()
                if line.split()[4] == str(target)]

    def metadata():
        status = source.stat()
        return status.st_dev, status.st_ino, status.st_uid, status.st_gid, status.st_mode

    def check(success=True):
        previous_mounts = mounts()
        existed = source.exists()
        previous_metadata = metadata() if source.is_dir() else None
        output = run('chroot', str(root), '/bin/nns-mount', '--check', success=success)
        assert mounts() == previous_mounts, 'Read-only check changed mount state'
        assert source.exists() == existed, 'Read-only check created backing'
        if previous_metadata is not None:
            assert metadata() == previous_metadata
        return output

    assert not source.exists()
    check(False)
    run('chroot', str(root), '/bin/nns-mount', success=False)
    assert not source.exists()
    mask = os.umask(0o077)
    try:
        prepare()
    finally:
        os.umask(mask)
    assert source.stat().st_uid == source.stat().st_gid == 0
    assert not mounts()
    check(False)
    run('chroot', str(root), '/bin/nns-mount', '--unknown', success=False)
    assert not mounts()
    invoke()
    check()
    assert source.stat().st_mode & 0o777 == 0o755
    assert len(mounts()) == 1
    original_mounts, original_metadata = mounts(), metadata()
    for _ in range(3):
        assert 'existing bind retained' in invoke()
        assert mounts() == original_mounts
        assert metadata() == original_metadata
    (source / 'retained').write_text('persistent-store\n')
    source.chmod(0o711)
    original_metadata = metadata()
    run('umount', str(target))
    invoke()
    assert metadata() == original_metadata
    assert (target / 'retained').read_text() == 'persistent-store\n'

    run('umount', str(target))
    # A replacement after validation must not redirect the bind to a new inode.
    run('chroot', str(root), '/bin/nns-mount-race')
    validated = root / 'data/nix-validated'
    assert target.stat().st_ino == validated.stat().st_ino, 'Unvalidated replacement was mounted'
    assert metadata() != original_metadata
    assert (target / 'retained').read_text() == 'persistent-store\n'
    assert not (target / 'replacement').exists()
    run('umount', str(target))
    (source / 'replacement').unlink()
    source.rmdir()
    validated.rename(source)
    assert metadata() == original_metadata

    # Concurrent starts must serialize rather than stack bind mounts.
    processes = [subprocess.Popen(['chroot', str(root), '/bin/nns-mount'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for _ in range(8)]
    for process in processes:
        output, error = process.communicate(timeout=10)
        assert process.returncode == 0, output + error
    assert len(mounts()) == 1
    flag_options = [('ro', 'rw', os.ST_RDONLY), ('nosuid', 'suid', os.ST_NOSUID),
                    ('nodev', 'dev', os.ST_NODEV), ('noexec', 'exec', os.ST_NOEXEC)]
    source_flags = os.statvfs(source).f_flag
    initial_options = ','.join(restricted if source_flags & flag else unrestricted
                               for restricted, unrestricted, flag in flag_options)
    for restricted, unrestricted, flag in flag_options:
        option = unrestricted if source_flags & flag else restricted
        run('mount', '-o', 'remount,bind,' + initial_options + ',' + option, str(target))
        assert (os.statvfs(source).f_flag ^ os.statvfs(target).f_flag) & flag
        mismatching = mounts()
        check(False)
        invoke(False)
        assert mounts() == mismatching
        assert metadata() == original_metadata
        run('mount', '-o', 'remount,bind,' + initial_options, str(target))
        invoke()
    for directory in (root / 'data', target):
        run('mount', '-o', 'remount,bind,ro,nosuid,nodev,noexec', str(directory))
    restricted_mounts = mounts()
    invoke()
    assert mounts() == restricted_mounts
    assert metadata() == original_metadata
    for directory in (root / 'data', target):
        run('mount', '-o', 'remount,bind,' + initial_options, str(directory))
    invoke()

    run('mount', '--bind', str(source), str(target))
    stacked = mounts()
    assert len(stacked) == 2
    check(False)
    invoke(False)
    assert mounts() == stacked
    run('umount', str(target))
    run('umount', str(target))

    run('mount', '-t', 'tmpfs', 'tmpfs', str(target))
    conflicting = mounts()
    check(False)
    invoke(False)
    assert mounts() == conflicting
    run('umount', str(target))
    set_root_writable(True)
    (target / 'occupied').touch()
    set_root_writable(False)
    invoke(False)
    assert (target / 'occupied').exists()
    assert not mounts()
    set_root_writable(True)
    (target / 'occupied').unlink()
    set_root_writable(False)

    retained = root / 'data/nix-retained'
    source.rename(retained)
    set_root_writable(True)
    (target / 'occupied').touch()
    set_root_writable(False)
    prepare(False)
    invoke(False)
    assert not source.exists()
    set_root_writable(True)
    (target / 'occupied').unlink()
    set_root_writable(False)
    for destination in ('/data/nix-retained', '/data/missing'):
        source.symlink_to(destination)
        invoke(False)
        assert source.is_symlink()
        source.unlink()
    source.touch()
    invoke(False)
    assert source.is_file()
    source.unlink()
    retained.rename(source)
    retained_target = root / 'nix-retained'
    set_root_writable(True)
    target.rename(retained_target)
    target.symlink_to('/nix-retained')
    set_root_writable(False)
    invoke(False)
    assert target.is_symlink()
    set_root_writable(True)
    target.unlink()
    target.touch()
    set_root_writable(False)
    invoke(False)
    assert target.is_file()
    set_root_writable(True)
    target.unlink()
    set_root_writable(False)
    invoke(False)
    assert not target.exists()
    set_root_writable(True)
    retained_target.rename(target)
    set_root_writable(False)
    invoke()
    assert metadata() == original_metadata
    assert (target / 'retained').read_text() == 'persistent-store\n'
    print('Native mount helper: read-only verification/root, fresh, repeated, concurrent, populated, descriptor pinning, flag validation, conflict, stack, and path-rejection checks passed.')
    run('umount', str(target))
    run('umount', str(root / 'proc'))
    run('umount', str(root / 'data'))
    run('umount', str(root))


if __name__ == '__main__':
    if sys.argv[1] == '--namespace':
        exercise(Path(sys.argv[2]))
    else:
        if len(sys.argv) != 4:
            raise SystemExit('Usage: test-rom-mount.py <mount-helper> <backing-preparation> <mount-race-fixture>')
        with tempfile.TemporaryDirectory(prefix='nns-mount-test-') as directory:
            root = Path(directory)
            for name in ('bin', 'data', 'nix', 'proc'):
                (root / name).mkdir()
            for argument, name in ((sys.argv[1], 'nns-mount'), (sys.argv[2], 'nns-prepare-backing'),
                                   (sys.argv[3], 'nns-mount-race')):
                shutil.copyfile(argument, root / 'bin' / name)
                (root / 'bin' / name).chmod(0o755)
            print(run('unshare', '--user', '--map-root-user', '--mount', '--pid', '--fork',
                      sys.executable, str(Path(__file__).resolve()), '--namespace', str(root)), end='')
