#!/usr/bin/env python3
"""Check that the VM init amendment retains authentication and explicit root requests."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
specifications = json.loads((root / 'tests/rom-storage/authenticated-init.json').read_text())
assert list(specifications) == ['system/core/init/property_service.cpp']
specification = next(iter(specifications.values()))
replacements = specification['replacements']
source = ('static void SetSafetyNetProps() {\n' + replacements[0][0] + '\n}\n'
          + replacements[1][0] + '\n}\n\nvoid LoadReleaseBuildProperties() {\n}\n')
for previous, replacement in replacements:
    assert source.count(previous) == 1
    source = source.replace(previous, replacement)
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'property_service.cpp'

    def check(text):
        path.write_text(text)
        return subprocess.run([sys.executable, str(root / 'tests/signing-migration/check-lab-init.py'),
                               str(path)], capture_output=True, text=True)

    result = check(source)
    assert result.returncode == 0, result.stderr + result.stdout
    for name, expected, forbidden in (
        ('ro.adb.secure', '1', '0'), ('ro.debuggable', '1', '0'),
        ('ro.force.debuggable', '0', '1'), ('service.adb.root', '0', '1'),
    ):
        changed = source.replace('{"' + name + '", "' + expected + '"}',
                                 '{"' + name + '", "' + forbidden + '"}')
        assert changed != source
        result = check(changed)
        assert result.returncode != 0, name
service = (root / 'integrations/rom/storage/init.nns-storage.rc').read_text()
assert 'file /proc/1/ns/mnt r\n' in service
assert 'readproc' not in service
assert 'capabilities SYS_ADMIN\n' in service and 'SYS_PTRACE' not in service
fixture = (root / 'tests/rom-storage/init.nns-storage-fixture.rc').read_text()
assert 'write /data/adbroot/enabled 1\n' in fixture
assert 'setprop service.adb.root 1' not in fixture
preparation = (root / 'tests/rom-storage/prepare-authenticated-init.py').read_text()
assert 'PRODUCT_PACKAGES += adb_root' in preparation
print('PASS: authenticated userdebug profile accepted; insecure, force-debug and automatic-root variants rejected')
