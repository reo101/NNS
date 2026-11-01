#!/usr/bin/env python3
"""Run the VM-only enforcing fixture service through authenticated ADB."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("action", choices=("inspect", "prepare-encrypted", "restart-mount"))
parser.add_argument("--adb", required=True)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--baseline", type=Path)
arguments = parser.parse_args()
if arguments.output.exists():
    parser.error("Refusing to overwrite an existing observation")
if arguments.baseline and arguments.action == "prepare-encrypted":
    parser.error("Preparation cannot compare an existing observation")
baseline = json.loads(arguments.baseline.read_text()) if arguments.baseline else None
server_socket = os.environ.get("ADB_SERVER_SOCKET", "")
if not server_socket.startswith("localfilesystem:/tmp/nns-cuttlefish-runtime-"):
    parser.error("An isolated NNS VM ADB server socket is required")


def adb(*command, check=True):
    return subprocess.run([arguments.adb, "-s", "vsock:3:5555", *command],
                          check=check, capture_output=True, text=True, timeout=15)


assert adb("get-state").stdout.strip() == "device"
assert adb("shell", "getprop", "ro.serialno").stdout.strip() == "CUTTLEFISHCVD01"
assert adb("shell", "getenforce").stdout.strip() == "Enforcing"


def read_report():
    result = adb("shell", "cat", "/data/nns-fixture/report.json", check=False)
    if result.returncode:
        return None
    return json.loads(result.stdout)


previous = read_report()
adb("shell", "setprop", "sys.nns.fixture.action", arguments.action)
deadline = time.monotonic() + 30
while True:
    report = read_report()
    if (report and report.get("action") == arguments.action and
            (previous is None or report["record_time_ns"] != previous["record_time_ns"])):
        break
    if time.monotonic() >= deadline:
        raise RuntimeError("Fixture service did not publish a new report")
    time.sleep(0.25)
mount_records = adb("shell", "cat", "/proc/self/mountinfo").stdout.splitlines()
report["adb_mountinfo"] = [line for line in mount_records if line.split()[4] == "/nix"]
with arguments.output.open("x") as output:
    output.write(json.dumps(report, indent=2) + "\n")
assert report["selinux_enforcing"] is True
assert report["domain"] == "u:r:nns_fixture:s0"
assert report["mount_count"] == 1
backing, target = report["backing"], report["target"]
assert backing == target, "Bind identity, flags, policy or metadata differ"
assert len(report["adb_mountinfo"]) == 1, "Bind is not visible in the ADB shell namespace"
mount_fields = report["adb_mountinfo"][0].split()
assert mount_fields[2] == f'{os.major(backing["device"])}:{os.minor(backing["device"])}'
assert mount_fields[3] == "/nix", "ADB sees a different backing directory"
observed_flags = set(mount_fields[5].split(","))
assert sum(value for name, value in (("ro", 1), ("nosuid", 2), ("nodev", 4), ("noexec", 8))
           if name in observed_flags) == backing["mount_flags"]
if arguments.action == "prepare-encrypted":
    assert backing["uid"] == backing["gid"] == 12345
    assert backing["mode"] == "0715"
    assert backing["fscrypt_policy_hex"], "No real encryption policy was observed"
    assert backing["fscrypt_policy_hex"][:2] in ("00", "02")
    assert backing["user_xattr_hex"] == b"nns-fixture-v1".hex()
    fixture = report["fixture_file"]
    assert fixture["uid"] == fixture["gid"] == 12345
    assert fixture["mode"] == "0715"
    assert fixture["user_xattr_hex"] == b"nns-fixture-v1".hex()
    assert fixture["sha256"] == hashlib.sha256(b"NNS encrypted backing fixture v1\n").hexdigest()
if baseline:
    for field in ("backing", "target", "fixture_file"):
        before, after = baseline[field], report[field]
        if before is None or after is None:
            assert before == after, field
            continue
        # Device numbers can change across boots; current bind identity is checked above.
        assert {key: value for key, value in before.items() if key != "device"} == {
            key: value for key, value in after.items() if key != "device"}, field
print("PASS: enforcing init fixture report, bind identity and requested preservation checks")
