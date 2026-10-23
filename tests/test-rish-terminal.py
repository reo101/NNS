#!/usr/bin/env python3
"""Exercise the native terminal transport without Android or Shizuku."""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

helper = os.path.abspath(sys.argv[1])


def frame(kind, payload=b""):
    return struct.pack(">BI", kind, len(payload)) + payload


def window(rows, columns):
    return frame(2, struct.pack(">HHHH", rows, columns, 0, 0))


def host(command, data=None, mask=0):
    if data is None:
        data = (window(28, 88) if mask else b"") + frame(3)
    return subprocess.run([helper, "--host", str(mask), "-c", command], input=data,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=6)


def read_exact(stream, size):
    result = b""
    deadline = time.monotonic() + 4
    while len(result) < size:
        assert select.select([stream], [], [], max(0, deadline - time.monotonic()))[0], "read timeout"
        chunk = os.read(stream.fileno(), size - len(result))
        assert chunk, "unexpected EOF"
        result += chunk
    return result


def packet(stream):
    kind, size = struct.unpack(">BI", read_exact(stream, 5))
    return kind, read_exact(stream, size)


for status in (0, 7, 42, 255):
    result = host(f"exit {status}")
    assert (result.returncode, result.stdout, result.stderr) == (status, b"", b""), result
result = host("printf out; printf err >&2; exit 7")
assert (result.returncode, result.stdout, result.stderr) == (7, b"out", b"err"), result
assert host("kill -TERM $$").returncode == 143
assert host("exec 1>&-; sleep 0.2; exit 7").returncode == 7
assert host("read value; printf %s \"$value\"", frame(1, b"input\n") + frame(3)).stdout == b"input"
data = b"x" * 150_000
wire = b"".join(frame(1, data[offset:offset + 4096]) for offset in range(0, len(data), 4096)) + frame(3)
assert host("cat", wire).stdout == data

for mask in range(1, 8):
    result = host("stty size </dev/tty; printf TTY; exit 7", mask=mask)
    assert result.returncode == 7, result
    combined = result.stdout + result.stderr
    assert b"28 88" in combined and b"TTY" in combined, result
for _ in range(40):
    result = host("printf TTY; exit 7", mask=7)
    assert (result.returncode, result.stdout, result.stderr) == (7, b"TTY", b""), result

process = subprocess.Popen([helper, "--host", "7", "-c", "printf ready; read value; stty size; exit 7"],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
process.stdin.write(window(28, 88))
process.stdin.flush()
assert read_exact(process.stdout, 5) == b"ready"
process.stdin.write(window(40, 100) + frame(1, b"continue\n") + frame(3))
process.stdin.flush()
stdout, stderr = process.communicate(timeout=5)
assert process.returncode == 7 and b"40 100" in stdout, (stdout, stderr)

master, slave = pty.openpty()
original = termios.tcgetattr(slave)
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 28, 88, 0, 0))
process = subprocess.Popen([helper, "--input", "7", os.ttyname(slave)], stdin=slave,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    assert packet(process.stdout) == (2, struct.pack(">HHHH", 28, 88, 0, 0))
    assert not termios.tcgetattr(slave)[3] & termios.ICANON
    os.write(master, b"A")
    assert packet(process.stdout) == (1, b"A")
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
    process.send_signal(signal.SIGWINCH)
    assert packet(process.stdout) == (2, struct.pack(">HHHH", 40, 100, 0, 0))
finally:
    process.terminate()
    process.communicate(timeout=4)
    assert termios.tcgetattr(slave) == original
    os.close(master)
    os.close(slave)

result = subprocess.run([helper, "--input", "0", ""], input=b"bytes",
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4)
assert (result.returncode, result.stdout, result.stderr) == (0, frame(1, b"bytes") + frame(3), b""), result
for mask in ("-1", "8", "invalid"):
    result = subprocess.run([helper, "--host", mask], input=b"",
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4)
    assert result.returncode == 2, result
for malformed in (b"\x09\0\0\0\0", frame(1, b""), struct.pack(">BI", 1, 4097), b"\x01\0", frame(2, b"bad")):
    assert host("sleep 2", malformed).returncode != 0

with tempfile.TemporaryDirectory() as directory:
    marker = os.path.join(directory, "child.pid")
    process = subprocess.Popen([helper, "--host", "0", "-c", f"echo $$ > '{marker}'; trap '' TERM; sleep 20"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 3
    while not os.path.exists(marker):
        assert time.monotonic() < deadline
        time.sleep(0.01)
    with open(marker) as source:
        child = int(source.read())
    process.stdin.write(struct.pack(">BI", 1, 4097))
    process.stdin.flush()
    process.communicate(timeout=5)
    assert process.returncode != 0
    try:
        os.kill(child, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("malformed input left the shell alive")

for mask in (0, 7):
    with tempfile.TemporaryDirectory() as directory:
        marker = os.path.join(directory, "background.pid")
        command = (f"sh -c 'trap \"\" TERM HUP; echo $$ > \"{marker}\"; "
                   "while :; do sleep 1; done' & "
                   f"while test ! -s '{marker}'; do sleep 0.01; done; exit 7")
        result = host(command, mask=mask)
        assert result.returncode == 7, result
        with open(marker) as source:
            child = int(source.read())
        try:
            with open(f"/proc/{child}/stat") as source:
                assert source.read().split(") ", 1)[1].startswith("Z "), "background process survived"
        except FileNotFoundError:
            pass

print("PASS: status, signals, separate streams, backpressure, PTYs, resize, raw input, restoration, protocol rejection and process-group cleanup")
