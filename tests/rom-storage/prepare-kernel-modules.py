#!/usr/bin/env python3
"""Export a matched kernel/module pair into private Cuttlefish source overlays."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace', type=Path, required=True)
parser.add_argument('--lab', type=Path, required=True)
parser.add_argument('--kernel', type=Path, required=True)
arguments = parser.parse_args()
workspace, lab, kernel = (path.resolve(strict=True) for path in
                          (arguments.workspace, arguments.lab, arguments.kernel))
if lab.parent != workspace / 'temporary/module-btrfs/storage-vm' or kernel.parent != Path('/nix/store'):
    parser.error('A disposable storage lab and Nix-built kernel output are required')
for unit in ('nns-storage-vm.service', 'nns-storage-vm-native-build.service'):
    if subprocess.run(['systemctl', '--user', 'is-active', '--quiet', unit]).returncode == 0:
        parser.error('Stop the VM and native build before preparing their inputs')
if subprocess.run(['pgrep', '-u', str(lab.stat().st_uid), '-x', 'run_cvd'],
                  capture_output=True).returncode == 0:
    parser.error('A Cuttlefish runtime is still active')
record_path = lab / 'observations/kernel-module-inputs.json'
artifact = lab / 'artifacts/matched-kernel'
if record_path.exists() or artifact.exists():
    parser.error('Refusing to replace an existing matched-kernel preparation')
versions = json.loads((kernel / 'module-versions.json').read_text())
if versions['release'] != '6.12.38-android16-5-g501f58f107ab-ab13974591':
    parser.error('The reviewed kernel release is required')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


modules = versions['modules']
for name, metadata in modules.items():
    if Path(name).name != name or not name.endswith('.ko'):
        parser.error('Invalid module basename')
    if digest(kernel / 'modules' / name) != metadata['sha256']:
        parser.error('Module content differs from its version-check record: ' + name)
source = workspace / 'source'
locations = {
    'gki-modules': source / 'kernel/prebuilts/6.12/x86_64',
    'virtual-device-modules': source / 'kernel/prebuilts/common-modules/virtual-device/6.12/x86-64',
}
inventories = {name: sorted(path.glob('*.ko')) for name, path in locations.items()}
original_names = {path.name for paths in inventories.values() for path in paths}
missing = original_names - modules.keys()
if missing:
    parser.error('Missing replacements for existing modules: ' + ', '.join(sorted(missing)))
for name in locations:
    if (lab / 'source-overrides' / name).exists():
        parser.error('Refusing to replace an existing module overlay: ' + name)
old_exit = lab / 'observations/native-build-exit.json'
previous_exit = lab / 'observations/native-build-before-matched-modules-exit.json'
if not old_exit.is_file() or previous_exit.exists():
    parser.error('The preceding native-build result must be preserved exactly once')

board = lab / 'source-overrides/BoardConfig.mk'
board_before = digest(board)
source_inputs = json.loads((lab / 'observations/source-inputs.json').read_text())
if board_before != source_inputs['overlay_inputs']['BoardConfig.mk']:
    parser.error('The private BoardConfig differs from its export record')

original_hashes = {}
for name, original in locations.items():
    destination = lab / 'source-overrides' / name
    subprocess.run(['cp', '--archive', '--reflink=always', str(original), str(destination)], check=True)
    for path in inventories[name]:
        original_hashes[str(path.relative_to(source))] = digest(path)
        replacement = destination / path.name
        replacement.unlink()
        # Fresh timestamps prevent Ninja from retaining older cached outputs.
        shutil.copyfile(kernel / 'modules' / path.name, replacement)
# Additional dependency modules belong in system_dlkm, not the vendor autoload list.
for name in sorted(modules.keys() - original_names):
    shutil.copyfile(kernel / 'modules' / name, lab / 'source-overrides/gki-modules' / name)
image = lab / 'source-overrides/gki-modules/kernel-6.12'
original_hashes['kernel/prebuilts/6.12/x86_64/kernel-6.12'] = digest(source / 'kernel/prebuilts/6.12/x86_64/kernel-6.12')
image.unlink()
shutil.copyfile(kernel / 'kernel', image)
# BPF headers must use BTF from this kernel, not the old prebuilt vmlinux.
for name in ('vmlinux', 'System.map'):
    original_hashes['kernel/prebuilts/6.12/x86_64/' + name] = digest(source / 'kernel/prebuilts/6.12/x86_64' / name)
    destination = lab / 'source-overrides/gki-modules' / name
    destination.unlink()
    shutil.copyfile(kernel / name, destination)
subprocess.run(['nix-store', '--add-root', str(artifact), '-r', str(kernel)], check=True)
with board.open('a') as stream:
    stream.write('\n# Nix already strips modules before signing. Preserve those signatures.\n'
                 'BOARD_DO_NOT_STRIP_VENDOR_MODULES := true\n')
old_exit.rename(previous_exit)
record = {
    'kernel_output': str(kernel), 'kernel_sha256': digest(kernel / 'kernel'),
    'version_check_sha256': digest(kernel / 'module-versions.json'),
    'module_count': len(modules), 'release': versions['release'],
    'original_module_inputs': original_hashes,
    'board_before_sha256': board_before, 'board_after_sha256': digest(board),
    'additional_system_modules': sorted(modules.keys() - original_names),
    'source_checkout_changed': False,
    'vmlinux_sha256': digest(kernel / 'vmlinux'),
    'scope': 'Matched kernel, BPF type data and complete module inputs; not a stock GKI ABI certification',
}
with record_path.open('x') as stream:
    json.dump(record, stream, indent=2)
    stream.write('\n')
print('PASS: matched kernel and complete module replacements staged without changing the ROM checkout')
