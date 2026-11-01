#!/usr/bin/env python3
"""Check source guards and refusal to overwrite private policy overlays."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests/rom-storage'))
import platform_policy

specifications = json.loads(platform_policy.MANIFEST_PATH.read_text())
assert set(specifications) == {'system/sepolicy/private/domain.te', 'system/sepolicy/private/vold.te'}
with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    source, overlay = directory / 'source', directory / 'overlay'
    overlay.mkdir()
    for relative, specification in specifications.items():
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        contents = '\n'.join(previous for previous, _ in specification['replacements']) + '\n'
        path.write_text(contents)
        specification['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = directory / 'manifest.json'
    manifest.write_text(json.dumps(specifications))
    with patch.object(platform_policy, 'MANIFEST_PATH', manifest):
        record = platform_policy.prepare_overlay(source, overlay)
        assert len(record['overlay_inputs']) == 2
        for relative, specification in specifications.items():
            text = (overlay / ('platform-' + Path(relative).name)).read_text()
            for _, replacement in specification['replacements']:
                assert replacement in text
            assert hashlib.sha256((source / relative).read_bytes()).hexdigest() == specification['sha256']
        try:
            platform_policy.prepare_overlay(source, overlay)
        except RuntimeError as error:
            assert 'existing policy overlay' in str(error)
        else:
            raise AssertionError('Existing overlay was overwritten')
        other_overlay = directory / 'other-overlay'
        other_overlay.mkdir()
        path = source / 'system/sepolicy/private/vold.te'
        original = path.read_text()
        path.write_text(original + '\n# changed source\n')
        try:
            platform_policy.prepare_overlay(source, other_overlay)
        except RuntimeError as error:
            assert 'Unreviewed platform policy baseline' in str(error)
        else:
            raise AssertionError('Changed source passed its hash guard')
        assert not list(other_overlay.iterdir())
        path.write_text(original + original)
        specifications['system/sepolicy/private/vold.te']['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(specifications))
        try:
            platform_policy.prepare_overlay(source, other_overlay)
        except RuntimeError as error:
            assert 'Missing or ambiguous platform policy block' in str(error)
        else:
            raise AssertionError('Ambiguous source block was amended')
        assert not list(other_overlay.iterdir())
print('PASS: platform amendments check source hashes, block uniqueness and overlay ownership')
