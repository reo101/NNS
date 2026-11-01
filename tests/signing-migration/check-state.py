#!/usr/bin/env python3
"""Compare lab application state across a reboot or signing change."""
import argparse
import json
from pathlib import Path
import re

PACKAGES = ('org.nns.signing.system', 'org.nns.signing.application')
PRESERVED_FIELDS = ('uid', 'credential_encrypted_sha256', 'device_encrypted_sha256',
                    'key_security_level', 'key_user_authentication_required', 'permission')


def validate_preservation(before, after, system_certificate):
    if not re.fullmatch('[0-9a-f]{64}', system_certificate):
        raise ValueError('Expected a SHA-256 system certificate fingerprint')
    if set(before) != set(PACKAGES) or set(after) != set(PACKAGES):
        raise ValueError('Both lab packages are required, without additional packages')
    for package in PACKAGES:
        previous, current = before[package], after[package]
        for report in (previous, current):
            if report.get('passed') is not True or report.get('package') != package:
                raise ValueError(f'Fixture did not validate its own state: {package}')
            if report.get('permission_granted') is not True:
                raise ValueError(f'Required permission is not granted: {package}')
            if report.get('key_user_authentication_required') is not False:
                raise ValueError('This lab does not model authentication-bound keys')
            for field in ('credential_encrypted_sha256', 'device_encrypted_sha256', 'certificate_sha256'):
                if not re.fullmatch('[0-9a-f]{64}', report.get(field, '')):
                    raise ValueError(f'Missing or invalid {field}: {package}')
        if current.get('phase') != 'verify':
            raise ValueError(f'Post-transition state must use verify, never seed: {package}')
        for field in PRESERVED_FIELDS:
            if field not in previous or previous[field] != current.get(field):
                raise ValueError(f'Changed or missing {field}: {package}')
        if package.endswith('.system'):
            if current['uid'] != 1000 or current['certificate_sha256'] != system_certificate:
                raise ValueError('System shared UID or expected platform certificate differs')
        elif current['uid'] < 10000 or current['certificate_sha256'] != previous['certificate_sha256']:
            raise ValueError('Ordinary application UID or signing certificate differs')
    return {'state': 'preserved', 'packages': list(PACKAGES),
            'authentication_bound_keys_tested': False, 'physical_device_validated': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--system-certificate', required=True)
    arguments = parser.parse_args()
    print(json.dumps(validate_preservation(json.loads(arguments.before.read_text()),
        json.loads(arguments.after.read_text()), arguments.system_certificate), indent=2))
