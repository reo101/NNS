"""Host preload integration tests with a deterministic protocol helper.
Usage: python3 tests/test-dns.py /absolute/path/libnns-dns.so
"""
import concurrent.futures
import ctypes as c
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

MAGIC = 0x31444E4E
HEADER = struct.Struct('<IiiI')
RECORD = struct.Struct('<iiiII28s256s')


def helper():
    flags, family, socktype, protocol = map(int, sys.argv[1:5])
    node = sys.argv[6] if sys.argv[5] == '1' else None
    service = sys.argv[8] if sys.argv[7] == '1' else None
    if node == 'truncated':
        os.write(1, HEADER.pack(MAGIC, 0, 0, 1))
        return
    if node == 'too-many':
        os.write(1, HEADER.pack(MAGIC, 0, 0, 65))
        return
    if node == 'noname':
        os.write(1, HEADER.pack(MAGIC, -2, 0, 0))
        return
    if node == 'system-error':
        os.write(1, HEADER.pack(MAGIC, -11, 13, 0))
        return
    if node == 'environment':
        assert 'LD_PRELOAD' not in os.environ
        assert 'LD_LIBRARY_PATH' not in os.environ
    if node == 'flags':
        assert flags == 0x408, flags  # ADDRCONFIG | NUMERICSERV
    family = family or 2
    addr = (struct.pack('<H', family) + struct.pack('!H', int(service or 0)))
    addr += (b'\x7f\x00\x00\x01' + bytes(8) if family == 2 else
             bytes(4) + bytes(15) + b'\x01' + struct.pack('<I', 42))
    canonical = b'canonical.test' if flags & 2 else b''
    count = 256 if node == 'bad-name' else len(canonical)
    os.write(1, HEADER.pack(MAGIC, 0, 0, 1))
    os.write(1, RECORD.pack(family, socktype, protocol, len(addr), count, addr, canonical))
    if node == 'failed-exit':
        sys.exit(1)


class AI(c.Structure):
    pass


AI._fields_ = [('flags', c.c_int), ('family', c.c_int), ('socktype', c.c_int),
               ('protocol', c.c_int), ('addrlen', c.c_uint), ('addr', c.c_void_p),
               ('canon', c.c_char_p), ('next', c.POINTER(AI))]


def checks():
    libc = c.CDLL(None, use_errno=True)
    libc.getaddrinfo.argtypes = [c.c_char_p, c.c_char_p, c.POINTER(AI), c.POINTER(c.POINTER(AI))]
    libc.freeaddrinfo.argtypes = [c.POINTER(AI)]

    def lookup(node, family=2, flags=0, expected=0, hints=True, service=b'443'):
        h = AI(flags=flags, family=family, socktype=1, protocol=6)
        out = c.POINTER(AI)()
        rc = libc.getaddrinfo(node, service, c.byref(h) if hints else None, c.byref(out))
        assert rc == expected, (node, rc, expected)
        if rc:
            assert not out
            if rc == -11:
                assert c.get_errno() == 13
            return
        try:
            assert out and out.contents.family == family
            ai = out.contents
            addr = c.string_at(ai.addr, ai.addrlen)
            assert addr[2:4] == b'\x01\xbb'
            if family == 10:
                assert len(addr) == 28 and addr[-4:] == struct.pack('<I', 42)
            if flags & 2:
                assert ai.canon == b'canonical.test'
        finally:
            libc.freeaddrinfo(out)  # real glibc ownership, not a custom free

    before_env = dict(os.environ)
    before_fds = len(os.listdir('/proc/self/fd'))
    lookup(b'environment')
    lookup(b'flags', flags=0x420)
    lookup(b'ipv6', family=10, flags=2)
    lookup(None)
    lookup(b'default-hints', hints=False)
    lookup(b'noname', expected=-2)
    lookup(b'system-error', expected=-11)
    lookup(b'bad-flags', flags=0x40, expected=-1)
    lookup(b'bad-family', family=1, expected=-6)
    lookup(None, service=None, expected=-2)
    for node in (b'truncated', b'too-many', b'bad-name', b'failed-exit'):
        lookup(node, expected=-3)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda _: lookup(b'environment', flags=2), range(64)))
    original_helper = os.environ['NNS_DNS_HELPER']
    os.environ['NNS_DNS_HELPER'] = '/no/such/nns-helper'
    lookup(b'missing-helper', expected=-3)
    os.environ['NNS_DNS_HELPER'] = original_helper
    assert dict(os.environ) == before_env
    assert len(os.listdir('/proc/self/fd')) == before_fds
    try:
        os.waitpid(-1, os.WNOHANG)
    except ChildProcessError:
        pass
    else:
        raise AssertionError('unreaped helper')
    print('PASS: DNS preload ABI, IPv6/scope, canonname/free, flags, errors, malformed replies, concurrent calls, environment and fd/child cleanup')


if __name__ == 'helper':
    helper()
elif sys.argv[1] == '--child':
    checks()
else:
    with tempfile.TemporaryDirectory(prefix='nns-dns-test-') as directory:
        mock = Path(directory) / 'resolver'
        mock.write_text(f'#!{sys.executable}\nimport runpy\nrunpy.run_path({str(Path(__file__).resolve())!r}, run_name="helper")\n')
        mock.chmod(0o755)
        env = dict(os.environ, LD_PRELOAD=str(Path(sys.argv[1]).resolve()), NNS_DNS_HELPER=str(mock))
        subprocess.run([sys.executable, __file__, '--child'], env=env, check=True, timeout=60)
