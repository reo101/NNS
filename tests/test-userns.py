"""Run outside the Nix build sandbox: test real, unprivileged Linux namespaces."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

HELPER = str(Path(sys.argv.pop(1)).resolve())


class NamespaceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nns-test-')
        self.base = Path(self.temp.name)
        self.store = self.base / 'backing'
        self.store.mkdir()
        # Let the host's Nix-linked test interpreter run through the new /nix.
        (self.store / 'store').symlink_to('/.nns-host/nix/store')
        (self.store / 'marker').write_text('canonical-store')
        self.cwd = self.base / 'cwd'
        self.cwd.mkdir()
        self.mounts = Path('/proc/self/mountinfo').read_text()
        self.userns = os.readlink('/proc/self/ns/user')

    def tearDown(self):
        self.assertEqual(list(self.base.glob('nns.*')), [], 'scratch directory leaked')
        self.assertEqual(Path('/proc/self/mountinfo').read_text(), self.mounts,
                         'parent mount namespace changed')
        self.temp.cleanup()

    def run_code(self, code, *args, explicit=True, store=None):
        result = subprocess.run([
            HELPER, *(['--userns'] if explicit else []),
            '--store', str(store or self.store), '--tmpdir', str(self.base),
            '--', sys.executable, '-c', code, *args,
        ], cwd=self.cwd, text=True, capture_output=True, timeout=20)
        return result

    def test_identity_cwd_canonical_path_and_caps(self):
        r = self.run_code('''
import json, os
from pathlib import Path
s = dict(line.split(':', 1) for line in Path('/proc/self/status').read_text().splitlines())
print(json.dumps([os.getuid(), os.getgid(), os.getcwd(),
  Path('/nix/marker').read_text(), os.readlink('/proc/self/ns/user'),
  s['NoNewPrivs'].strip(), s['CapEff'].strip()]))
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        uid, gid, cwd, marker, namespace, nnp, caps = json.loads(r.stdout)
        self.assertEqual((uid, gid), (os.getuid(), os.getgid()))
        self.assertTrue(os.path.samefile(cwd, self.cwd))
        self.assertEqual(marker, 'canonical-store')
        self.assertNotEqual(namespace, self.userns)
        self.assertEqual(nnp, '1')
        if os.getuid() != 0:
            self.assertEqual(int(caps, 16), 0)

    @unittest.skipIf(os.getuid() == 0, 'automatic userns applies to non-root callers')
    def test_non_root_automatically_uses_userns(self):
        r = self.run_code('import os; print(os.readlink("/proc/self/ns/user"))', explicit=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotEqual(r.stdout.strip(), self.userns)

    def test_arguments_and_exit_status(self):
        r = self.run_code('import sys; print(sys.argv[1:]); sys.exit(37)', 'has spaces', '')
        self.assertEqual(r.returncode, 37, r.stderr)
        self.assertEqual(r.stdout.strip(), "['has spaces', '']")
        r = self.run_code('import os,signal; os.kill(os.getpid(), signal.SIGTERM)')
        self.assertEqual(r.returncode, 128 + signal.SIGTERM, r.stderr)

    def test_setup_failure_is_clean(self):
        r = self.run_code('raise Exception("must not execute")', store=self.base / 'absent')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('mount', r.stderr)
        self.assertNotIn('must not execute', r.stderr)

    def test_userns_does_not_grant_parent_filesystem_privileges(self):
        secret = self.base / 'unreadable'
        secret.write_text('private')
        secret.chmod(0)
        try:
            r = self.run_code('''
import sys
try:
    open(sys.argv[1]).read()
except PermissionError:
    sys.exit(0)
sys.exit(99)
''', str(secret))
            self.assertEqual(r.returncode, 0, r.stderr)
        finally:
            secret.chmod(0o600)


unittest.main()
