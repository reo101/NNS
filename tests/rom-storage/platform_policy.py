#!/usr/bin/env python3
"""Prepare hash-guarded platform-policy amendments without changing the source."""
import argparse
import hashlib
import json
from pathlib import Path

MANIFEST_PATH = Path(__file__).resolve().parents[2] / 'integrations/rom/storage/platform-policy.json'


def load_amendments(source):
    specifications = json.loads(MANIFEST_PATH.read_text())
    for relative, specification in specifications.items():
        contents = (source / relative).read_bytes()
        if hashlib.sha256(contents).hexdigest() != specification['sha256']:
            raise RuntimeError('Unreviewed platform policy baseline: ' + relative)
        specification['source_text'] = contents.decode()
    return specifications


def prepare_overlay(source, overlay):
    specifications = load_amendments(source)
    outputs = {}
    for relative, specification in specifications.items():
        text = specification['source_text']
        for previous, replacement in specification['replacements']:
            if text.count(previous) != 1:
                raise RuntimeError('Missing or ambiguous platform policy block: ' + relative)
            text = text.replace(previous, replacement)
        destination = overlay / ('platform-' + Path(relative).name)
        if destination.exists():
            raise RuntimeError('Refusing to replace an existing policy overlay: ' + str(destination))
        outputs[destination] = text
    for destination, text in outputs.items():
        with destination.open('x') as stream:
            stream.write(text)
    return {
        'manifest_sha256': hashlib.sha256(MANIFEST_PATH.read_bytes()).hexdigest(),
        'source_inputs': {relative: specification['sha256']
                          for relative, specification in specifications.items()},
        'overlay_inputs': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in outputs},
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--overlay', type=Path, required=True)
    parser.add_argument('--record', type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.record.exists():
        parser.error('Refusing to replace an existing policy preparation record')
    record = prepare_overlay(arguments.source, arguments.overlay)
    with arguments.record.open('x') as stream:
        json.dump(record, stream, indent=2)
        stream.write('\n')
    print('PASS: reviewed platform policy exported to a private overlay')
