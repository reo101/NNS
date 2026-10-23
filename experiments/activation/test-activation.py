"""Run the production activation contract against all three implementations.

No device access. Each activation gets UID 0 in an unprivileged user namespace.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('activation_contract', ROOT / 'tests/test-nns-activation.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
LANGUAGES = {
    'shell': [shutil.which('bash'), str(ROOT / 'nix/nns-system/activate.sh')],
    'nushell': [shutil.which('nu'), '--no-config-file', str(Path(__file__).with_name('activate.nu'))],
    'babashka': [shutil.which('bb'), str(Path(__file__).with_name('activate.clj'))],
}


class ActivationContract(contract.ActivationTest):
    implementation = None

    def setUp(self):
        super().setUp()
        for tool in ('sh', 'kill'):
            if not (self.bin / tool).exists():
                (self.bin / tool).symlink_to(shutil.which(tool))

    def command(self, generation=None, mode='switch', root=True):
        command = [*LANGUAGES[self.implementation], str(generation or self.gen), mode]
        if root and os.getuid() != 0:
            command = [shutil.which('unshare'), '--user', '--map-root-user', '--mount', '--fork', *command]
        return command

    def run_activation(self, generation=None, mode='switch'):
        return subprocess.run(self.command(generation, mode), env=self.env, text=True,
                              capture_output=True, timeout=20)

    def test_nonroot_rejected(self):
        if os.getuid() == 0:
            self.skipTest('test requires a non-root host caller')
        result = subprocess.run(self.command(root=False), env=self.env, text=True,
                                capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires root', result.stderr)

    def test_rootless_user_namespace_activation(self):
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_boot_mode(self):
        result = self.run_activation(mode='boot')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_mode(self):
        result = self.run_activation(mode='invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_lock_symlink_rejected_without_writing_target(self):
        victim = self.base / 'victim'
        victim.write_text('preserve\n')
        (self.base / 'state/nns.lock').symlink_to(victim)
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_text(), 'preserve\n')
        self.assertFalse(self.log.exists())

    def test_oneshot_requires_finish(self):
        (self.gen / 'services/example/oneshot').touch()
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_broken_generation_link_rejected(self):
        (self.gen / 'profiles/broken').symlink_to(self.base / 'absent')
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_file_discovery_failure_is_observed(self):
        find = self.bin / 'find'
        find.unlink()
        find.write_text('#!/bin/sh\nprintf "intentional discovery failure\\n" >&2\nexit 43\n')
        find.chmod(0o755)
        result = self.run_activation()
        if self.implementation == 'shell':
            # Deliberately document the baseline's pipeline error suppression.
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(self.log.exists())
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.log.exists())

    def test_profile_failure_stops_later_publication(self):
        (self.bin / 'nix-env').write_text('#!/bin/sh\nprintf "intentional failure\\n" >&2\nexit 23\n')
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / 'state/nns/authorized_keys/alice').exists())
        self.assertFalse((self.base / 'state/nns/services/example/run').exists())

    def test_failed_sshd_preflight_prevents_publication(self):
        (self.gen / 'sshd-enabled').touch()
        (self.gen / 'sshd_config').write_text('Port 22\n')
        checker = self.gen / 'check-sshd'
        checker.write_text('#!/bin/sh\nprintf "intentional SSH failure\\n" >&2\nexit 29\n')
        checker.chmod(0o755)
        generator = self.bin / 'ssh-keygen'
        generator.write_text('#!/bin/sh\nexit 0\n')
        generator.chmod(0o755)
        state = self.base / 'state/nns'
        state.mkdir()
        (state / 'ssh_host_ed25519_key').write_text('fixture host key\n')
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('intentional SSH', result.stderr)
        self.assertFalse(self.log.exists())
        self.assertFalse((self.base / 'etc-root/passwd').exists())

    def test_valid_sshd_configuration_and_persistent_host_key(self):
        (self.gen / 'sshd-enabled').touch()
        configuration = self.gen / 'sshd_config'
        configuration.write_text('Port 22\n')
        checker = self.gen / 'check-sshd'
        checker.write_text('#!/bin/sh\ntest -f "$1/passwd" && test -f "$2"\n')
        checker.chmod(0o755)
        generator = self.bin / 'ssh-keygen'
        generator.write_text('#!/bin/sh\nfor argument do target=$argument; done\nprintf "host-key\\n" > "$target"\n')
        generator.chmod(0o755)
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        key = self.base / 'state/nns/ssh_host_ed25519_key'
        inode = key.stat().st_ino
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        configuration.write_text('Port 8022\n')
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(key.stat().st_ino, inode)
        published = self.base / 'state/nns/sshd_config'
        self.assertEqual(published.read_text(), 'Port 8022\n')
        self.assertEqual(published.stat().st_mode & 0o777, 0o600)

    def test_empty_managed_collections(self):
        shutil.rmtree(self.gen / 'services/example')
        shutil.rmtree(self.gen / 'profiles/work')
        (self.gen / 'authorized_keys/alice').unlink()
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_lock_reexecution_uses_absolute_interpreter(self):
        self.env['PATH'] = str(self.bin) + ':/system/bin:/system/xbin'
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_store_like_generation_links(self):
        for name in ('etc', 'system-profile'):
            source = self.base / (name + '-source')
            (self.gen / name).rename(source)
            (self.gen / name).symlink_to(source)
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'etc-root/nix/nix.conf').read_text(), 'sandbox = false\n')
        profile = self.base / 'profiles/system-profile'
        self.assertEqual(str(profile.readlink()), str((self.gen / 'system-profile').resolve()))
        self.assertIn('--set ' + str((self.gen / 'system-profile').resolve()), self.log.read_text())

    def test_service_run_and_finish_links_are_canonical(self):
        service = self.gen / 'services/example'
        run = self.base / 'store-run'
        (service / 'run').rename(run)
        (service / 'run').symlink_to(run)
        (service / 'oneshot').touch()
        finish = self.base / 'store-finish'
        finish.write_text('#!/bin/sh\nexit 0\n')
        finish.chmod(0o755)
        (service / 'finish').symlink_to(finish)
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        published = self.base / 'state/nns/services/example'
        self.assertEqual(str((published / 'run').readlink()), str(run.resolve()))
        self.assertEqual(str((published / 'finish').readlink()), str(finish.resolve()))

    def test_symlink_launcher_rejected(self):
        directory = self.base / 'writable'
        directory.mkdir(mode=0o777)
        directory.chmod(0o777)
        launcher = Path(self.env['NNS_LAUNCHER'])
        target = directory / 'launcher'
        launcher.rename(target)
        launcher.symlink_to(target)
        result = self.run_activation()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_invalid_supervisor_pids(self):
        state = self.base / 'state/nns'
        state.mkdir()
        pidfile = state / 'supervisor.pid'
        for value in ('0', '000', '', 'invalid', '999999999999999999999999999999999'):
            pidfile.write_text(value + '\n')
            result = self.run_activation()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual(pidfile.read_text().strip(), value)

    def test_regular_control_file_is_not_a_supervisor(self):
        service = self.base / 'state/nns/services/example'
        (service / 'supervise').mkdir(parents=True)
        control = service / 'supervise/control'
        control.write_text('preserve\n')
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(control.read_text(), 'preserve\n')

    def test_nested_configuration_and_symlink_sources(self):
        source = self.base / 'configuration-source'
        source.write_text('source contents\n')
        (self.gen / 'etc/ssl/certs/linked.pem').symlink_to(source)
        (self.base / 'etc-root/unmanaged').write_text('retain\n')
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.base / 'etc-root/ssl/certs/linked.pem'
        self.assertFalse(destination.is_symlink())
        self.assertEqual(destination.read_text(), source.read_text())
        self.assertEqual((self.base / 'etc-root/unmanaged').read_text(), 'retain\n')

    def test_concurrent_activations_are_serialized(self):
        writer = self.bin / 'nix-env'
        original = writer.read_text()
        writer.write_text(original.replace('printf "%s\\n" "$*" >> "$NNS_TEST_LOG"', '''
case "$2" in
    */system-profile)
        printf 'begin\\n' >> "$NNS_TEST_LOG"
        sleep 0.25
        printf 'end\\n' >> "$NNS_TEST_LOG" ;;
esac
'''))
        with subprocess.Popen(self.command(), env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as first:
            with subprocess.Popen(self.command(), env=self.env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as second:
                first_output = first.communicate(timeout=20)
                second_output = second.communicate(timeout=20)
        self.assertEqual(first.returncode, 0, first_output)
        self.assertEqual(second.returncode, 0, second_output)
        self.assertEqual(self.log.read_text().splitlines(), ['begin', 'end', 'begin', 'end'])

    def test_detached_supervisor_does_not_retain_activation_lock(self):
        (self.bin / 'runsvdir').write_text('#!/bin/sh\nexec sleep 20\n')
        pidfile = self.base / 'state/nns/supervisor.pid'
        try:
            result = self.run_activation()
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(['flock', '--nonblock', str(self.base / 'state/nns.lock'),
                                     'true'], capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            if pidfile.exists():
                try:
                    os.kill(int(pidfile.read_text()), 15)
                except ProcessLookupError:
                    pass

    def test_daemon_probe_uses_daemon_remote(self):
        daemon = self.gen / 'services/nix-daemon'
        daemon.mkdir()
        (daemon / 'run').symlink_to(self.gen / 'services/example/run')
        log = self.base / 'ping.log'
        (self.bin / 'nix').write_text(f'''#!/bin/sh
[ "$NIX_REMOTE" = daemon ] || exit 8
printf '%s\\n' "$*" >> "{log}"
''')
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('store ping --store daemon', log.read_text())


def main():
    languages = sys.argv[1:] or list(LANGUAGES)
    suite = unittest.TestSuite()
    for language in languages:
        if language not in LANGUAGES or LANGUAGES[language][0] is None:
            raise SystemExit(f'unavailable activation language: {language}')
        test_class = type(f'{language.title()}Activation', (ActivationContract,), {'implementation': language})
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(test_class))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())


if __name__ == '__main__':
    main()
