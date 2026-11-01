#!/usr/bin/env python3
"""Test module import, release and signing guards with mock kmod metadata."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    modules = directory / 'modules'
    modules.mkdir()
    metadata = {
        'imports': {'module_layout': '0x12345678', 'helper_symbol': '0xabcdef01'},
        'vermagic': '6.12.38-fixture SMP preempt mod_unload modversions',
        'signer': 'Fixture signing certificate',
    }
    program = f'#!{sys.executable}\n' + '''
import json
from pathlib import Path
import sys
metadata = json.loads(Path(sys.argv[-1]).read_text())
if Path(sys.argv[0]).name == 'modprobe':
    for symbol, version in metadata['imports'].items():
        print(version, symbol)
else:
    print(metadata[sys.argv[2]])
'''
    for name in ('modinfo', 'modprobe'):
        path = directory / name
        path.write_text(program)
        path.chmod(0o755)
    symvers = directory / 'Module.symvers'
    symvers.write_text('0x12345678\tmodule_layout\tvmlinux\tEXPORT_SYMBOL\n'
                       '0xabcdef01\thelper_symbol\tvmlinux\tEXPORT_SYMBOL\n')
    release = directory / 'kernel.release'
    release.write_text('6.12.38-fixture\n')
    output = directory / 'result.json'

    def execute(value):
        (modules / 'driver.ko').write_text(json.dumps(value))
        return subprocess.run([
            sys.executable, str(root / 'tests/rom-storage/check-module-versions.py'),
            '--modules', str(modules), '--symvers', str(symvers),
            '--release', str(release), '--output', str(output),
        ], capture_output=True, text=True,
            env={**os.environ, 'PATH': str(directory) + os.pathsep + os.environ['PATH']})

    valid = execute(metadata)
    assert valid.returncode == 0, valid.stderr
    assert json.loads(output.read_text())['modules']['driver.ko']['imports_checked'] == 2
    output.unlink()
    cases = [
        ({**metadata, 'imports': {**metadata['imports'], 'module_layout': '0x11111111'}}, 'mismatched or missing symbol'),
        ({**metadata, 'imports': {**metadata['imports'], 'unknown_symbol': '0x22222222'}}, 'mismatched or missing symbol'),
        ({**metadata, 'imports': {'helper_symbol': '0xabcdef01'}}, 'Missing module_layout'),
        ({**metadata, 'vermagic': '6.12.37-fixture SMP'}, 'Wrong kernel release'),
        ({**metadata, 'signer': ''}, 'unsigned module'),
    ]
    for value, error in cases:
        result = execute(value)
        assert result.returncode != 0 and error in result.stderr, result
        assert not output.exists()
print('PASS: matching modules accepted; wrong or absent imports, release and signer rejected')

with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    product, kernel = directory / 'product', directory / 'kernel'
    kernel.mkdir()
    (kernel / 'kernel').write_bytes(b'kernel fixture')
    product.mkdir()
    (product / 'kernel').write_bytes((kernel / 'kernel').read_bytes())
    expected = {}
    for partition in ('vendor_ramdisk', 'vendor_dlkm', 'system_dlkm'):
        destination = product / partition / 'lib/modules'
        destination.mkdir(parents=True)
        module = destination / (partition + '.ko')
        module.write_bytes(partition.encode())
        expected[module.name] = {'sha256': hashlib.sha256(module.read_bytes()).hexdigest()}
    (kernel / 'module-versions.json').write_text(json.dumps({'modules': expected}))
    output = directory / 'result.json'

    def check_staging():
        return subprocess.run([
            sys.executable, str(root / 'tests/rom-storage/check-staged-modules.py'),
            '--product', str(product), '--kernel', str(kernel), '--output', str(output),
        ], capture_output=True, text=True)

    result = check_staging()
    assert result.returncode == 0, result.stderr
    output.unlink()
    module = product / 'vendor_dlkm/lib/modules/vendor_dlkm.ko'
    original = module.read_bytes()
    module.write_bytes(b'stale module')
    result = check_staging()
    assert result.returncode != 0 and 'Stale or modified' in result.stderr, result
    assert not output.exists()
    module.write_bytes(original)
    expected['missing.ko'] = {'sha256': '0' * 64}
    (kernel / 'module-versions.json').write_text(json.dumps({'modules': expected}))
    result = check_staging()
    assert result.returncode != 0 and 'absent from staging' in result.stderr, result
    assert not output.exists()
    del expected['missing.ko']
    (kernel / 'module-versions.json').write_text(json.dumps({'modules': expected}))
    (product / 'kernel').write_bytes(b'wrong kernel')
    result = check_staging()
    assert result.returncode != 0 and 'Staged kernel differs' in result.stderr, result
    assert not output.exists()
print('PASS: staged module sets accepted; stale modules, omissions and wrong kernel rejected')
