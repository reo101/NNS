"""Prove s6-rc state transitions against real, isolated s6 processes."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

TOOLS = {name: shutil.which(name) for name in (
    "bash", "s6-rc-compile", "s6-rc-init", "s6-svscan", "s6-rc",
)}


@unittest.skipUnless(all(TOOLS.values()), "s6, s6-rc, and bash must be on PATH")
class S6RcTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="nns-s6-rc-")
        self.root = Path(self.temporary_directory.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.transitions = []
        self.compiled = self.root / "compiled"
        self.live = self.root / "live"
        self.scan = self.root / "scan"
        self.scan.mkdir()
        self.supervisor = subprocess.Popen(
            [TOOLS["s6-svscan"], str(self.scan)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        self.wait_for(lambda: (self.scan / ".s6-svscan/control").is_fifo(),
                      "s6-svscan did not become ready")

    def tearDown(self):
        for transition in self.transitions:
            if transition.poll() is None:
                transition.terminate()
                try:
                    transition.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    transition.kill()
                    transition.wait(timeout=2)
        if self.supervisor.poll() is None:
            self.supervisor.send_signal(signal.SIGTERM)
            try:
                self.supervisor.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.supervisor.pid, signal.SIGKILL)
                self.supervisor.wait(timeout=3)
        self.temporary_directory.cleanup()

    def service(self, name, kind, **files):
        directory = self.source / name
        directory.mkdir()
        (directory / "type").write_text(kind + "\n")
        for filename, content in files.items():
            path = directory / filename
            if filename == "contents.d" or filename == "dependencies.d":
                path.mkdir()
                for service_name in content:
                    (path / service_name).touch()
            else:
                path.write_text(content)
                if filename in ("up", "run"):
                    path.chmod(0o755)
        return directory

    def script(self, name, body):
        path = self.root / name
        path.write_text(f"#!{TOOLS['bash']}\n{body}")
        path.chmod(0o755)
        return str(path) + "\n"

    def compile(self):
        result = subprocess.run(
            [TOOLS["s6-rc-compile"], str(self.compiled), str(self.source)],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def initialize(self):
        result = subprocess.run(
            [TOOLS["s6-rc-init"], "-c", str(self.compiled), "-l", str(self.live), str(self.scan)],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def change(self, *arguments, timeout=10):
        return subprocess.run(
            [TOOLS["s6-rc"], "-l", str(self.live), *arguments],
            capture_output=True, text=True, timeout=timeout,
        )

    def wait_for(self, predicate, message, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail(message)

    def test_compile_rejects_dependency_cycle(self):
        self.service("first", "oneshot", up="true\n", **{"dependencies.d": ["second"]})
        self.service("second", "oneshot", up="true\n", **{"dependencies.d": ["first"]})
        result = subprocess.run(
            [TOOLS["s6-rc-compile"], str(self.compiled), str(self.source)],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("cyclic", result.stderr.lower())

    def test_failed_oneshot_blocks_dependent_and_retry_does_not_repeat_success(self):
        gate = self.root / "release-failure"
        failure_log = self.root / "failure.log"
        independent_log = self.root / "independent.log"
        dependent_log = self.root / "dependent.log"
        self.service(
            "failing", "oneshot",
            up=self.script("failing.sh", f"printf 'attempt\\n' >> '{failure_log}'\ntest -e '{gate}'\n"),
        )
        self.service("independent", "oneshot",
                     up=self.script("independent.sh", f"printf 'ran\\n' >> '{independent_log}'\n"))
        self.service("dependent", "oneshot",
                     up=self.script("dependent.sh", f"printf 'ran\\n' >> '{dependent_log}'\n"),
                     **{"dependencies.d": ["failing"]})
        self.service("bundle", "bundle", **{"contents.d": ["dependent", "independent"]})
        self.compile()
        self.initialize()

        failed = self.change("-u", "change", "bundle")
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertEqual(independent_log.read_text().splitlines(), ["ran"])
        self.assertFalse(dependent_log.exists())

        gate.touch()
        retried = self.change("-u", "change", "bundle")
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertEqual(failure_log.read_text().splitlines(), ["attempt", "attempt"])
        self.assertEqual(dependent_log.read_text().splitlines(), ["ran"])

        repeated = self.change("-u", "change", "bundle")
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(failure_log.read_text().splitlines(), ["attempt", "attempt"])
        self.assertEqual(independent_log.read_text().splitlines(), ["ran"])
        self.assertEqual(dependent_log.read_text().splitlines(), ["ran"])

    def test_longrun_readiness_holds_dependent_after_process_starts(self):
        ready = self.root / "ready"
        started = self.root / "started"
        dependent_log = self.root / "dependent.log"
        run = (
            f"#!{TOOLS['bash']}\n"
            f"touch '{started}'\n"
            f"while test ! -e '{ready}'; do sleep 0.02; done\n"
            "printf '\\n' >&3\n"
            "exec 3>&-\n"
            "exec sleep 30\n"
        )
        self.service("daemon", "longrun", run=run, **{"notification-fd": "3\n"})
        self.service("dependent", "oneshot",
                     up=self.script("dependent.sh", f"printf 'ran\\n' >> '{dependent_log}'\n"),
                     **{"dependencies.d": ["daemon"]})
        self.service("bundle", "bundle", **{"contents.d": ["dependent"]})
        self.compile()
        self.initialize()

        transition = subprocess.Popen(
            [TOOLS["s6-rc"], "-l", str(self.live), "-u", "change", "bundle"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.transitions.append(transition)
        self.wait_for(lambda: started.exists(), "longrun process did not start")
        time.sleep(0.2)
        self.assertIsNone(transition.poll(), "transition completed before readiness")
        self.assertFalse(dependent_log.exists(), "dependent ran before readiness")

        ready.touch()
        stdout, stderr = transition.communicate(timeout=8)
        self.assertEqual(transition.returncode, 0, stderr or stdout)
        self.assertEqual(dependent_log.read_text().splitlines(), ["ran"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
