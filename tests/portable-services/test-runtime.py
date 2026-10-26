"""Exercise identical portable declarations under real subordinate managers."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


class ManagerContract(unittest.TestCase):
    manager = None
    package = None

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='portable-service-test-')
        self.root = Path(self.directory.name)
        self.manifest = json.loads((self.package / 'manifest.json').read_text())
        self.configuration = Path(self.manifest['configurationDirectory'])
        self.environment = dict(os.environ, MANAGER_TEST_DIRECTORY=str(self.root),
                                PORTABLE_UNSET='must be removed')
        self.log = open(self.root / 'manager.log', 'w+')
        self.process = None
        self.pending = []
        self.addCleanup(self.cleanup)
        shutil.copytree(self.package / 'configuration', self.configuration)
        if self.manager == 's6-rc':
            self.scan = self.root / 'scan'
            self.scan.mkdir()
            self.live = self.root / 'live'
            self.process = subprocess.Popen(['s6-svscan', str(self.scan)], env=self.environment,
                                           stdout=self.log, stderr=self.log, start_new_session=True)
            self.wait_for(lambda: (self.scan / '.s6-svscan/control').is_fifo(), 's6-svscan startup')
            result = self.execute(['s6-rc-init', '-t', '5000', '-c', str(self.package / 'compiled'),
                                   '-l', str(self.live), str(self.scan)])
        else:
            self.socket = self.root / 'dinit.sock'
            # Keep the user manager alive without starting the aggregate fixture.
            control = self.root / 'control'
            control.mkdir()
            (control / 'boot').write_text('type = internal\n')
            self.process = subprocess.Popen(
                ['dinit', '--user', '-p', str(self.socket), '-d', str(control),
                 '-d', str(self.package / 'services'), 'boot'], env=self.environment,
                stdout=self.log, stderr=self.log, start_new_session=True)
            self.wait_for(self.socket.exists, 'Dinit startup')
            result = self.execute(['dinitctl', '-p', str(self.socket), 'status', 'boot'])
        self.assertEqual(result.returncode, 0, result.stdout + self.log_text())

    def log_text(self):
        self.log.flush()
        return Path(self.log.name).read_text()

    def wait_for(self, predicate, description, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.process is not None and self.process.poll() is not None:
                self.fail('manager exited during ' + description + '\n' + self.log_text())
            time.sleep(0.03)
        self.fail('timed out during ' + description + '\n' + self.log_text())

    def execute(self, command, timeout=12):
        return subprocess.run(command, env=self.environment, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, timeout=timeout)

    def command(self, action, name):
        native = self.manifest['services'][name]['nativeName']
        if self.manager == 's6-rc':
            return ['s6-rc', '-l', str(self.live), '-u' if action == 'start' else '-d', 'change', native]
        return ['dinitctl', '-p', str(self.socket), action, native]

    def request(self, action, name, success=True):
        result = self.execute(self.command(action, name))
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + self.log_text())
        return result

    def asynchronous_start(self, name):
        process = subprocess.Popen(self.command('start', name), env=self.environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.pending.append(process)
        return process

    def cleanup(self):
        try:
            for process in self.pending:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=3)
            if self.process is not None and self.process.poll() is None:
                if self.manager == 's6-rc':
                    self.execute(['s6-rc', '-l', str(self.live), '-da', 'change'], timeout=5)
                    self.execute(['s6-svscanctl', '-t', str(self.scan)], timeout=5)
                else:
                    self.execute(['dinitctl', '-p', str(self.socket), 'shutdown'], timeout=5)
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=3)
        finally:
            if self.process is not None and self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
            self.log.close()
            shutil.rmtree(self.configuration, ignore_errors=True)
            self.directory.cleanup()

    def test_failed_prerequisite_and_explicit_retry(self):
        result = self.request('start', 'consumer', success=False)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.root / 'attempts').exists(), self.log_text())
        self.assertFalse((self.root / 'consumer').exists())
        self.request('start', 'independent')
        self.assertEqual((self.root / 'independent').read_text(), 'run\n')
        (self.root / 'release').touch()
        self.request('start', 'consumer')
        self.wait_for(lambda: (self.root / 'consumer').exists(), 'consumer after prerequisite success')
        attempts = (self.root / 'attempts').read_text()
        self.request('start', 'consumer')
        self.assertEqual((self.root / 'attempts').read_text(), attempts)

    def test_successful_oneshot_does_not_repeat(self):
        self.request('start', 'independent')
        self.request('start', 'independent')
        time.sleep(1.1)
        self.assertEqual((self.root / 'independent').read_text().splitlines(), ['run'])

    def test_arguments_environment_and_configuration(self):
        self.request('start', 'environment')
        captured = json.loads((self.root / 'environment.json').read_text())
        source = self.configuration / self.manifest['services']['environment']['nativeName'] / 'nested/settings.conf'
        self.assertEqual(captured['arguments'], ['--configuration', str(source), '--entry',
                         'first value', '--entry', 'second "quote"', 'tail argument'])
        self.assertEqual(captured['configuration'], 'generated configuration\n')
        self.assertEqual((source.parent.parent / 'reference.conf').read_text(), 'file-backed configuration\n')
        self.assertEqual(captured['literal'], 'spaces \' " $HOME $(not-a-command)\nsecond line')
        self.assertEqual(captured['empty'], '')
        self.assertTrue(captured['unset'])
        self.assertEqual(captured['uid_environment'], 'declarative value')
        self.assertFalse((source.parent.parent / 'disabled').exists())

    def test_executable_with_equals_is_not_an_environment_assignment(self):
        self.request('start', 'literal-executable')
        self.assertEqual((self.root / 'literal-executable').read_text(), 'executed\n')

    def test_ownership_paths_do_not_collide(self):
        services = self.manifest['services']
        self.assertNotEqual(services['ownership/worker']['nativeName'], services['ownership-worker']['nativeName'])
        for name, filename in [('ownership/worker', 'nested-worker'), ('ownership-worker', 'flat-worker')]:
            self.request('start', name)
            self.assertEqual((self.root / filename).read_text(), 'run\n')
        self.assertFalse((self.root / 'attempts').exists())

    def test_readiness_holds_dependent_after_process_start(self):
        process = self.asynchronous_start('ready-consumer')
        self.wait_for(lambda: (self.root / 'starting').exists(), 'readiness process startup')
        time.sleep(0.15)
        self.assertIsNone(process.poll(), self.log_text())
        self.assertFalse((self.root / 'ready-consumer').exists())
        (self.root / 'ready').touch()
        output, _ = process.communicate(timeout=8)
        self.assertEqual(process.returncode, 0, output + self.log_text())
        self.assertEqual((self.root / 'ready-consumer').read_text(), 'run\n')

    def test_readiness_timeout_blocks_dependent(self):
        result = self.request('start', 'timeout-consumer', success=False)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.root / 'timeout-starting').exists())
        self.assertFalse((self.root / 'timeout-consumer').exists())

    def test_longrun_restarts_beyond_default_limits(self):
        self.request('start', 'restart', success=False)
        def restarted():
            try:
                return int((self.root / 'restarts').read_text()) >= 6
            except (FileNotFoundError, ValueError):
                return False
        self.wait_for(restarted, 'six process starts', timeout=15)

    def test_explicit_stop_and_start(self):
        (self.root / 'release').touch()
        self.request('start', 'consumer')
        self.wait_for(lambda: (self.root / 'consumer').exists(), 'initial consumer start')
        self.request('stop', 'consumer')
        self.request('start', 'consumer')
        self.wait_for(lambda: len((self.root / 'consumer').read_text().splitlines()) == 2,
                      'second consumer start')


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: test-runtime.py S6RC_PACKAGE DINIT_PACKAGE')
    packages = [Path(path).resolve() for path in sys.argv[1:]]
    mapping = Path('/proc/self/uid_map').read_text().split()
    if os.getpid() != 1 or os.getuid() != 0 or len(mapping) != 3 or mapping[2] != '1':
        raise SystemExit('run through tests/portable-services/default.nix; private PID and user namespaces are required')
    # The runner creates the mount namespace. Package and script paths are in /nix.
    subprocess.run(['mount', '--make-rprivate', '/'], check=True)
    subprocess.run(['mount', '-t', 'tmpfs', '-o', 'mode=1777', 'tmpfs', '/tmp'], check=True)
    os.environ['TMPDIR'] = '/tmp'
    tempfile.tempdir = None
    suite = unittest.TestSuite()
    for manager, package in zip(['s6-rc', 'dinit'], packages):
        case = type(manager + 'Contract', (ManagerContract,), {'manager': manager, 'package': package})
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(case))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())


if __name__ == '__main__':
    main()
