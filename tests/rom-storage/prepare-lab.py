#!/usr/bin/env python3
"""Export a VM-only storage candidate into a private ROM build overlay."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from platform_policy import prepare_overlay

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace', type=Path, required=True)
parser.add_argument('--lab', type=Path, required=True)
parser.add_argument('--export', dest='export_root', type=Path, required=True)
parser.add_argument('--image', type=Path, required=True)
parser.add_argument('--arm64-controller', type=Path, required=True)
parser.add_argument('--x86_64-controller', type=Path, required=True)
arguments = parser.parse_args()
workspace, lab, export_root = (path.resolve(strict=True) for path in
                              (arguments.workspace, arguments.lab, arguments.export_root))
if lab.parent != workspace / 'temporary/module-btrfs/storage-vm':
    parser.error('A separate storage VM lab directory is required')
if not (lab / 'authentication/adb.pub').is_file() or not (lab / 'output-cache').is_dir():
    parser.error('Prepare the private cache and fresh ADB authentication key first')
image = arguments.image.resolve(strict=True)
if image.stat().st_size != 256 * 1024 * 1024:
    parser.error('The prepared 256 MiB fixture image is required')
with image.open('rb') as stream:
    stream.seek(65536 + 0x40)
    if stream.read(8) != b'_BHRfS_M':
        parser.error('The fixture does not contain a Btrfs primary superblock')
source = workspace / 'source'
overlay = lab / 'source-overrides'
integration = overlay / 'nns-rom'
if integration.exists():
    parser.error('Refusing to replace an existing source overlay')

inputs = {}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_text(relative):
    path = source / relative
    inputs[relative] = digest(path)
    return path.read_text()


def replace_once(text, previous, replacement):
    if text.count(previous) != 1:
        raise RuntimeError('Source baseline does not contain one expected block: ' + previous)
    return text.replace(previous, replacement)


integration.mkdir()
for name in ('Android.bp', 'BoardConfig.mk', 'product.mk', 'init.nns-mount.rc',
             'nns-mount.c', 'nns-backing.c', 'nns-backing.h', 'nns-init.inc'):
    shutil.copy2(export_root / 'integrations/rom' / name, integration / name)
for name in ('sepolicy', 'storage'):
    shutil.copytree(export_root / 'integrations/rom' / name, integration / name)
shutil.copy2(arguments.arm64_controller.resolve(strict=True), integration / 'storage/libnns-storage-controller-arm64.a')
shutil.copy2(arguments.x86_64_controller.resolve(strict=True), integration / 'storage/libnns-storage-controller-x86_64.a')
shutil.copy2(integration / 'storage/Android.bp.in', integration / 'storage/Android.bp')
shutil.copytree(export_root / 'tests/rom-storage', integration / 'storage-fixture',
                ignore=shutil.ignore_patterns('__pycache__'))
shutil.copy2(image, integration / 'storage-fixture/nix.btrfs')
shutil.copy2(lab / 'authentication/adb.pub', integration / 'storage-fixture/adb.pub')

mount_rc = integration / 'init.nns-mount.rc'
mount_rc.write_text(replace_once(mount_rc.read_text(), '    exec_start nns-mount\n',
    '    mkdir /data/nns-storage 0700 root root encryption=Require\n'
    '    mkdir /data/nns-storage-results 0755 root root encryption=Require\n'
    '    exec_start nns-storage\n\n'
    'on property:sys.nns.storage.ready=1\n'
    '    exec_start nns-mount\n'
    '    exec_start nns-storage-consumer\n'))

board = source_text('device/google/cuttlefish/vsoc_x86_64/BoardConfig.mk')
board = replace_once(board,
    'SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += external/nns-rom-tests/sepolicy\n',
    'SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += external/nns-rom/storage/sepolicy external/nns-rom/storage-fixture/sepolicy\n')
(overlay / 'BoardConfig.mk').write_text(board)
product = source_text('vendor/lineage/build/target/product/lineage_cf_phone_x86_64.mk')
product = replace_once(product,
    'PRODUCT_PACKAGES += nns-fixture\n'
    'PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \\\n'
    '    system/bin/nns-fixture \\\n'
    '    system/etc/init/init.nns-fixture.rc\n',
    'PRODUCT_PACKAGES += nns-storage nns-storage-fixture nns-storage-fixture-image NnsStorageApplicationFixture\n'
    'PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \\\n'
    '    system/bin/nns-storage \\\n'
    '    system/etc/init/init.nns-storage.rc \\\n'
    '    system/bin/nns-storage-fixture \\\n'
    '    system/etc/init/init.nns-storage-fixture.rc \\\n'
    '    system/etc/nns-storage-fixture/nix.btrfs \\\n'
    '    system/app/NnsStorageApplicationFixture/%\n'
    'PRODUCT_SYSTEM_EXT_PROPERTIES += ro.nns.storage.fixture=1\n'
    'PRODUCT_ADB_KEYS := external/nns-rom/storage-fixture/adb.pub\n')
(overlay / 'product.mk').write_text(product)

platform_policy = prepare_overlay(source, overlay)
inputs.update(platform_policy['source_inputs'])
record = {'source_inputs': inputs, 'platform_policy': platform_policy,
          'overlay_inputs': {str(path.relative_to(overlay)): digest(path)
                             for path in sorted(overlay.rglob('*')) if path.is_file()},
          'image_sha256': digest(image), 'private_adb_key_exported': False}
with (lab / 'observations/source-inputs.json').open('x') as output:
    json.dump(record, output, indent=2)
    output.write('\n')
print('PASS: private VM source overlay exported without changing the ROM checkout')
