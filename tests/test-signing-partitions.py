"""Exercise lab-only OS partition replacement on disposable GPT disk files."""
import hashlib
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
replacement = runpy.run_path(str(ROOT / 'tests/signing-migration/replace-os-partitions.py'))
replace = replacement['replace_partitions']


def refuse(*arguments):
    try:
        replace(*arguments)
    except ValueError:
        return
    raise AssertionError('Unsafe partition replacement was accepted')


with tempfile.TemporaryDirectory(prefix='nns-signing-partitions-') as temporary:
    parent = Path(temporary)
    lab = parent / 'lab'
    lab.mkdir()
    (lab / '.gitignore').write_text('signing-keys/\n')
    original = lab / 'original.raw'
    with original.open('wb') as stream:
        stream.truncate(32 * 1024**2)
    layout = ('label: gpt\nunit: sectors\n'
              'start=2048,size=2048,name="boot_a"\n'
              'start=4096,size=2048,name="boot_b"\n'
              'start=6144,size=8192,name="super"\n'
              'start=14336,size=8192,name="userdata"\n'
              'start=22528,size=4096,name="metadata"\n'
              'start=26624,size=2048,name="misc"\n')
    subprocess.run(['sfdisk', str(original)], input=layout, text=True,
                   check=True, capture_output=True)
    with original.open('r+b') as stream:
        for sector in (14336, 22528, 26624):
            stream.seek(sector * 512)
            stream.write(b'preserved-lab-state\n')
        stream.seek(4096 * 512 - 32)
        stream.write(b'old-partition-footer'.ljust(32, b'x'))
    images = lab / 'images'
    images.mkdir()
    (images / 'boot.img').write_bytes(b'replacement-boot\n')
    (images / 'super.img').write_bytes(b'replacement-super\n')
    disk = lab / 'patched.raw'
    shutil.copyfile(original, disk)
    report = replace(lab, disk, images)
    assert report['replaced'] == ['boot_a', 'boot_b', 'super']
    assert set(report['preserved_partition_sha256']) == {'userdata', 'metadata', 'misc'}
    with disk.open('rb') as stream:
        stream.seek(2048 * 512)
        assert stream.read(17) == b'replacement-boot\n'
        stream.seek(4096 * 512 - 32)
        assert stream.read(32) == bytes(32), 'Old partition footer was not cleared'
        stream.seek(6144 * 512)
        assert stream.read(18) == b'replacement-super\n'
    table = replacement['partition_table'](disk)
    for partition in table:
        if partition['name'] in report['preserved_partition_sha256']:
            assert replacement['partition_hash'](original, partition) == replacement['partition_hash'](disk, partition)
    oversized = lab / 'oversized.raw'
    shutil.copyfile(original, oversized)
    previous = hashlib.sha256(oversized.read_bytes()).digest()
    (images / 'boot.img').write_bytes(b'x' * (1024**2 + 1))
    refuse(lab, oversized, images)
    assert hashlib.sha256(oversized.read_bytes()).digest() == previous
    linked = lab / 'linked.raw'
    linked.symlink_to(original)
    refuse(lab, linked, images)
    linked.unlink()
    linked.hardlink_to(original)
    refuse(lab, linked, images)
    linked.unlink()
    external = parent / 'outside.raw'
    shutil.copyfile(original, external)
    refuse(lab, external, images)

print('PASS: OS-only GPT replacement preserves userdata/metadata/misc and refuses unsafe disk copies or image sizes')
