"""Exercise the native FIFO client against real runsv, without root."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

CONTROL = os.environ['NNS_SERVICE_CONTROL']
RUNSV = shutil.which('runsv')
SV = shutil.which('sv')


class ServiceControlTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(prefix='nns-control-test-')
        self.root = Path(self.temporary_directory.name)
        self.processes = []

    def tearDown(self):
        for process, service in reversed(self.processes):
            if process.poll() is None:
                self.run_control(service, 'down')
                self.run_control(service, 'exit')
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
        self.temporary_directory.cleanup()

    def create_service(self, run_script, check_script=None):
        service = self.root / f'service-{len(self.processes)}'
        service.mkdir()
        run = service / 'run'
        run.write_text(f'#!{shutil.which("sh")}\n' + run_script + '\n')
        run.chmod(0o755)
        (service / 'down').touch()
        if check_script is not None:
            check = service / 'check'
            check.write_text(f'#!{shutil.which("sh")}\n' + check_script + '\n')
            check.chmod(0o755)
        process = subprocess.Popen([RUNSV, str(service)], start_new_session=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.processes.append((process, service))
        self.wait_for(lambda: (service / 'supervise/control').is_fifo(),
                      'runsv did not create its control FIFO')
        return service

    def run_control(self, service, command):
        return subprocess.run([CONTROL, str(service), command], capture_output=True,
                              text=True, timeout=2)

    def status(self, service):
        return subprocess.check_output([SV, 'status', str(service)], text=True, timeout=2)

    def wait_for(self, predicate, message):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail(message)

    def test_once_runs_finite_action_once_on_both_exit_codes(self):
        for exit_code in (0, 19):
            with self.subTest(exit_code=exit_code):
                log = self.root / f'action-{exit_code}'
                service = self.create_service(f"printf 'action\\n' >> '{log}'\nexit {exit_code}")
                result = self.run_control(service, 'once')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.wait_for(log.exists, 'once action did not run')
                self.wait_for(lambda: self.status(service).startswith('down:'),
                              'once service did not return to down state')
                time.sleep(1.2)  # Longer than runsv's minimum restart delay.
                self.assertEqual(log.read_text().splitlines(), ['action'])

    def test_up_and_down_control_longrun(self):
        service = self.create_service('exec sleep 30')
        self.assertEqual(self.run_control(service, 'up').returncode, 0)
        self.wait_for(lambda: self.status(service).startswith('run:'), 'up did not start the longrun')
        self.assertEqual(self.run_control(service, 'down').returncode, 0)
        self.wait_for(lambda: self.status(service).startswith('down:'), 'down did not stop the longrun')

    def test_exit_stops_supervisor(self):
        service = self.create_service('exec sleep 30')
        process = self.processes[-1][0]
        result = self.run_control(service, 'exit')
        self.assertEqual(result.returncode, 0, result.stderr)
        process.wait(timeout=4)
        self.assertEqual(process.returncode, 0)

    def test_readiness_differs_from_supervisor_run_state(self):
        release = self.root / 'ready'
        service = self.create_service('exec sleep 30', f"test -e '{release}'")
        self.assertEqual(self.run_control(service, 'up').returncode, 0)
        self.wait_for(lambda: self.status(service).startswith('run:'), 'longrun did not enter run state')
        failed_check = subprocess.run([SV, '-w', '1', 'check', str(service)],
                                      capture_output=True, text=True, timeout=3)
        self.assertNotEqual(failed_check.returncode, 0)
        release.touch()
        ready_check = subprocess.run([SV, '-w', '1', 'check', str(service)],
                                     capture_output=True, text=True, timeout=3)
        self.assertEqual(ready_check.returncode, 0, ready_check.stderr)

    def control_path(self):
        service = self.root / 'invalid-service'
        (service / 'supervise').mkdir(parents=True)
        return service, service / 'supervise/control'

    def test_rejects_missing_path_without_waiting(self):
        self.assertNotEqual(self.run_control(self.root / 'missing', 'up').returncode, 0)

    def test_rejects_fifo_without_reader_without_waiting(self):
        service, fifo = self.control_path()
        os.mkfifo(fifo)
        self.assertNotEqual(self.run_control(service, 'up').returncode, 0)

    def test_rejects_regular_file_without_writing_it(self):
        service, regular = self.control_path()
        regular.write_text('preserve')
        self.assertNotEqual(self.run_control(service, 'up').returncode, 0)
        self.assertEqual(regular.read_text(), 'preserve')

    def test_rejects_final_component_symlink_without_writing_target(self):
        service, link = self.control_path()
        target = self.root / 'target'
        target.write_text('preserve')
        link.symlink_to(target)
        self.assertNotEqual(self.run_control(service, 'up').returncode, 0)
        self.assertEqual(target.read_text(), 'preserve')

    def test_rejects_invalid_command(self):
        result = self.run_control(self.root / 'missing', 'restart')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid command', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
