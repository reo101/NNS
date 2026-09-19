import hashlib
import importlib.util
import struct
import sys
import unittest

spec = importlib.util.spec_from_file_location('repacker', sys.argv.pop(1))
repacker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repacker)


class RepackTest(unittest.TestCase):
    def setUp(self):
        self.stock = bytearray(8192)
        self.stock[:8] = b'ANDROID!'
        struct.pack_into('<I', self.stock, 8, 512)
        struct.pack_into('<I', self.stock, 20, 1584)
        struct.pack_into('<I', self.stock, 40, 4)
        self.vbmeta = bytearray(512)
        self.vbmeta[:4] = b'AVB0'
        struct.pack_into('>QQ', self.vbmeta, 12, 64, 192)
        struct.pack_into('>I', self.vbmeta, 120, 3)
        self.expected = dict(size=512, hash_alg='sha256', flags=3,
                             digest=hashlib.sha256(self.vbmeta).hexdigest())
        self.kernel = bytearray(256)
        self.kernel[56:60] = b'ARM\x64'
        self.kernel += ' '.join(f'androidboot.vbmeta.{key}={self.expected[key]}'
                                for key in ('size', 'hash_alg', 'digest')).encode()

    def pack(self):
        return repacker.repack(self.stock, self.kernel, self.vbmeta, self.expected)

    def test_preserves_header_and_payload_without_footer(self):
        result = self.pack()
        header = self.stock[:4096]
        struct.pack_into('<I', header, 8, len(self.kernel))
        self.assertEqual(result[:4096], header)
        self.assertEqual(result[4096:4096+len(self.kernel)], self.kernel)
        self.assertEqual(result[4096+len(self.kernel):], bytes(-len(self.kernel) % 4096))
        self.assertEqual(len(result) % 4096, 0)

    def test_rejects_incompatible_headers(self):
        for offset, value in ((40, 3), (12, 8), (20, 0), (1580, 4096), (8, 100000)):
            with self.subTest(offset=offset):
                old = self.stock[offset:offset+4]
                struct.pack_into('<I', self.stock, offset, value)
                with self.assertRaises(ValueError):
                    self.pack()
                self.stock[offset:offset+4] = old

    def test_checks_vbmeta_struct_not_padding(self):
        self.vbmeta += bytes(4096)
        self.pack()
        self.vbmeta[256] ^= 1
        with self.assertRaisesRegex(ValueError, 'digest'):
            self.pack()

    def test_rejects_wrong_kernel_profile(self):
        self.kernel[-1] ^= 1
        with self.assertRaisesRegex(ValueError, 'kernel'):
            self.pack()


unittest.main()
