"""NNS activation and single-owner handoff against real subordinate managers."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BASE = Path('/data/nns-service-managers')
BACKENDS = ('runit', 's6-rc', 'dinit')
VARIANTS = ('base', 'update', 'typechange', 'remove', 'gated', 'finite-failure')


def reap_orphans():
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if not pid:
            return


def running(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[0] not in ('Z', 'X')
    except FileNotFoundError:
        return False


class ServiceManagerTest(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(BASE, ignore_errors=True)
        BASE.mkdir()
        self.state = BASE / 'state'
        self.launcher = BASE / 'bin/launcher'
        self.launcher.parent.mkdir()
        self.launcher.write_text(f'''#!{shutil.which("sh")}
shift 2
test "$(cat {BASE}/state/supervisor.pid)" = "$$" || exit 91
test -s {BASE}/state/manager-process || exit 92
test ! -e /proc/self/fd/9 || exit 93
test "$NNS_SERVICE_LOCKED" = 0 || exit 94
exec "$@"
''')
        self.launcher.chmod(0o755)
        self.generation = self.generations[(self.backend, 'base')]
        self.current = self.generation
        self.addCleanup(self.cleanup)
        self.activate(self.generation)
        self.wait_for(lambda: (BASE / 'worker-pids').exists(), 'worker start')
        self.assert_owner()

    def command(self, arguments, check=True, timeout=45):
        result = subprocess.run(list(map(str, arguments)), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        reap_orphans()
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + '\n' + self.log_text())
        return result

    def manager_state(self):
        """Bounded native state dump for failure diagnostics."""
        lines = []
        runtime = self.state / 'managers' / self.backend
        for name in ('live', 'scan'):
            entry = runtime / name
            if not entry.exists() and not entry.is_symlink():
                continue
            target = entry.resolve() if entry.is_symlink() else entry
            lines.append(f'{name} -> {target}')
            if name == 'scan' and target.is_dir():
                for service in sorted(target.iterdir()):
                    try:
                        status = subprocess.run(
                            [shutil.which('s6-svstat'), str(service)],
                            capture_output=True, text=True, timeout=5).stdout.strip()
                    except (OSError, subprocess.TimeoutExpired):
                        status = 'unavailable'
                    lines.append(f'  {service.name}: {status or "no state"}')
        for service in sorted((self.state / 'services').glob('*')):
            run = service / 'run'
            marker = ' pending-update' if (service / 'pending-update').exists() else ''
            target = os.readlink(run) if run.is_symlink() else 'absent'
            lines.append(f'service {service.name}: run={target}{marker}')
        return '\n'.join(lines)

    def native_policy_running(self):
        """A failed native reconciliation must leave the policy process running."""
        if self.backend == 'runit':
            dispatcher = self.state / 'services/nns-dispatcher'
            result = subprocess.run(
                [str(self.generation / 'system-profile/bin/sv'), 'status', str(dispatcher)],
                capture_output=True, text=True, timeout=10)
            return result.returncode == 0 and result.stdout.startswith('run:')
        runtime = self.state / 'managers' / self.backend
        if self.backend == 's6-rc':
            result = subprocess.run(
                [shutil.which('s6-svstat'), str(runtime / 'scan/svc-nns-dispatcher')],
                capture_output=True, text=True, timeout=10)
            return result.stdout.startswith('up')
        result = subprocess.run(
            [shutil.which('dinitctl'), '--quiet', '--socket-path', str(runtime / 'control'),
             'is-started', 'svc-nns-dispatcher'],
            capture_output=True, text=True, timeout=10)
        return result.returncode == 0

    def wait_for(self, predicate, description, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            reap_orphans()
            if predicate():
                return
            time.sleep(0.05)
        processes = []
        for path in Path('/proc').glob('[0-9]*/stat'):
            try:
                processes.append(path.read_text().strip())
            except FileNotFoundError:
                pass
        self.fail(f'timed out waiting for {description}\n{self.log_text()}\n'
                  f'{self.manager_state()}\n' + '\n'.join(processes))

    def log_text(self):
        path = self.state / 'supervisor.log'
        return path.read_text(errors='replace') if path.exists() else ''

    def completed(self, name):
        return (self.state / 'services' / name / 'completed').exists()

    def activate(self, generation, mode='switch', check=True):
        result = self.command([generation / 'activate', mode], check=check)
        if not result.returncode:
            self.current = generation
        return result

    def cleanup(self):
        if getattr(self, 'abrupt_manager_exit', False):
            # The final Dinit case proves refusal to touch unknown children.
            # PID-namespace termination, not an unsafe replacement, removes them.
            return
        result = self.command([self.current / 'service-control', 'stop'], check=False)
        self.assertEqual(result.returncode, 0, result.stdout + '\n' + self.log_text())
        reap_orphans()
        self.assertFalse((BASE / 'duplicate-owner').exists())

    def assert_owner(self):
        self.wait_for(lambda: (BASE / 'daemon-ready').exists(), 'daemon readiness')
        pids = (BASE / 'daemon-pids').read_text().splitlines()
        self.assertEqual(sum(running(pid) for pid in pids), 1, pids)
        self.assertFalse((BASE / 'duplicate-owner').exists())

    def test_retry_completion_and_independent_startup(self):
        status = self.state / 'services/prepare/exit-status'
        self.wait_for(status.exists, 'failed finite status')
        self.assertNotEqual(status.read_text().split()[0], '0')
        self.assertFalse(self.completed('prepare'))
        self.assertFalse((BASE / 'consumer-ready').exists())
        self.assertFalse(self.completed('unlock'))
        self.assertFalse((BASE / 'labeled').exists())
        self.assert_owner()
        (BASE / 'release').touch()
        self.wait_for(lambda: self.completed('prepare'), 'automatic finite retry')
        self.wait_for(lambda: (BASE / 'consumer-ready').exists(), 'successful prerequisite gating')
        count = len((BASE / 'prepare-attempts').read_text().splitlines())
        time.sleep(1.4)
        self.assertEqual(len((BASE / 'prepare-attempts').read_text().splitlines()), count)
        self.assertEqual(len((BASE / 'worker-pids').read_text().splitlines()), 1, 'an independent startup goal restarted after another branch failed')

    def test_reapplication_and_stable_independent_longrun(self):
        (BASE / 'release').touch()
        self.wait_for(lambda: self.completed('prepare') and self.completed('directory-shared'), 'finite success')
        worker = (BASE / 'worker-pids').read_text()
        daemon = (BASE / 'daemon-pids').read_text()
        count = len((BASE / 'prepare-attempts').read_text().splitlines())
        shared = BASE / 'shared'
        shared.chmod(0o777)
        self.activate(self.generation)
        self.wait_for(lambda: self.completed('prepare') and len((BASE / 'prepare-attempts').read_text().splitlines()) > count,
                      'finite reapplication')
        self.wait_for(lambda: shared.stat().st_mode & 0o7777 == 0o710, 'directory mode reapplication')
        self.assertEqual((BASE / 'worker-pids').read_text(), worker)
        self.assertEqual((BASE / 'daemon-pids').read_text(), daemon)

    def test_scanner_exit_cleans_surviving_supervisors(self):
        if self.backend != 's6-rc':
            self.skipTest('s6 scanner recovery')
        pid = int((self.state / 'supervisor.pid').read_text())
        os.kill(pid, 9)
        self.wait_for(lambda: not running(pid), 'scanner exit')
        self.activate(self.generation)
        self.assert_owner()
        self.assertNotEqual(int((self.state / 'supervisor.pid').read_text()), pid)

    def test_unrecoverable_manager_exit_refuses_takeover(self):
        if self.backend != 'dinit':
            self.skipTest('Dinit cannot account for children after manager loss')
        # This is the last case in the last backend. Its orphans remain confined
        # until the enclosing PID namespace exits immediately after the suite.
        pid = int((self.state / 'supervisor.pid').read_text())
        os.kill(pid, 9)
        self.wait_for(lambda: not running(pid), 'manager exit')
        self.abrupt_manager_exit = True
        owner = (BASE / 'daemon-pids').read_text()
        result = self.activate(self.generation, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exited unexpectedly', result.stdout)
        result = self.activate(self.generations[('runit', 'base')], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((BASE / 'daemon-pids').read_text(), owner)
        self.assert_owner()

    def test_unlock_phase_and_account_identity(self):
        self.assertFalse(self.completed('unlock'))
        self.assertFalse(self.completed('after-unlock'))
        (BASE / 'unlocked').touch()
        self.wait_for(lambda: self.completed('unlock') and self.completed('after-unlock') and self.completed('directory-labeled'), 'unlock phase')
        (BASE / 'uid-drift').touch()
        self.activate(self.generation)
        status = self.state / 'services/directory-labeled/exit-status'
        self.wait_for(lambda: status.exists() and status.read_text().split()[0] != '0', 'UID drift rejection')
        self.assertFalse(self.completed('directory-labeled'))
        (BASE / 'uid-drift').unlink()
        self.wait_for(lambda: self.completed('directory-labeled'), 'UID drift recovery')
        (BASE / 'unlocked').unlink()
        self.activate(self.generation, 'boot')
        self.assertFalse(self.completed('unlock'), 'boot reused prior unlock completion')
        self.assertFalse(self.completed('after-unlock'))
        (BASE / 'unlocked').touch()
        self.wait_for(lambda: self.completed('unlock'), 'boot unlock dispatch')

    def test_longrun_to_failed_finite_does_not_block_activation(self):
        (BASE / 'release').touch()
        self.wait_for(lambda: (BASE / 'consumer-ready').exists(), 'active dependent')
        (BASE / 'consumer-ready').unlink()
        self.activate(self.generations[(self.backend, 'finite-failure')])
        status = self.state / 'services/worker/exit-status'
        self.wait_for(lambda: status.exists() and status.read_text().split()[0] != '0', 'failed replacement action')
        self.assertFalse(self.completed('worker'))
        self.assertFalse((BASE / 'consumer-ready').exists())
        self.assert_owner()
        (BASE / 'finite-release').touch()
        self.wait_for(lambda: self.completed('worker') and (BASE / 'consumer-ready').exists(), 'replacement retry and dependent startup')

    def test_new_unlock_dependency_is_not_started_by_database_update(self):
        previous_records = (BASE / 'worker-pids').read_text().splitlines()
        previous_pid = previous_records[-1]
        self.activate(self.generations[(self.backend, 'gated')])
        self.wait_for(lambda: not running(previous_pid), 'previous worker stop')
        time.sleep(1.2)
        self.assertEqual((BASE / 'worker-pids').read_text().splitlines(), previous_records)
        self.assertFalse(self.completed('unlock'))
        (BASE / 'unlocked').touch()
        self.wait_for(lambda: len((BASE / 'worker-pids').read_text().splitlines()) > len(previous_records), 'unlock-dependent worker')
        self.assertTrue(self.completed('unlock'))

    def test_changed_program_kind_changes_and_removal(self):
        (BASE / 'release').touch()
        self.wait_for(lambda: (BASE / 'consumer-ready').exists(), 'active dependent before kind changes')
        self.activate(self.generations[(self.backend, 'update')])
        self.wait_for(lambda: (BASE / 'worker-version').read_text().strip() == 'updated', 'changed longrun')
        self.assertGreaterEqual(len((BASE / 'worker-pids').read_text().splitlines()), 2)
        self.activate(self.generations[(self.backend, 'typechange')])
        self.wait_for(lambda: self.completed('worker'), 'longrun to oneshot')
        self.activate(self.generation)
        self.wait_for(lambda: not self.completed('worker') and len((BASE / 'worker-pids').read_text().splitlines()) >= 3,
                      'oneshot to longrun')
        self.activate(self.generations[(self.backend, 'remove')])
        self.assertFalse((self.state / 'services/removable').exists())
        self.assertFalse((self.state / 'services/removal-consumer').exists())
        self.assertTrue((BASE / 'removable').exists(), 'service removal deleted application data')
        self.assert_owner()

    def test_writable_process_identity_is_rejected_before_publication(self):
        record = self.state / 'manager-process'
        profile = os.readlink(BASE / 'profiles/system-profile')
        record.chmod(0o666)
        try:
            result = self.activate(self.generation, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('writable by another identity', result.stdout)
            self.assertEqual(os.readlink(BASE / 'profiles/system-profile'), profile)
        finally:
            record.chmod(0o600)
        self.assert_owner()

    def test_native_administrative_links_are_rejected_before_publication(self):
        if self.backend == 'runit':
            self.skipTest('native administrative paths')
        runtime = self.state / 'managers' / self.backend
        directory = runtime / ('scan' if self.backend == 's6-rc' else 'services')
        original = runtime / 'retained-directory'
        victim = BASE / 'administrative-victim'
        victim.mkdir()
        directory.rename(original)
        directory.symlink_to(victim)
        profile = os.readlink(BASE / 'profiles/system-profile')
        try:
            result = self.activate(self.generation, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('symlink', result.stdout)
            self.assertEqual(os.readlink(BASE / 'profiles/system-profile'), profile)
            self.assertEqual(list(victim.iterdir()), [])
        finally:
            directory.unlink()
            original.rename(directory)
        self.assert_owner()

    def test_native_operator_stop_survives_completed_startup(self):
        if self.backend == 'runit':
            self.skipTest('native dispatcher completion')
        (BASE / 'release').touch()
        (BASE / 'unlocked').touch()
        self.wait_for(lambda: self.completed('prepare') and self.completed('after-unlock') and self.completed('directory-labeled'), 'complete startup')
        tools = self.generation / 'system-profile/bin'
        runtime = self.state / 'managers' / self.backend
        if self.backend == 's6-rc':
            supervisor = runtime / 'scan/svc-nns-dispatcher'
            self.wait_for(lambda: self.command([tools / 's6-svstat', '-o', 'up', supervisor]).stdout.strip() == 'false', 'dispatcher exit')
            self.command([tools / 's6-rc', '-l', runtime / 'live', '-d', 'change', 'svc-worker'])
        else:
            self.wait_for(lambda: self.command([tools / 'dinitctl', '-p', runtime / 'control', 'is-started', 'svc-nns-dispatcher'], check=False).returncode != 0, 'dispatcher exit')
            self.command([tools / 'dinitctl', '-p', runtime / 'control', 'stop', 'svc-worker'])
        records = (BASE / 'worker-pids').read_text()
        self.assertFalse(running(records.splitlines()[-1]))
        time.sleep(1.3)
        self.assertEqual((BASE / 'worker-pids').read_text(), records)
        self.assert_owner()

    def test_coordinated_stop_can_activate_again(self):
        self.command([self.current / 'service-control', 'stop'])
        self.assertFalse((self.state / 'supervisor.pid').exists())
        self.activate(self.generation)
        self.assert_owner()

    def test_failed_candidate_preflight_does_not_publish(self):
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            candidate = Path(directory) / 'generation'
            shutil.copytree(self.generation, candidate, symlinks=True)
            (candidate / 'service-manager').write_text('missing-manager\n')
            profiles = {p.name: os.readlink(p) for p in (BASE / 'profiles').iterdir() if p.is_symlink()}
            owner = (BASE / 'daemon-pids').read_text()
            result = self.activate(candidate, check=False)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(profiles, {p.name: os.readlink(p) for p in (BASE / 'profiles').iterdir() if p.is_symlink()})
            self.assertEqual((BASE / 'daemon-pids').read_text(), owner)
            self.assertEqual((self.state / 'manager-generation').resolve(), self.current)

    def test_backend_switches_and_rollback_have_one_owner(self):
        for backend in BACKENDS:
            if backend == self.backend:
                continue
            target = self.generations[(backend, 'base')]
            self.activate(target)
            self.assert_owner()
            self.assertEqual((self.state / 'manager-generation').resolve(), target)
            self.activate(self.generation)
            self.assert_owner()
            self.assertEqual((self.state / 'manager-generation').resolve(), self.generation)

    def test_legacy_previous_generation_without_manager_file(self):
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            legacy = Path(directory) / 'legacy'
            shutil.copytree(self.generation, legacy, symlinks=True)
            (legacy / 'service-manager').unlink()
            (legacy / 'service-control').unlink()
            (legacy / 'service-control').write_text(f'#!{shutil.which("sh")}\nexit 0\n')
            (legacy / 'service-control').chmod(0o755)
            self.command([self.current / 'service-control', 'stop'])
            (self.state / 'manager-generation').unlink()
            (self.state / 'manager-generation').symlink_to(legacy)
            self.activate(self.generation)
            self.assert_owner()
            self.assertEqual((self.state / 'manager-generation').resolve(), self.generation)

    def test_failed_native_reconciliation_can_retry_the_same_generation(self):
        if self.backend == 'runit':
            self.skipTest('native update intent')
        (BASE / 'release').touch()
        self.wait_for(lambda: (BASE / 'consumer-ready').exists(), 'active dependent')
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            directory = Path(directory)
            candidate = directory / 'generation'
            shutil.copytree(self.generations[(self.backend, 'update')], candidate, symlinks=True)
            original_profile = (candidate / 'system-profile').resolve()
            profile = directory / 'profile'
            (profile / 'bin').mkdir(parents=True)
            for entry in (original_profile / 'bin').iterdir():
                (profile / 'bin' / entry.name).symlink_to(entry)
            (profile / 'etc').symlink_to(original_profile / 'etc')
            (candidate / 'system-profile').unlink()
            (candidate / 'system-profile').symlink_to(profile)
            name = 's6-rc' if self.backend == 's6-rc' else 'dinitctl'
            original_command = (original_profile / 'bin' / name).resolve()
            command = profile / 'bin' / name
            command.unlink()
            pattern = '*" -d change "*' if self.backend == 's6-rc' else '*" stop "*" svc-worker "*'
            command.write_text(f'#!{shutil.which("sh")}\ncase " $* " in {pattern}) exit 37;; esac\nexec "{original_command}" "$@"\n')
            command.chmod(0o755)
            result = self.activate(candidate, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(self.native_policy_running(),
                            'failed native reconciliation left the policy process stopped')
            pending = self.state / 'services/worker/pending-update'
            self.assertTrue(pending.exists(), 'failed update lost its restart intent')
            self.assertEqual((BASE / 'worker-version').read_text().strip(), 'base')
            command.unlink()
            command.symlink_to(original_command)
            self.activate(candidate)
            self.wait_for(lambda: (BASE / 'worker-version').read_text().strip() == 'updated', 'same-generation retry')
            self.assertFalse(pending.exists())
            self.assert_owner()
            self.activate(self.generation)

    def test_failed_stop_prevents_replacement_owner(self):
        controller = self.current / 'service-control'
        original = controller.read_text()
        owner = (BASE / 'daemon-pids').read_text()
        try:
            controller.write_text(f'#!{shutil.which("sh")}\nexit 37\n')
            target = self.generations[(next(b for b in BACKENDS if b != self.backend), 'base')]
            result = self.activate(target, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.state / 'manager-generation').resolve(), self.current)
            self.assertEqual((BASE / 'daemon-pids').read_text(), owner)
            self.assert_owner()
        finally:
            controller.write_text(original)

    def test_pending_finite_group_is_cancelled_before_update_and_handoff(self):
        if self.backend == 'runit':
            self.skipTest('native cancellation barrier')
        for handoff in (False, True):
            (BASE / 'hang').touch()
            self.activate(self.generation)
            child_record = BASE / 'hung-child'
            # An attempt can start before activation pauses the dispatcher.
            # Its record survives cancellation until the replacement starts.
            self.wait_for(lambda: child_record.exists() and running(child_record.read_text().strip()), 'pending finite child')
            pid = child_record.read_text().strip()
            (BASE / 'hang').unlink()
            target = self.generations[('runit', 'base')] if handoff else self.generation
            self.activate(target)
            self.wait_for(lambda: not running(pid), 'cancelled finite child')
            child_record.unlink()
            self.assert_owner()

    def test_runit_delayed_dispatcher_supervision_retries(self):
        if self.backend != 'runit':
            self.skipTest('runit delayed supervisor recovery')
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            directory = Path(directory)
            candidate = directory / 'generation'
            shutil.copytree(self.generation, candidate, symlinks=True)
            original_profile = (candidate / 'system-profile').resolve()
            profile = directory / 'profile'
            (profile / 'bin').mkdir(parents=True)
            for entry in (original_profile / 'bin').iterdir():
                (profile / 'bin' / entry.name).symlink_to(entry)
            (profile / 'etc').symlink_to(original_profile / 'etc')
            (candidate / 'system-profile').unlink()
            (candidate / 'system-profile').symlink_to(profile)
            original_sv = (original_profile / 'bin' / 'sv').resolve()
            sv_wrapper = profile / 'bin' / 'sv'
            sv_wrapper.unlink()
            # Fail status check on nns-dispatcher twice, then forward to original.
            fail_count_file = directory / '.sv-fail-count'
            fail_count_file.write_text('0')
            sv_wrapper.write_text(f'''#!{shutil.which("sh")}
fail_file={fail_count_file}
if [ "$1" = "status" ] && echo " $* " | grep -q 'nns-dispatcher'; then
    count=$(cat "$fail_file")
    if [ "$count" -lt 2 ]; then
        echo $((count + 1)) > "$fail_file"
        echo 'transient supervisor unavailable' >&2
        exit 1
    fi
fi
exec "{original_sv}" "$@"
''')
            sv_wrapper.chmod(0o755)
            result = self.activate(candidate)
            self.assertEqual(result.stdout, '', 'successful control operations must be quiet')
            self.assertEqual(fail_count_file.read_text().strip(), '2')
            self.assertTrue(self.native_policy_running(), 'dispatcher must be running after retry')
            self.assert_owner()
            self.activate(self.generation)

    def test_runit_startup_command_failure_returns_error(self):
        if self.backend != 'runit':
            self.skipTest('runit startup failure')
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            directory = Path(directory)
            candidate = directory / 'generation'
            shutil.copytree(self.generations[('runit', 'update')], candidate, symlinks=True)
            original_profile = (candidate / 'system-profile').resolve()
            profile = directory / 'profile'
            (profile / 'bin').mkdir(parents=True)
            for entry in (original_profile / 'bin').iterdir():
                (profile / 'bin' / entry.name).symlink_to(entry)
            (profile / 'etc').symlink_to(original_profile / 'etc')
            (candidate / 'system-profile').unlink()
            (candidate / 'system-profile').symlink_to(profile)
            original_sv = (original_profile / 'bin' / 'sv').resolve()
            sv_wrapper = profile / 'bin' / 'sv'
            sv_wrapper.unlink()
            # Fail on start/up commands for dispatcher.
            sv_wrapper.write_text(f'''#!{shutil.which("sh")}
case " $* " in
    *" up "*"/nns-dispatcher "|*" start "*"/nns-dispatcher ")
        echo 'injected dispatcher start failure' >&2
        exit 37
        ;;
esac
exec "{original_sv}" "$@"
''')
            sv_wrapper.chmod(0o755)
            result = self.activate(candidate, check=False)
            self.assertNotEqual(result.returncode, 0, 'activation must fail on start error')
            # Publication identifies the controller for the partially applied
            # generation. Activation failure is not an automatic rollback.
            self.assertEqual((self.state / 'manager-generation').resolve(), candidate)
            self.assertIn('injected dispatcher start failure', result.stdout)
            self.assertTrue((self.state / 'manager-process').exists())
            pending = self.state / 'services/worker/pending-update'
            self.assertTrue(pending.exists(), 'published command still needs reconciliation')
            sv_wrapper.unlink()
            sv_wrapper.symlink_to(original_sv)
            self.activate(candidate)
            self.wait_for(lambda: (BASE / 'worker-version').read_text().strip() == 'updated',
                          'retry after failed dispatcher start')
            self.assertFalse(pending.exists())
            self.assert_owner()
            self.activate(self.generation)

    def test_runit_failed_stop_during_update_restores_dispatcher(self):
        if self.backend != 'runit':
            self.skipTest('runit failed update stop recovery')
        (BASE / 'release').touch()
        self.wait_for(lambda: (BASE / 'consumer-ready').exists(), 'active dependent')
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            directory = Path(directory)
            candidate = directory / 'generation'
            shutil.copytree(self.generations[(self.backend, 'update')], candidate, symlinks=True)
            original_profile = (candidate / 'system-profile').resolve()
            profile = directory / 'profile'
            (profile / 'bin').mkdir(parents=True)
            for entry in (original_profile / 'bin').iterdir():
                (profile / 'bin' / entry.name).symlink_to(entry)
            (profile / 'etc').symlink_to(original_profile / 'etc')
            (candidate / 'system-profile').unlink()
            (candidate / 'system-profile').symlink_to(profile)
            original_sv = (original_profile / 'bin' / 'sv').resolve()
            sv_wrapper = profile / 'bin' / 'sv'
            sv_wrapper.unlink()
            # Fail on stop of worker during update.
            sv_wrapper.write_text(f'''#!{shutil.which("sh")}
case "$*" in
    *" down "*/worker)
        exit 37
        ;;
esac
exec "{original_sv}" "$@"
''')
            sv_wrapper.chmod(0o755)
            result = self.activate(candidate, check=False)
            self.assertNotEqual(result.returncode, 0, 'failed stop must fail activation')
            self.assertTrue(self.native_policy_running(), 'dispatcher must remain running after failed stop')
            pending = self.state / 'services/worker/pending-update'
            self.assertTrue(pending.exists(), 'pending-update must be retained after failed stop')
            self.assertEqual((BASE / 'worker-version').read_text().strip(), 'base', 'worker version must not change')
            # Restore and retry with same candidate.
            sv_wrapper.unlink()
            sv_wrapper.symlink_to(original_sv)
            self.activate(candidate)
            self.wait_for(lambda: (BASE / 'worker-version').read_text().strip() == 'updated', 'same-generation retry succeeds')
            self.assertFalse(pending.exists(), 'pending-update cleared after successful update')
            self.assert_owner()
            self.activate(self.generation)

    def test_runit_failed_shutdown_handoff_preserves_records(self):
        if self.backend != 'runit':
            self.skipTest('runit failed handoff recovery')
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            directory = Path(directory)
            candidate = directory / 'generation'
            shutil.copytree(self.generation, candidate, symlinks=True)
            original_profile = (candidate / 'system-profile').resolve()
            profile = directory / 'profile'
            (profile / 'bin').mkdir(parents=True)
            for entry in (original_profile / 'bin').iterdir():
                (profile / 'bin' / entry.name).symlink_to(entry)
            (profile / 'etc').symlink_to(original_profile / 'etc')
            (candidate / 'system-profile').unlink()
            (candidate / 'system-profile').symlink_to(profile)
            original_sv = (original_profile / 'bin/sv').resolve()
            command = profile / 'bin/sv'
            self.activate(candidate)
            owner = (BASE / 'daemon-pids').read_text()
            records = {name: (self.state / name).read_text()
                       for name in ('supervisor.pid', 'manager-process')}
            command.unlink()
            command.write_text(f'''#!{shutil.which("sh")}
case " $* " in
    *" shutdown "*"/worker ") echo 'injected shutdown failure' >&2; exit 37;;
esac
exec "{original_sv}" "$@"
''')
            command.chmod(0o755)
            try:
                result = self.activate(self.generations[('s6-rc', 'base')], check=False)
                self.assertNotEqual(result.returncode, 0, 'failed shutdown must prevent handoff')
                self.assertIn('injected shutdown failure', result.stdout)
                self.assertEqual((self.state / 'manager-generation').resolve(), candidate)
                for name, value in records.items():
                    self.assertEqual((self.state / name).read_text(), value)
                self.assertTrue((self.state / 'services/worker').is_dir())
                self.assertEqual((BASE / 'daemon-pids').read_text(), owner)
                self.assertFalse((BASE / 'duplicate-owner').exists())
            finally:
                command.unlink()
                command.symlink_to(original_sv)
                # Finish the interrupted shutdown before restoring the baseline.
                self.command([candidate / 'service-control', 'stop'])
                self.activate(self.generation)


def main():
    mapping = Path('/proc/self/uid_map').read_text().split()
    if os.getpid() != 1 or os.getuid() != 0 or len(mapping) != 3 or mapping[2] != '1':
        raise SystemExit('requires PID 1 in a one-ID user namespace')
    if len(sys.argv) != 1 + len(BACKENDS) * len(VARIANTS):
        raise SystemExit('expected each backend and variant generation')
    subprocess.run(['mount', '--make-rprivate', '/'], check=True)
    # The launcher supplies private mount points, never create these on the host.
    for path, options in (('/data', 'mode=755'), ('/system', 'mode=755'), ('/tmp', 'mode=1777')):
        Path(path).mkdir(exist_ok=True)
        subprocess.run(['mount', '-t', 'tmpfs', '-o', options, 'tmpfs', path], check=True)
    system = Path('/system/bin')
    system.mkdir()
    shell = shutil.which('sh')
    scripts = {
        'getprop': 'test -f /data/nns-service-managers/unlocked && echo true || echo false\n',
        'stat': "if test -f /data/nns-service-managers/uid-drift; then echo '9999:9999:u:object_r:app_data_file:s0'; else echo '0:0:u:object_r:app_data_file:s0'; fi\n",
        'chcon': 'echo "$1 $2" >> /data/nns-service-managers/labels\n',
    }
    for name, body in scripts.items():
        script = system / name
        script.write_text(f'#!{shell}\n{body}')
        script.chmod(0o755)
    os.environ['TMPDIR'] = '/tmp'
    tempfile.tempdir = None
    generations = {}
    for (backend, variant), source in zip(((b, v) for b in BACKENDS for v in VARIANTS), sys.argv[1:]):
        target = Path('/data/generations') / f'{backend}-{variant}'
        shutil.copytree(source, target, symlinks=True)
        generations[(backend, variant)] = target
    for backend in BACKENDS:
        if os.environ.get('NNS_TEST_BACKEND', backend) != backend:
            continue
        case = type(backend + 'ServiceManagerTest', (ServiceManagerTest,), {'backend': backend, 'generations': generations})
        loader = unittest.TestLoader()
        if os.environ.get('NNS_TEST_CASE'):
            loader.testNamePatterns = ['*' + os.environ['NNS_TEST_CASE'] + '*']
        suite = loader.loadTestsFromTestCase(case)
        # The intentional loss case leaves cleanup to namespace termination.
        ordered = sorted(suite, key=lambda test: test.id().endswith('.test_unrecoverable_manager_exit_refuses_takeover'))
        result = unittest.TextTestRunner(verbosity=2, failfast=True).run(unittest.TestSuite(ordered))
        if not result.wasSuccessful():
            raise SystemExit(1)


if __name__ == '__main__':
    main()
