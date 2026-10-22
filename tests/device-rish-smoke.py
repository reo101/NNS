#!/usr/bin/env python3
"""Check Shizuku streams and terminal behavior through a NoD SSH session."""
import argparse
import fcntl
import os
import pty
import select
import shlex
import signal
import struct
import subprocess
import termios
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--host", default="nix-on-droid@192.168.1.217")
parser.add_argument("--port", default="8022")
parser.add_argument("--rish", default="/data/nix/var/nns/bin/rish")
arguments = parser.parse_args()
ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-p", arguments.port, arguments.host]
launcher = ["/data/nix/bin/nix-enter", "--userns", "--", "/system/bin/sh", arguments.rish]


def batch(command, data=b""):
    return subprocess.run(ssh + [shlex.join(launcher + ["-c", command])], input=data,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)


for command, status, stdout, stderr in [
    ("true", 0, b"", b""),
    ("exit 7", 7, b"", b""),
    ("printf out; printf err >&2; exit 7", 7, b"out", b"err"),
    ("kill -TERM $$", 143, b"", b""),
    ("exec 1>&-; sleep 0.2; exit 7", 7, b"", b""),
]:
    result = batch(command)
    assert (result.returncode, result.stdout, result.stderr) == (status, stdout, stderr), result
result = batch('read value; printf "%s" "$value"', b"input\n")
assert (result.returncode, result.stdout, result.stderr) == (0, b"input", b""), result


def terminal(command, action, marker=b"READY"):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 120, 0, 0))
    process = subprocess.Popen(ssh[:1] + ["-tt"] + ssh[1:] + ["exec " + shlex.join(launcher + ["-c", command])],
                               stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
                               preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
    os.close(slave)
    output = b""
    deadline = time.monotonic() + 15
    acted = False
    try:
        while process.poll() is None or select.select([master], [], [], 0)[0]:
            assert time.monotonic() < deadline, output
            if not select.select([master], [], [], 0.2)[0]:
                continue
            try:
                data = os.read(master, 65536)
            except OSError as error:
                if error.errno == 5:
                    break
                raise
            if not data:
                break
            output += data
            if marker in output and not acted:
                action(master, process)
                acted = True
        status = process.wait(timeout=3)
        assert acted, output
        return status, output
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        os.close(master)


def resize_and_input(master, process):
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 55, 132, 0, 0))
    process.send_signal(signal.SIGWINCH)
    time.sleep(0.5)
    os.write(master, b"value\n")


status, output = terminal('set -e; test -t 0; test -t 1; test -t 2; id -u; stty size; printf READY; read value; stty size; printf "VALUE=%s\\n" "$value"; exit 7', resize_and_input)
assert status == 7 and b"36 120" in output and b"55 132" in output and b"VALUE=value" in output, (status, output)
status, output = terminal('trap "printf INTERRUPTED; exit 42" INT; printf READY; while :; do sleep 1; done',
                          lambda master, process: os.write(master, b"\x03"))
assert status == 42 and b"INTERRUPTED" in output, (status, output)
print("PASS: quiet status, separate streams, stdin, signals, early stdout close, terminal dimensions, resize and Ctrl-C")
