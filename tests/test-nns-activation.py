import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'nix/nns-system/activate.sh'
REQUIRED_TOOLS = ('nix', 'nix-env', 'sleep', 'runsvdir', 'sv', 'flock', 'install', 'mv', 'mkdir', 'id',
                  'cp', 'chmod', 'chown', 'stat', 'readlink', 'ln', 'rm', 'find', 'grep',
                  'cut', 'cat', 'nohup', 'mktemp')


class ActivationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nns-activation-')
        self.base = Path(self.tmp.name)
        self.gen = self.base / 'generation'
        self.bin = self.gen / 'system-profile/bin'
        self.bin.mkdir(parents=True)
        self.log = self.base / 'nix-env.log'
        for tool in REQUIRED_TOOLS:
            path = self.bin / tool
            if tool == 'nix-env':
                path.write_text('''#!/bin/sh
[ "$NIX_REMOTE" = local ] || exit 3
[ "$NIX_CONF_DIR" = "$NNS_NIX_CONF_DIRECTORY" ] || exit 3
printf "%s\\n" "$*" >> "$NNS_TEST_LOG"
while [ "$1" != --profile ]; do shift; done
profile=$2; shift 2
[ "$1" = --set ] || exit 2
ln -sfn "$2" "$profile"
''')
                path.chmod(0o755)
            elif tool in ('runsvdir', 'sv', 'nix'):
                path.write_text('#!/bin/sh\nexit 0\n')
                path.chmod(0o755)
            else:
                actual = shutil.which(tool)
                if actual:
                    path.symlink_to(actual)
        etc = self.gen / 'etc'
        (etc / 'nix').mkdir(parents=True)
        root_home = self.base / 'root-home'
        root_home.mkdir()
        (etc / 'passwd').write_text(f'root:x:0:0:root:{root_home}:/bin/sh\n')
        (etc / 'group').write_text('root:x:0:\n')
        (etc / 'nix/nix.conf').write_text('sandbox = false\n')
        (etc / 'ssl/certs').mkdir(parents=True)
        (etc / 'ssl/certs/ca-bundle.crt').write_text('test-ca\n')
        (self.gen / 'profiles/work/bin').mkdir(parents=True)
        (self.gen / 'services/example').mkdir(parents=True)
        run = self.gen / 'services/example/run'
        run.write_text('#!/bin/sh\nexit 0\n')
        run.chmod(0o755)
        (self.gen / 'authorized_keys').mkdir()
        (self.gen / 'authorized_keys/alice').write_text('ssh-ed25519 AAAA test\n')
        for path in ('state', 'etc-root', 'profiles', 'nix-conf'):
            (self.base / path).mkdir()
        launcher = self.base / 'launcher'
        launcher.write_text('#!/bin/sh\nshift 2\nexec "$@"\n')
        launcher.chmod(0o755)
        self.env = dict(os.environ,
            NNS_STATE_DIRECTORY=str(self.base / 'state/nns'),
            NNS_ETC_DIRECTORY=str(self.base / 'etc-root'),
            NNS_PROFILE_DIRECTORY=str(self.base / 'profiles'),
            NNS_NIX_CONF_DIRECTORY=str(self.base / 'nix-conf'),
            NNS_LAUNCHER=str(launcher),
            NNS_TEST_LOG=str(self.log))

    def tearDown(self):
        self.tmp.cleanup()

    def run_activation(self, generation=None):
        command = ['bash', str(SCRIPT), str(generation or self.gen), 'switch']
        if os.getuid() != 0:
            command = ['unshare', '--user', '--map-root-user', '--mount', '--fork', *command]
        return subprocess.run(command, env=self.env, text=True, capture_output=True)

    def test_activation_repeat_and_managed_state(self):
        inode = (self.base / 'etc-root').stat().st_ino
        for _ in range(2):
            result = self.run_activation()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.base / 'etc-root').stat().st_ino, inode)
        # Infrastructure alias and the ordinary work profile, once per activation.
        self.assertEqual(len(self.log.read_text().splitlines()), 4)
        self.assertEqual((self.base / 'profiles/system-profile').resolve(),
                         (self.gen / 'system-profile').resolve())
        self.assertEqual((self.base / 'profiles/work').resolve(), (self.gen / 'profiles/work').resolve())
        self.assertEqual((self.base / 'etc-root/nix/nix.conf').read_text(), 'sandbox = false\n')
        self.assertEqual((self.base / 'nix-conf/nix.conf').read_text(),
                         (self.base / 'etc-root/nix/nix.conf').read_text())
        for directory in ('nix', 'ssl', 'ssl/certs'):
            self.assertEqual((self.base / 'etc-root' / directory).stat().st_mode & 0o777, 0o755)
        key = self.base / 'state/nns/authorized_keys/alice'
        self.assertEqual(key.read_text(), 'ssh-ed25519 AAAA test\n')
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(key.stat().st_uid, os.getuid())  # UID 0 inside the mapped namespace.
        self.assertEqual((self.base / 'state/nns/services/example/run').resolve(),
                         (self.gen / 'services/example/run').resolve())

    def test_preflight_rejects_invalid_inputs_without_profile_publication(self):
        before = sorted(str(p.relative_to(self.base)) for p in self.base.rglob('*'))
        result = self.run_activation(self.base / 'missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sorted(str(p.relative_to(self.base)) for p in self.base.rglob('*')), before)
        bad = self.gen / 'profiles/bad.name'
        bad.mkdir()
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / 'profiles/system-profile').exists())
        bad.rmdir()
        invalid_service = self.gen / 'services/bad.name'
        invalid_service.mkdir()
        (invalid_service / 'run').write_text('#!/bin/sh\n')
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / 'profiles/system-profile').exists())

    def test_admin_symlink_and_writable_parent_rejected(self):
        admin = self.base / 'etc-root'
        admin.rmdir()
        admin.symlink_to(self.base / 'state')
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.log.read_text().splitlines()) if self.log.exists() else 0, 0)
        admin.unlink()
        admin.mkdir()
        admin.chmod(0o777)
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.log.read_text().splitlines()) if self.log.exists() else 0, 0)

    def test_stale_authorized_keys_are_removed(self):
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        key = self.gen / 'authorized_keys/alice'
        key.unlink()
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / 'state/nns/authorized_keys/alice').exists())
        shutil.rmtree(self.gen / 'services/example')
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / 'state/nns/services/example').exists())

    def test_stopped_supervisor_state_does_not_block_activation(self):
        services = self.base / 'state/nns/services'
        for name in ('stale', 'example'):
            control = services / name / 'supervise/control'
            control.parent.mkdir(parents=True)
            os.mkfifo(control)
        (services / 'example/run').symlink_to(self.base / 'previous-run')
        (self.bin / 'sv').write_text('#!/bin/sh\nexit 1\n')
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((services / 'stale').exists())
        self.assertEqual((services / 'example/run').resolve(),
                         (self.gen / 'services/example/run').resolve())

    def test_oneshots_reapply_without_waiting_for_a_running_process(self):
        job = self.gen / 'services/prepare'
        job.mkdir()
        (job / 'oneshot').touch()
        for name in ('run', 'finish'):
            script = job / name
            script.write_text('#!/bin/sh\nexit 0\n')
            script.chmod(0o755)
        log = self.base / 'sv.log'
        (self.bin / 'sv').write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{log}"\n')
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        service = self.base / 'state/nns/services/prepare'
        self.assertTrue((service / 'down').exists())
        self.assertEqual((service / 'finish').resolve(), (job / 'finish').resolve())
        (service / 'completed').touch()
        control = service / 'supervise/control'
        control.parent.mkdir()
        os.mkfifo(control)
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((service / 'completed').exists())
        commands = log.read_text()
        self.assertIn(f'-w 10 down {service}', commands)
        self.assertEqual(commands.count(f'up {service}'), 2)
        self.assertNotIn(f'restart {service}', commands)
        (job / 'oneshot').unlink()
        (job / 'finish').unlink()
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((service / 'oneshot').exists())
        self.assertFalse((service / 'finish').exists())
        self.assertFalse((service / 'down').exists())
        self.assertIn(f'-w 10 restart {service}', log.read_text())

    def test_nonroot_rejected(self):
        if os.getuid() == 0:
            self.skipTest('test requires a non-root host caller')
        result = subprocess.run(['bash', str(SCRIPT), str(self.gen), 'switch'],
                                env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires root', result.stderr)

    def test_rootless_user_namespace_activation(self):
        if os.getuid() == 0 or not shutil.which('unshare'):
            self.skipTest('rootless user namespaces unavailable')
        result = subprocess.run(['unshare', '--user', '--map-root-user', '--mount', '--fork',
                                 'bash', str(SCRIPT), str(self.gen), 'switch'],
                                env=self.env, text=True, capture_output=True)
        if result.returncode and ('Operation not permitted' in result.stderr or 'unshare failed' in result.stderr):
            self.skipTest('user namespaces unavailable')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
