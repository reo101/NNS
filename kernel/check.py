"""Build-time checks for the pinned cheetah kernel profile."""
import gzip
import json
from pathlib import Path
import shlex
import sys

config_only = sys.argv[-1] == '--config-only'
out, manifest = map(Path, sys.argv[1:-1] if config_only else sys.argv[1:])
config = (out / '.config').read_text()
expected = json.loads(manifest.read_text())
for key in ('USER_NS', 'USB_CONFIGFS_F_HID', 'KSU', 'KSU_SUSFS',
            'KSU_SUSFS_SUS_MAP', 'CMDLINE_EXTEND'):
    assert f'CONFIG_{key}=y\n' in config, key
assert 'CONFIG_PANIC_TIMEOUT=-1\n' in config
assert '# CONFIG_TRIM_UNUSED_KSYMS is not set\n' in config
assert '# CONFIG_MODULE_SIG_PROTECT is not set\n' in config
assert '# CONFIG_MODULE_FORCE_LOAD is not set\n' in config
cmd = shlex.split(next(line.split('=', 1)[1] for line in config.splitlines()
                      if line.startswith('CONFIG_CMDLINE=')))[0]
props = dict(item.split('=', 1) for item in cmd.split())
for key in ('size', 'hash_alg', 'digest'):
    assert props[f'androidboot.vbmeta.{key}'] == str(expected[key]), key
if config_only:
    print('PASS: resolved kernel configuration and AVB profile')
    sys.exit(0)
image = (out / 'arch/arm64/boot/Image').read_bytes()
assert cmd.encode() + b'\0' in image
assert b'INIT-FATAL-CAPTURE' not in image
assert image[56:60] == b'ARM\x64'
start = image.index(b'IKCFG_ST') + len(b'IKCFG_ST')
end = image.index(b'IKCFG_ED', start)
assert gzip.decompress(image[start:end]).decode() == config, 'stale embedded kernel config'
assert (out / 'include/config/kernel.release').read_text().strip() == '6.1.162'
print('PASS: ARM64 Image, features, AVB profile, release, no reboot trap')
