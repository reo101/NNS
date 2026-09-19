"""Repack a kernel-only Android boot-v4 image; never flash or add an AVB footer."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

PAGE = 4096


def repack(stock, kernel, vbmeta, expected):
    if len(stock) < PAGE or stock[:8] != b'ANDROID!':
        raise ValueError('not an Android boot image')
    old_size, ramdisk_size = struct.unpack_from('<II', stock, 8)
    if struct.unpack_from('<I', stock, 40)[0] != 4:
        raise ValueError('only boot header v4 is supported')
    if ramdisk_size:
        raise ValueError('refusing to discard a ramdisk')
    if struct.unpack_from('<I', stock, 20)[0] != 1584:
        raise ValueError('unexpected v4 header size')
    if struct.unpack_from('<I', stock, 1580)[0]:
        raise ValueError('signed boot payload unsupported; would invalidate its signature')
    if not 0 < old_size <= len(stock) - PAGE:
        raise ValueError('truncated stock kernel')
    if len(kernel) < 64 or kernel[56:60] != b'ARM\x64':
        raise ValueError('expected an uncompressed ARM64 Image')
    if len(vbmeta) < 256 or vbmeta[:4] != b'AVB0':
        raise ValueError('invalid vbmeta header')
    size = 256 + sum(struct.unpack_from('>QQ', vbmeta, 12))
    if size > len(vbmeta) or size != expected['size']:
        raise ValueError('vbmeta struct size does not match this kernel profile')
    if expected['hash_alg'] != 'sha256' or hashlib.sha256(vbmeta[:size]).hexdigest() != expected['digest']:
        raise ValueError('vbmeta digest does not match this kernel profile')
    if struct.unpack_from('>I', vbmeta, 120)[0] != expected['flags']:
        raise ValueError('vbmeta flags do not match this kernel profile')
    for key in ('size', 'hash_alg', 'digest'):
        if f'androidboot.vbmeta.{key}={expected[key]}'.encode() not in kernel:
            raise ValueError(f'kernel does not contain the expected vbmeta.{key}')
    result = bytearray(stock[:PAGE])
    struct.pack_into('<I', result, 8, len(kernel))
    result += kernel + bytes(-len(kernel) % PAGE)
    if len(result) > 64 * 1024 * 1024:
        raise ValueError('boot image exceeds the cheetah boot partition size')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stock', type=Path)
    parser.add_argument('kernel', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--vbmeta', type=Path, required=True,
                        help='dump/image of the matching vbmeta partition; checked, never modified')
    parser.add_argument('--manifest', type=Path, required=True)
    args = parser.parse_args()
    try:
        expected = json.loads(args.manifest.read_text())
        result = repack(args.stock.read_bytes(), args.kernel.read_bytes(),
                        args.vbmeta.read_bytes(), expected)
        with args.output.open('xb') as output:  # No accidental input/output overwrite.
            output.write(result)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'repack: {error}\n')
    print(f'{args.output}: {len(result)} bytes, sha256={hashlib.sha256(result).hexdigest()}')
    print('No partitions flashed. This image is tied to the verified vbmeta profile.')


if __name__ == '__main__':
    main()
