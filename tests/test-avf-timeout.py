"""Run the AVF polling loops and entry point with fake VM state and time."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path(__file__).resolve().parents[1] / 'integrations/avf/VirtualMachineClient.kt'
)


class VirtualMachineTimeoutTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = SOURCE.read_text()
        entry_start = source.index('    @JvmStatic')
        entry_end = source.index('    private fun execute(', entry_start)
        framework_start = source.index('        var sawRunning = false')
        framework_end = source.index('    /** Attach an external vhost-user backend')
        backend_start = source.index('    private fun runWithFilesystemBackend(')
        monitor_start = source.index('            val deadline =', backend_start)
        monitor_end = source.index('    private fun buildPayloadImage(', monitor_start)
        # Compile the production loops, cleanup, timeout checks, and entry point.
        # Android binder/socket setup is replaced; no device or real VM is used.
        harness = '''
object Clock {
    private var time = 0L
    fun now() = time
    fun advance() { time += 300_000 }
}
class VirtualMachine(private val mode: String) {
    private var polls = 0
    fun getStatus(): Int {
        polls++
        return if (mode == "stopped" && polls > 1) 0 else 1
    }
    fun getState() = if (getStatus() == 0) 6 else 2
    fun stop() { println("STOP") }
}
class Pipe {
    fun close() { println("CLOSE") }
}
object VirtualMachineClient {
@ENTRY_POINT@
    private fun execute(arguments: Array<String>) {
        if (arguments[0] == "framework") runFramework(arguments[1])
        else runFilesystem(arguments[1])
    }
    private fun runFramework(mode: String) {
        val vm = VirtualMachine(mode)
        val vmDirectory = java.io.File(".")
        val console = Unit
        val logs = Unit
@FRAMEWORK_MONITOR@
    private fun runFilesystem(mode: String) {
        val instance: Any = VirtualMachine(mode)
        val instanceType = VirtualMachine::class.java
        val consolePipe = arrayOf(Pipe(), Pipe())
        val logPipe = arrayOf(Pipe(), Pipe())
        val console = Unit
        val logs = Unit
        var running = true
        var timedOut = true
        try {
@MONITOR@
    private fun drain(stream: Unit, label: String) = Unit
}
'''.replace('@ENTRY_POINT@', source[entry_start:entry_end]).replace(
            '@FRAMEWORK_MONITOR@', source[framework_start:framework_end]
        ).replace('@MONITOR@', source[monitor_start:monitor_end]).replace(
            'System.currentTimeMillis()', 'Clock.now()'
        ).replace('Thread.sleep(500)', 'Clock.advance()').replace(
            'Thread.sleep(2_000)', 'Clock.advance()'
        )
        cls.directory = tempfile.TemporaryDirectory(prefix='nns-avf-timeout-')
        cls.addClassCleanup(cls.directory.cleanup)
        directory = Path(cls.directory.name)
        program = directory / 'VirtualMachineTimeoutTest.kt'
        program.write_text(harness)
        cls.archive = directory / 'test.jar'
        compiled = subprocess.run(
            ['kotlinc', str(program), '-include-runtime', '-d', str(cls.archive)],
            capture_output=True, text=True,
        )
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def run_monitor(self, backend, mode):
        return subprocess.run(
            ['java', '-jar', str(self.archive), backend, mode],
            capture_output=True, text=True, timeout=10,
        )

    def test_natural_shutdown_succeeds_without_stop(self):
        for backend in ('framework', 'filesystem'):
            with self.subTest(backend=backend):
                result = self.run_monitor(backend, 'stopped')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('STOP', result.stdout)
                closed = 4 if backend == 'filesystem' else 0
                self.assertEqual(result.stdout.splitlines().count('CLOSE'), closed)

    def test_timeout_fails_after_cleanup(self):
        for backend in ('framework', 'filesystem'):
            with self.subTest(backend=backend):
                result = self.run_monitor(backend, 'timeout')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('timed out', result.stderr)
                cleanup = [line for line in result.stdout.splitlines() if line in ('STOP', 'CLOSE')]
                closed = 4 if backend == 'filesystem' else 0
                self.assertEqual(cleanup, ['STOP'] + ['CLOSE'] * closed)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
