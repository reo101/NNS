"""Check lab state comparison and key-generation guards without an Android VM."""
import copy
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / 'tests/signing-migration'
validation = runpy.run_path(str(LAB / 'check-state.py'))
packages = validation['PACKAGES']
validate = validation['validate_preservation']
before = {
    package: {
        'package': package, 'passed': True, 'phase': 'seed',
        'uid': 1000 if package.endswith('.system') else 10123,
        'credential_encrypted_sha256': 'a' * 64,
        'device_encrypted_sha256': 'b' * 64,
        'certificate_sha256': 'c' * 64 if package.endswith('.system') else 'd' * 64,
        'key_security_level': 0, 'key_user_authentication_required': False,
        'permission': 'fixture-permission', 'permission_granted': True,
    } for package in packages
}
after = copy.deepcopy(before)
for report in after.values():
    report['phase'] = 'verify'
after[packages[0]]['certificate_sha256'] = 'e' * 64
assert validate(before, after, 'e' * 64)['state'] == 'preserved'
control = copy.deepcopy(after)
control[packages[0]]['certificate_sha256'] = 'c' * 64
assert validate(before, control, 'c' * 64)['state'] == 'preserved'

for package, field, value in (
    (packages[0], 'uid', 1001),
    (packages[1], 'uid', 10124),
    (packages[0], 'credential_encrypted_sha256', 'f' * 64),
    (packages[1], 'device_encrypted_sha256', 'f' * 64),
    (packages[0], 'certificate_sha256', 'c' * 64),
    (packages[1], 'certificate_sha256', 'e' * 64),
    (packages[0], 'key_security_level', None),
    (packages[0], 'permission_granted', False),
    (packages[1], 'key_user_authentication_required', True),
    (packages[0], 'phase', 'seed'),
    (packages[1], 'passed', False),
):
    changed = copy.deepcopy(after)
    changed[package][field] = value
    try:
        validate(before, changed, 'e' * 64)
    except ValueError:
        pass
    else:
        raise AssertionError(f'Changed fixture state was accepted: {package} {field}')

with tempfile.TemporaryDirectory(prefix='nns-signing-key-guard-') as temporary:
    lab = Path(temporary)
    result = subprocess.run(['bash', str(LAB / 'generate-lab-keys.sh'), str(lab)],
                            capture_output=True, text=True)
    assert result.returncode != 0
    assert not (lab / 'signing-keys').exists(), 'Keys were created before an ignore rule'
    (lab / '.gitignore').write_text('signing-keys/\n')
    keys = lab / 'signing-keys/lab'
    keys.mkdir(parents=True)
    existing = keys / 'releasekey.pk8'
    existing.write_bytes(b'non-secret existing-file fixture\n')
    result = subprocess.run(['bash', str(LAB / 'generate-lab-keys.sh'), str(lab)],
                            capture_output=True, text=True)
    assert result.returncode != 0
    assert existing.read_bytes() == b'non-secret existing-file fixture\n'
    assert list(keys.iterdir()) == [existing], 'Existing-key refusal generated other keys'
    result = subprocess.run([sys.executable, str(LAB / 'run-fixtures.py'),
        '--adb', '/nonexistent-adb', '--phase', 'verify', '--output', str(lab / 'report.json')],
        env=os.environ | {'ADB_SERVER_SOCKET': '', 'ADB_USB': '0', 'ADB_MDNS': '0'},
        capture_output=True, text=True)
    assert result.returncode == 2 and 'isolated signing-lab ADB socket' in result.stderr
    assert not (lab / 'report.json').exists()

print('PASS: signing-state preservation, refusal cases and ignore-before-key-generation guards')
