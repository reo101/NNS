"""Check a console log pulled from the external virtiofsd AVF experiment."""
from pathlib import Path
import re
import sys

console = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', Path(sys.argv[1]).read_text())
console = console.replace('[console] ', '').replace('[log] ', '')
markers = [
    'VM started; external read-only filesystem backend=',
    'nns-guest: absolute store symlink',
    'nns-guest: relative store symlink',
    'nns-guest: STORE SYMLINK READS SUCCEEDED',
    'nns-guest: GUEST STORE READY',
    'nns-guest: PACKAGE REALISATION AND EXECUTION SUCCEEDED',
    'nns-guest: GUEST BUILD AND PHONE PUBLICATION SUCCEEDED',
    'nns-guest: GUEST DNS AND HTTPS SUCCEEDED',
]
for marker in markers:
    assert marker in console, f'Missing boot proof: {marker}'
# Serial autologin can suppress the per-target status line. The guest's
# own multi-user target report proves the default target completed.
assert 'nns-guest: MULTI USER active' in console or re.search(
    r'nns-guest: SYSTEM STATE (running|degraded)', console
) or (
    'Queued start job for default target Multi-User System.' in console
    and re.search(r'Startup finished in [^\n]*\(userspace\)', console)
), 'Missing proof that the multi-user target completed'
assert 'Input/output error' not in console, 'Shared-store I/O failure'
assert 'nns-guest: GUEST STORE FAILED' not in console, 'Guest store preparation failed'
assert 'nns-guest: PHONE STORE UNREACHABLE' not in console, 'Phone bridge unavailable'
assert 'nns-guest: BUILD PARTITION MISSING' not in console, 'Build partition missing'
assert 'nns-guest: GUEST DNS OR HTTPS FAILED' not in console, 'Guest network failed'
print('AVF boot, store seed, sandboxed guest build, phone publication, and guest HTTPS verified')
