#!/usr/bin/env python3
"""Compile the controller against an existing full ROM neverallow policy."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from platform_policy import MANIFEST_PATH, load_amendments

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--candidate', type=Path, required=True)
parser.add_argument('--fixture-policy', type=Path)
parser.add_argument('--tools', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
arguments = parser.parse_args()
arguments.output.mkdir(exist_ok=False)
marker = '#line 1 "external/nns-rom/sepolicy/nns_mount.te"'
baseline = arguments.baseline.read_text()
if baseline.count(marker) != 1:
    raise RuntimeError('The reviewed NNS ROM policy inclusion point is missing or ambiguous')


def expand(text):
    boundary = '__NNS_STORAGE_FRAGMENT_BEGIN__\n'
    result = subprocess.run([
        'm4', '-Dtarget_build_variant=userdebug', '-Dtarget_full_treble=true',
        '-Dtarget_compatible_property=true', '-Dtarget_enforce_sysprop_owner=true',
        str(arguments.source / 'system/sepolicy/public/global_macros'),
        str(arguments.source / 'system/sepolicy/public/te_macros'),
        str(arguments.source / 'system/sepolicy/public/ioctl_defines'), '-',
    ], input=boundary + text, check=True, capture_output=True, text=True).stdout
    return result.split(boundary, 1)[1]


amendments = load_amendments(arguments.source)
for relative, specification in amendments.items():
    for previous, replacement in specification['replacements']:
        previous, replacement = expand(previous), expand(replacement)
        if baseline.count(previous) != 1:
            raise RuntimeError('Missing or ambiguous expanded policy block: ' + relative)
        baseline = baseline.replace(previous, replacement)
expanded = expand((arguments.candidate / 'nns_storage.te').read_text())
if arguments.fixture_policy:
    expanded += '\n' + expand(arguments.fixture_policy.read_text())
fragment = arguments.output / 'candidate-expanded.conf'
fragment.write_text(expanded)
policy_source = arguments.output / 'candidate-full.conf'
policy_source.write_text(baseline.replace(marker, expanded + '\n' + marker))
policy = arguments.output / 'policy'
for command, name in (
    ([str(arguments.tools / 'checkpolicy'), '-M', '-c', '30', '-o', str(policy), str(policy_source)], 'compile'),
    ([str(arguments.tools / 'checkfc'), str(policy), str(arguments.candidate / 'file_contexts')], 'file-contexts'),
):
    result = subprocess.run(command, capture_output=True, text=True)
    (arguments.output / (name + '.log')).write_text(result.stdout + result.stderr)
    result.check_returncode()
permissive = subprocess.run([str(arguments.tools / 'sepolicy-analyze'), str(policy), 'permissive'],
                            check=True, capture_output=True, text=True).stdout.split()
if {'nns_storage', 'nns_storage_fixture', 'kernel'} & set(permissive):
    raise RuntimeError('The storage controller, fixture and kernel must remain enforcing')
# Each injected grant must fail an assertion, not merely a syntax/type check.
negative_rules = {
    'remount': 'allow nns_storage labeledfs:filesystem remount;',
    'unmount': 'allow nns_storage labeledfs:filesystem unmount;',
    'filesystem-relabel-from': 'allow nns_storage labeledfs:filesystem relabelfrom;',
    'filesystem-relabel-to': 'allow nns_storage labeledfs:filesystem relabelto;',
    'other-filesystem-mount': 'allow nns_storage tmpfs:filesystem mount;',
    'other-domain-mount': 'allow nns_mount labeledfs:filesystem mount;',
    'process-inspection-capability': 'allow nns_storage self:capability sys_ptrace;',
    'key-add': 'allowxperm nns_storage nns_storage_file:dir ioctl { 0x6617 };',
    'key-remove': 'allowxperm nns_storage nns_storage_file:dir ioctl { 0x6618 };',
    'key-remove-all-users': 'allowxperm nns_storage nns_storage_file:dir ioctl { 0x6619 };',
    'encryption-policy-set': 'allowxperm nns_storage nns_storage_file:dir ioctl { 0x6613 };',
    'other-directory-key-status': 'allowxperm nns_storage system_data_file:dir ioctl { 0x661a };',
    'other-domain-key-status': 'allow nns_mount nns_storage_file:dir ioctl;\n'
                               'allowxperm nns_mount nns_storage_file:dir ioctl { 0x661a };',
}
if arguments.fixture_policy:
    negative_rules['fixture-key-status'] = 'allowxperm nns_storage_fixture nns_storage_file:dir ioctl { 0x661a };'
negative_source = arguments.output / 'negative.conf'
for name, rule in negative_rules.items():
    negative_source.write_text(policy_source.read_text().replace(marker, rule + '\n' + marker))
    result = subprocess.run([
        str(arguments.tools / 'checkpolicy'), '-M', '-c', '30',
        '-o', str(arguments.output / 'negative-policy'), str(negative_source),
    ], capture_output=True, text=True)
    log = result.stdout + result.stderr
    (arguments.output / ('negative-' + name + '.log')).write_text(log)
    if result.returncode == 0 or 'neverallow' not in log or 'violated by' not in log:
        raise RuntimeError('Forbidden grant did not fail a neverallow assertion: ' + name)
negative_source.unlink()
record = {
    'state': 'candidate_compiled_against_amended_full_rom_policy',
    'amendments_sha256': hashlib.sha256(MANIFEST_PATH.read_bytes()).hexdigest(),
    'platform_source_inputs': {relative: specification['sha256']
                               for relative, specification in amendments.items()},
    'negative_grants_rejected': negative_rules,
    'baseline_sha256': hashlib.sha256(arguments.baseline.read_bytes()).hexdigest(),
    'candidate_sha256': hashlib.sha256((arguments.candidate / 'nns_storage.te').read_bytes()).hexdigest(),
    'fixture_sha256': hashlib.sha256(arguments.fixture_policy.read_bytes()).hexdigest() if arguments.fixture_policy else None,
    'compiled_sha256': hashlib.sha256(policy.read_bytes()).hexdigest(),
    'neverallows_enabled': True, 'permissive_types': permissive,
    'scope': 'Full baseline with explicit platform amendments and candidate fragment; not a rebuilt ROM image or property-context package check',
}
(arguments.output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
print(f'PASS: candidate controller, amended full ROM assertions, file contexts and {len(negative_rules)} forbidden grants')
