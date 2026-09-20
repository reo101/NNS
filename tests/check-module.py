"""Check the manager-installable archive without executing ARM64 code."""
from pathlib import Path
import stat
import struct
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as z:
    names = set(z.namelist())
    required = {'module.prop', 'customize.sh', 'post-fs-data.sh', 'service.sh', 'skip_mount',
                'sepolicy.rule', 'bin/nix-enter', 'etc/profile', 'etc/nix/nix.conf'}
    assert names == required, names ^ required
    assert z.testzip() is None
    assert 'id=nix\n' in z.read('module.prop').decode()
    for name in names:
        assert not Path(name).is_absolute() and '..' not in Path(name).parts
        assert z.getinfo(name).date_time == (1980, 1, 1, 0, 0, 0)
    for name in ('bin/nix-enter', 'customize.sh', 'post-fs-data.sh', 'service.sh'):
        assert (z.getinfo(name).external_attr >> 16) & stat.S_IXUSR, name
    for name in ('customize.sh', 'post-fs-data.sh', 'service.sh'):
        assert z.read(name).startswith(b'#!/system/bin/sh\n')
    elf = z.read('bin/nix-enter')
    assert elf[:6] == b'\x7fELF\x02\x01'
    assert struct.unpack_from('<H', elf, 18)[0] == 183, 'not AArch64'
    phoff = struct.unpack_from('<Q', elf, 32)[0]
    entsize, count = struct.unpack_from('<HH', elf, 54)
    assert all(struct.unpack_from('<I', elf, phoff+i*entsize)[0] != 3
               for i in range(count)), 'dynamic interpreter present'
print('PASS: module ZIP layout, timestamps, modes, Android shebangs, static AArch64 ELF')
