#!/usr/bin/env python3
"""Check the lab-only init override before compiling it."""
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
expected = {
    'service.adb.root': '0',
    'ro.adb.secure': '1',
    'ro.debuggable': '1',
    'ro.force.debuggable': '0',
}
debug = source.split('void LoadDebugProperties() {', 1)[1].split('\nvoid LoadReleaseBuildProperties()', 1)[0]
entries = re.findall(r'\{"([^"]+)", "([^"]+)"\}', debug)
if len(entries) != len(expected) or dict(entries) != expected or 'persist.sys.evox_debug_enabled' in debug:
    raise SystemExit('Lab init must require authentication and an explicit root request')
safety = source.split('static void SetSafetyNetProps() {', 1)[1].split('\nvoid LoadVbMetaOverrides()', 1)[0]
properties = dict(re.findall(r'\{"([^"]+)", "([^"]+)"\}', safety))
if any(properties.get(name) != value for name, value in expected.items() if name != 'service.adb.root'):
    raise SystemExit('Boot property overrides must preserve the lab authentication policy')
print('PASS: lab init permits an explicit root request while requiring ADB authentication and disabling force-debug')
