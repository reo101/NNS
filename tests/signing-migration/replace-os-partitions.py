#!/usr/bin/env python3
"""Replace OS partitions in a stopped lab's raw disk copy, never a block device."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

OS_IMAGES = {'super': 'super.img'} | {
    partition + slot: partition + '.img'
    for partition in ('boot', 'init_boot', 'vendor_boot', 'vbmeta', 'vbmeta_system',
                      'vbmeta_vendor_dlkm', 'vbmeta_system_dlkm')
    for slot in ('_a', '_b')
}


def partition_table(image):
    table = json.loads(subprocess.check_output(['sfdisk', '--json', str(image)], text=True))['partitiontable']
    if table['label'] != 'gpt' or table['unit'] != 'sectors':
        raise ValueError('Expected a GPT disk with sector offsets')
    partitions = table['partitions']
    names = [partition.get('name') for partition in partitions]
    if len(set(names)) != len(names) or not {'userdata', 'metadata', 'misc'} <= set(names):
        raise ValueError('Distinct userdata, metadata and misc partitions are required')
    size = image.stat().st_size
    for partition in partitions:
        partition['offset'] = partition['start'] * table['sectorsize']
        partition['length'] = partition['size'] * table['sectorsize']
        if partition['offset'] < 0 or partition['length'] <= 0 or partition['offset'] + partition['length'] > size:
            raise ValueError('Partition exceeds the raw disk copy')
    ordered = sorted(partitions, key=lambda partition: partition['offset'])
    if any(left['offset'] + left['length'] > right['offset'] for left, right in zip(ordered, ordered[1:])):
        raise ValueError('Overlapping partitions are refused')
    return partitions


def partition_hash(image, partition):
    digest = hashlib.sha256()
    with image.open('rb') as stream:
        stream.seek(partition['offset'])
        remaining = partition['length']
        while remaining:
            contents = stream.read(min(remaining, 4 * 1024**2))
            if not contents:
                raise ValueError('Truncated raw disk copy')
            digest.update(contents)
            remaining -= len(contents)
    return digest.hexdigest()


def replace_partitions(lab, image, images):
    lab = lab.resolve(strict=True)
    if 'signing-keys/' not in (lab / '.gitignore').read_text().splitlines():
        raise ValueError('Expected the ignored disposable lab directory')
    status = image.lstat()
    if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
        raise ValueError('Only an unshared regular raw disk copy is allowed')
    image = image.resolve(strict=True)
    if not image.is_relative_to(lab) or image.is_relative_to(lab / 'signing-keys'):
        raise ValueError('Raw disk copy must be inside the lab and outside its keys')
    partitions = partition_table(image)
    preserved = {partition['name']: partition_hash(image, partition)
                 for partition in partitions if partition['name'] not in OS_IMAGES}
    replacements = []
    with tempfile.TemporaryDirectory(prefix='partition-images-', dir=lab) as temporary:
        for partition in partitions:
            if partition['name'] not in OS_IMAGES:
                continue
            source = images / OS_IMAGES[partition['name']]
            if source.is_symlink() or not stat.S_ISREG(source.stat().st_mode) or source.resolve() == image:
                raise ValueError('Expected a separate regular replacement image')
            with source.open('rb') as stream:
                sparse = stream.read(4) == b'\x3a\xff\x26\xed'
            if sparse:
                converted = Path(temporary) / partition['name']
                subprocess.run(['simg2img', str(source), str(converted)], check=True)
                source = converted
            if not 0 < source.stat().st_size <= partition['length']:
                raise ValueError('Replacement image does not fit: ' + partition['name'])
            replacements.append((partition, source))
        if not replacements or not any(partition['name'] == 'super' for partition, _ in replacements):
            raise ValueError('Expected OS partitions including super')
        with image.open('r+b') as output:
            for partition, source in replacements:
                subprocess.run(['fallocate', '--punch-hole', '--keep-size',
                                '--offset', str(partition['offset']), '--length', str(partition['length']),
                                str(image)], check=True)
                output.seek(partition['offset'])
                with source.open('rb') as contents:
                    shutil.copyfileobj(contents, output, 4 * 1024**2)
                output.flush()
            os.fsync(output.fileno())
    if partition_table(image) != partitions:
        raise ValueError('Partition table changed')
    for partition in partitions:
        if partition['name'] in preserved and partition_hash(image, partition) != preserved[partition['name']]:
            raise ValueError('Non-OS partition changed: ' + partition['name'])
    return {'state': 'os_partitions_replaced', 'image': str(image),
            'replaced': [partition['name'] for partition, _ in replacements],
            'preserved_partition_sha256': preserved,
            'package_manager_state_edited': False, 'physical_device_validated': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lab-directory', type=Path, required=True)
    parser.add_argument('--raw-disk-copy', type=Path, required=True)
    parser.add_argument('--images', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    report = replace_partitions(arguments.lab_directory, arguments.raw_disk_copy, arguments.images)
    with arguments.output.open('x') as output:
        output.write(json.dumps(report, indent=2) + '\n')
