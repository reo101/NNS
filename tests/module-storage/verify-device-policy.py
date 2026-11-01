#!/usr/bin/env python3
"""Verify a storage-only KernelSU policy extension from saved policy snapshots."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import setools

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--policy', type=Path, required=True)
parser.add_argument('--types-policy', type=Path)
parser.add_argument('--access', type=Path, default=Path(__file__).with_name('device-access.rule'))
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--allow-existing-ksu-filesystem-rule', action='store_true')
args = parser.parse_args()
if args.output.exists():
    parser.error('Refusing to replace a policy observation')

expected_types = {
    'nns_storage': {'domain', 'coredomain'},
    'nns_storage_exec': {'file_type', 'exec_type', 'system_file_type'},
    **{name: {'file_type', 'data_file_type', 'core_data_file_type'} for name in (
        'nns_storage_file', 'nns_storage_config_file', 'nns_storage_image_file', 'nns_storage_log_file')},
}
before = setools.SELinuxPolicy(str(args.baseline))
after = setools.SELinuxPolicy(str(args.policy))
old_types = {str(t): t for t in before.types()}
new_types = {str(t): t for t in after.types()}
assert not set(expected_types) & old_types.keys(), 'Storage types already existed in the baseline'
assert new_types.keys() - old_types.keys() == expected_types.keys(), 'Unexpected type additions'
assert old_types.keys() <= new_types.keys(), 'An existing type disappeared'
for name, original in old_types.items():
    current = new_types[name]
    assert {str(a) for a in original.attributes()} == {str(a) for a in current.attributes()}, name
    assert original.ispermissive == current.ispermissive, name
for name, attributes in expected_types.items():
    assert {str(a) for a in new_types[name].attributes()} == attributes, name
    assert not new_types[name].ispermissive, name

membership = {}
source_rules = {}


def members(policy, symbol):
    key = (id(policy), str(symbol))
    if key not in membership:
        membership[key] = {str(t) for t in symbol.expand()}
    return membership[key]


def nonempty_rules(policy):
    # Compilers discard rules over empty attributes; they grant no access.
    return {str(r) for r in policy.terules()
            if members(policy, r.source) and members(policy, r.target)}


old_rules = nonempty_rules(before)
new_rules = nonempty_rules(after)
assert old_rules <= new_rules, 'An existing TE rule was changed or removed'
for rule in new_rules - old_rules:
    assert set(re.findall(r'[A-Za-z_][A-Za-z_0-9]*', rule)) & expected_types.keys(), rule


def rules(policy, source, target=None, tclass=None, kind='allow'):
    key = (id(policy), source, kind)
    if key not in source_rules:
        source_rules[key] = [r for r in policy.terules()
                             if str(r.ruletype) == kind and source in members(policy, r.source)]
    return [r for r in source_rules[key]
            if (target is None or target in members(policy, r.target))
            and (tclass is None or str(r.tclass) == tclass)]


def permissions(policy, source, target, tclass, kind='allow'):
    return set().union(*(set(r.perms) for r in rules(policy, source, target, tclass, kind)))


observed = []
inherited_exceptions = []
if args.types_policy:
    inherited = setools.SELinuxPolicy(str(args.types_policy))
    expected = {}
    transitions = set()
    for line in args.access.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        words = line.replace('{', '').replace('}', '').split()
        if words[0] == 'type_transition':
            assert len(words) == 5 and words[3] == 'process', line
            transitions.add(tuple(words[1:]))
            matches = rules(after, words[1], words[2], 'process', 'type_transition')
            assert any(str(r.default) == words[4] for r in matches), line
            continue
        assert words[0] in ('allow', 'allowxperm'), line
        kind, source, target, tclass, *values = words
        if kind == 'allowxperm':
            assert values.pop(0) == 'ioctl'
            values = [int(v, 16) for v in values]
        expected.setdefault((kind, source, target, tclass), set()).update(values)
    inherited_rules = nonempty_rules(inherited)
    for rule in after.terules():
        if str(rule) not in new_rules or str(rule) in inherited_rules:
            continue
        key = (str(rule.ruletype), str(rule.source), str(rule.target), str(rule.tclass))
        if key[0] in ('allow', 'allowxperm'):
            assert key in expected, str(rule)
        else:
            assert key[0] == 'type_transition' and (*key[1:], str(rule.default)) in transitions, str(rule)
    for (kind, source, target, tclass), requested in expected.items():
        original = permissions(inherited, source, target, tclass, kind)
        current = permissions(after, source, target, tclass, kind)
        assert current == original | requested, (kind, source, target, tclass, requested, current)
        observed.append({'kind': kind, 'source': source, 'target': target,
                         'class': tclass, 'permissions': sorted(current)})

    assert permissions(after, 'nns_storage', 'nns_storage', 'capability') == {'sys_admin'}
    for capability_class in ('capability2', 'cap_userns', 'cap2_userns'):
        assert not rules(after, 'nns_storage', target='nns_storage', tclass=capability_class), capability_class
    mounted_types = set()
    for rule in rules(after, 'nns_storage', tclass='filesystem'):
        if args.allow_existing_ksu_filesystem_rule and str(rule.target) == 'ksu_file':
            assert str(rule) in old_rules, 'The KernelSU exception is new or changed'
            inherited_exceptions.append(str(rule))
            continue
        assert not set(rule.perms) & {'remount', 'unmount', 'relabelfrom', 'relabelto', 'pivot_root'}, str(rule)
        if 'mount' in rule.perms:
            mounted_types.update(str(t) for t in rule.target.expand())
    assert mounted_types == {'labeledfs'}, mounted_types
    forbidden = {
        ('nns_storage_file', 'dir'): {0x6613, 0x6617, 0x6618, 0x6619},
        ('system_data_file', 'dir'): {0x6613, 0x6617, 0x6618, 0x6619, 0x661a, 0x9403, 0x940e, 0x940f},
        ('loop_device', 'blk_file'): {0x4c00, 0x4c01, 0x4c02, 0x4c04, 0x4c06, 0x4c07},
    }
    for (target, tclass), requests in forbidden.items():
        granted = permissions(after, 'nns_storage', target, tclass, 'allowxperm')
        assert not granted & requests, (target, granted & requests)

record = {
    'state': 'storage_access_verified' if args.types_policy else 'storage_types_verified',
    'baseline_sha256': hashlib.sha256(args.baseline.read_bytes()).hexdigest(),
    'policy_sha256': hashlib.sha256(args.policy.read_bytes()).hexdigest(),
    'added_types': sorted(expected_types),
    'old_type_attributes_and_permissiveness_unchanged': True,
    'existing_te_rules_unchanged': True,
    'added_rules': sorted(new_rules - old_rules),
    'effective_requested_permissions': observed,
    'accepted_unchanged_kernel_su_filesystem_rules': inherited_exceptions,
}
args.output.write_text(json.dumps(record, indent=2) + '\n')
print('PASS: storage-only policy additions and effective permissions verified')
