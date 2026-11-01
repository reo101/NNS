#!/usr/bin/env python3
"""Prepare the authorized, authenticated userdebug profile in a private VM overlay."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace', type=Path, required=True)
parser.add_argument('--lab', type=Path, required=True)
arguments = parser.parse_args()
workspace, lab = (path.resolve(strict=True) for path in (arguments.workspace, arguments.lab))
if lab.parent != workspace / 'temporary/module-btrfs/storage-vm':
    parser.error('A disposable storage VM lab is required')
for unit in ('nns-storage-vm.service', 'nns-storage-vm-native-build.service'):
    if subprocess.run(['systemctl', '--user', 'is-active', '--quiet', unit]).returncode == 0:
        parser.error('Stop the VM and native build before changing their inputs')
manifest = Path(__file__).with_name('authenticated-init.json')
specifications = json.loads(manifest.read_text())
relative, specification = next(iter(specifications.items()))
source = workspace / 'source' / relative
contents = source.read_bytes()
if hashlib.sha256(contents).hexdigest() != specification['sha256']:
    parser.error('Unreviewed init baseline')
text = contents.decode()
for previous, replacement in specification['replacements']:
    if text.count(previous) != 1:
        parser.error('Missing or ambiguous init replacement block')
    text = text.replace(previous, replacement)
destination = lab / 'source-overrides/authenticated-property-service.cpp'
record_path = lab / 'observations/authenticated-init-inputs.json'
if destination.exists() or record_path.exists():
    parser.error('Refusing to replace an existing init preparation')
product = lab / 'source-overrides/product.mk'
product_before = hashlib.sha256(product.read_bytes()).hexdigest()
inputs = json.loads((lab / 'observations/source-inputs.json').read_text())
if product_before != inputs['overlay_inputs']['product.mk']:
    parser.error('The private product differs from its export record')
with destination.open('x') as stream:
    stream.write(text)
validator = Path(__file__).resolve().parents[1] / 'signing-migration/check-lab-init.py'
subprocess.run([sys.executable, str(validator), str(destination)], check=True)
with product.open('a') as stream:
    stream.write('\n# Authenticated userdebug access for the disposable VM only.\n'
                 'PRODUCT_SYSTEM_EXT_PROPERTIES += ro.console.enable=1\n'
                 'PRODUCT_PACKAGES += adb_root\n'
                 'PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system_ext/bin/adb_root system_ext/etc/init/adb_root.rc\n')
record = {
    'source': relative, 'source_sha256': specification['sha256'],
    'overlay_sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
    'manifest_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
    'product_before_sha256': product_before,
    'product_after_sha256': hashlib.sha256(product.read_bytes()).hexdigest(),
    'properties': {'ro.debuggable': '1', 'ro.adb.secure': '1',
                   'ro.force.debuggable': '0', 'service.adb.root': '0'},
    'source_checkout_changed': False,
}
with record_path.open('x') as stream:
    json.dump(record, stream, indent=2)
    stream.write('\n')
print('PASS: private authenticated userdebug init profile prepared')
