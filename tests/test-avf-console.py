"""Check a console log pulled from the external virtiofsd AVF experiment."""
from pathlib import Path
import re
import sys

console = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', Path(sys.argv[1]).read_text())
markers = [
    'VM started; external read-only filesystem backend=',
    'nns-guest: absolute store symlink',
    'nns-guest: relative store symlink',
    'nns-guest: STORE SYMLINK READS SUCCEEDED',
    'nns-guest: PHONE DAEMON REACHABLE',
    'nns-guest: PACKAGE REALISATION AND EXECUTION SUCCEEDED',
    'nns-guest: DAEMON BUILD AND STORE VISIBILITY SUCCEEDED',
    'nns-guest: SHARED STORE WRITE REJECTED',
    'nns-guest: GUEST DNS AND HTTPS SUCCEEDED',
    'Reached target Multi-User System.',
]
for marker in markers:
    assert marker in console, f'Missing boot proof: {marker}'
assert 'Input/output error' not in console, 'Shared-store I/O failure'
assert 'nns-guest: PHONE DAEMON UNREACHABLE' not in console, 'Daemon bridge failed'
assert 'nns-guest: SHARED STORE UNEXPECTEDLY WRITABLE' not in console, 'Store export is writable'
assert 'nns-guest: GUEST DNS OR HTTPS FAILED' not in console, 'Guest network failed'
print('AVF boot, package realisation, daemon build, read-only store, and guest HTTPS verified')
