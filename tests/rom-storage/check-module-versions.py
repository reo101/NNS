#!/usr/bin/env python3
"""Verify every module import against the matched kernel/module symbol versions."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--modules', type=Path, required=True)
parser.add_argument('--symvers', type=Path, required=True)
parser.add_argument('--release', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
arguments = parser.parse_args()
release = arguments.release.read_text().strip()
versions = {}
for line in arguments.symvers.read_text().splitlines():
    fields = line.split()
    version, symbol = int(fields[0], 16), fields[1]
    if symbol in versions and versions[symbol] != version:
        raise RuntimeError('Conflicting exported symbol version: ' + symbol)
    versions[symbol] = version
modules = sorted(arguments.modules.glob('*.ko'))
if not modules or 'module_layout' not in versions:
    raise RuntimeError('A complete module set and kernel symbol versions are required')
record = {'release': release, 'module_layout': hex(versions['module_layout']), 'modules': {}}
for module in modules:
    imported = subprocess.run(['modprobe', '--show-modversions', str(module)],
                              check=True, capture_output=True, text=True).stdout
    imports = {}
    for line in imported.splitlines():
        version, symbol = line.split()
        imports[symbol] = int(version, 16)
        if versions.get(symbol) != imports[symbol]:
            raise RuntimeError(f'{module.name}: mismatched or missing symbol {symbol}')
    if imports.get('module_layout') != versions['module_layout']:
        raise RuntimeError('Missing module_layout version: ' + module.name)
    vermagic = subprocess.run(['modinfo', '-F', 'vermagic', str(module)],
                              check=True, capture_output=True, text=True).stdout.strip()
    signer = subprocess.run(['modinfo', '-F', 'signer', str(module)],
                            check=True, capture_output=True, text=True).stdout.strip()
    if not vermagic.startswith(release + ' ') or not signer:
        raise RuntimeError('Wrong kernel release or unsigned module: ' + module.name)
    record['modules'][module.name] = {
        'sha256': hashlib.sha256(module.read_bytes()).hexdigest(),
        'imports_checked': len(imports), 'vermagic': vermagic, 'signer': signer,
    }
with arguments.output.open('x') as stream:
    json.dump(record, stream, indent=2)
    stream.write('\n')
print(f'PASS: {len(modules)} signed modules match the kernel and exported symbol versions')
