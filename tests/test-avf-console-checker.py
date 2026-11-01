"""Check both systemd boot-completion reports and reject partial startup."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CHECKER = Path(__file__).with_name('test-avf-console.py')
PROOFS = '\n'.join([
    'VM started; external read-only filesystem backend=',
    'nns-guest: absolute store symlink',
    'nns-guest: relative store symlink',
    'nns-guest: STORE SYMLINK READS SUCCEEDED',
    'nns-guest: GUEST STORE READY',
    'nns-guest: PACKAGE REALISATION AND EXECUTION SUCCEEDED',
    'nns-guest: GUEST BUILD AND PHONE PUBLICATION SUCCEEDED',
    'nns-guest: GUEST DNS AND HTTPS SUCCEEDED',
])
TARGET = 'Queued start job for default target Multi-User System.'
COMPLETE = 'Startup finished in 1s (kernel) + 2s (userspace) = 3s.'


class ConsoleCheckerTest(unittest.TestCase):
    def test_boot_completion(self):
        for evidence, success in [
            ('Reached target Multi-User System.', True),
            (TARGET + '\n' + COMPLETE, True),
            (TARGET, False),
            (COMPLETE, False),
            ('Queued start job for default target Initrd Default Target.\n' + COMPLETE, False),
        ]:
            with self.subTest(evidence=evidence), tempfile.TemporaryDirectory() as directory:
                console = Path(directory) / 'console.log'
                console.write_text(PROOFS + '\n' + evidence)
                result = subprocess.run([sys.executable, str(CHECKER), str(console)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)


if __name__ == '__main__':
    unittest.main()
