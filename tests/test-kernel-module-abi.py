"""Check module CRC rejection without loading or executing kernel modules."""
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
from unittest.mock import patch

script = Path(__file__).resolve().parents[1] / 'kernel/check-module-abi.py'
with tempfile.TemporaryDirectory(prefix='nns-module-abi-') as temporary:
    root = Path(temporary)
    modules = root / 'modules'
    modules.mkdir()
    (modules / 'driver.ko').touch()
    symbols = root / 'vmlinux.symvers'
    symbols.write_text('0x12345678 core_symbol vmlinux EXPORT_SYMBOL\n')
    for name, required, exported, passed in [
        ('matching', '0x12345678 core_symbol\n0x11111111 module_symbol\n', '0x11111111 module_symbol\n', True),
        ('no-exports', '0x12345678 core_symbol\n', subprocess.CalledProcessError(
            1, ['modprobe'], output='', stderr='modprobe: No data available\n'), True),
        ('wrong-crc', '0x87654321 core_symbol\n', '', False),
        ('missing-symbol', '0x12345678 absent_symbol\n', '', False),
        ('duplicate-export', '0x12345678 core_symbol\n', '0x12345678 core_symbol\n', False),
    ]:
        output = root / (name + '.json')
        arguments = [str(script), str(symbols), str(modules), '--modprobe', 'modprobe', '--output', str(output)]
        with patch.object(sys, 'argv', arguments), patch('subprocess.check_output', side_effect=[required, exported]):
            try:
                runpy.run_path(str(script), run_name='__main__')
            except SystemExit:
                assert not passed, name
        report = json.loads(output.read_text())
        assert (report['state'] == 'passed') == passed, name
print('PASS: matching CRCs accepted; mismatches, absent symbols and duplicate kernel exports rejected')
