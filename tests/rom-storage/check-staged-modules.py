#!/usr/bin/env python3
"""Reject stale or modified modules in Cuttlefish ramdisk and DLKM staging."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--product', type=Path, required=True)
parser.add_argument('--kernel', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
arguments = parser.parse_args()
versions = json.loads((arguments.kernel / 'module-versions.json').read_text())
expected = versions['modules']
record = {'kernel_output': str(arguments.kernel.resolve()), 'partitions': {}}
installed = set()
for partition in ('vendor_ramdisk', 'vendor_dlkm', 'system_dlkm'):
    directory = arguments.product / partition / 'lib/modules'
    modules = sorted(directory.rglob('*.ko'))
    if not modules:
        raise RuntimeError('Missing staged modules: ' + partition)
    record['partitions'][partition] = {}
    for module in modules:
        digest = hashlib.sha256(module.read_bytes()).hexdigest()
        if module.name not in expected or digest != expected[module.name]['sha256']:
            raise RuntimeError('Stale or modified staged module: ' + str(module))
        installed.add(module.name)
        record['partitions'][partition][str(module.relative_to(directory))] = digest
if installed != set(expected):
    raise RuntimeError('Matched modules absent from staging: ' + ', '.join(sorted(set(expected) - installed)))
kernel_hash = hashlib.sha256((arguments.kernel / 'kernel').read_bytes()).hexdigest()
if hashlib.sha256((arguments.product / 'kernel').read_bytes()).hexdigest() != kernel_hash:
    raise RuntimeError('Staged kernel differs from the matched kernel output')
record['kernel_sha256'] = kernel_hash
with arguments.output.open('x') as stream:
    json.dump(record, stream, indent=2)
    stream.write('\n')
print(f'PASS: staged kernel and {len(installed)} modules match the verified build byte-for-byte')
