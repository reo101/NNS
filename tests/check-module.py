"""Check the manager-installable archive without executing ARM64 code."""
from pathlib import Path
import stat
import struct
import sys
import zipfile

arch = sys.argv[2] if len(sys.argv) > 2 else 'arm64'
machine = {'arm64': 183, 'x64': 62}[arch]
with zipfile.ZipFile(sys.argv[1]) as z:
    names = set(z.namelist())
    required = {'module.prop', 'customize.sh', 'post-fs-data.sh', 'service.sh', 'stage-etc.sh', 'skip_mount',
                'sepolicy.rule', 'bin/nix-enter', 'bin/nns-resolver',
                'lib/libnns-dns.so', 'etc/profile', 'etc/nix/nix.conf'}
    assert names == required, names ^ required
    assert z.testzip() is None
    assert 'id=nix\n' in z.read('module.prop').decode()
    policy = z.read('sepolicy.rule')
    assert b'@APP_' not in policy
    for domain in ('untrusted_app', 'untrusted_app_25', 'untrusted_app_27', 'untrusted_app_32'):
        assert policy.count(f'type_transition {domain} nns_exec process nns_app\n'.encode()) == 1
        assert policy.count(f'allow nns_app {domain} fifo_file {{ read write open getattr ioctl append }}\n'.encode()) == 1
    for name in names:
        assert not Path(name).is_absolute() and '..' not in Path(name).parts
        assert z.getinfo(name).date_time == (1980, 1, 1, 0, 0, 0)
    for name in ('bin/nix-enter', 'bin/nns-resolver', 'customize.sh', 'post-fs-data.sh', 'service.sh', 'stage-etc.sh'):
        assert (z.getinfo(name).external_attr >> 16) & stat.S_IXUSR, name
    for name in ('customize.sh', 'post-fs-data.sh', 'service.sh', 'stage-etc.sh'):
        assert z.read(name).startswith(b'#!/system/bin/sh\n')
    elf = z.read('bin/nix-enter')
    assert elf[:6] == b'\x7fELF\x02\x01'
    assert struct.unpack_from('<H', elf, 18)[0] == machine, arch
    phoff = struct.unpack_from('<Q', elf, 32)[0]
    entsize, count = struct.unpack_from('<HH', elf, 54)
    assert all(struct.unpack_from('<I', elf, phoff+i*entsize)[0] != 3
               for i in range(count)), 'dynamic interpreter present'
    for name in ('bin/nns-resolver', 'lib/libnns-dns.so'):
        elf = z.read(name)
        assert elf[:6] == b'\x7fELF\x02\x01'
        assert struct.unpack_from('<H', elf, 18)[0] == machine, name
        assert b'/nix/store/' not in elf, name
    assert b'/system/bin/linker64\x00' in z.read('bin/nns-resolver')
print('PASS: module ZIP layout, timestamps, modes, Android shebangs, static launcher and Android DNS ELFs')
