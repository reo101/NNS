#!/usr/bin/env python3
"""Test LFS digest checks without a network or Git checkout."""

import hashlib
import json
from pathlib import Path
import runpy
import tempfile
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
verification = runpy.run_path(str(root / "integrations/rom/verify-source-lfs.py"))
commands = []
verification["SYNC"]["download_environment"] = lambda _: {}
verification["SYNC"]["require_space"] = lambda _: None
def run(arguments, *_, **streams):
    commands.append(arguments)
    if arguments[1] == "smudge":
        streams["stdout"].write(content)


verification["SYNC"]["run"] = run

with tempfile.TemporaryDirectory(prefix="nns-rom-lfs-test-") as temporary:
    directory = Path(temporary)
    checkout = directory / "source/prebuilt"
    checkout.mkdir(parents=True)
    (directory / "source-manifest.xml").write_text(
        '<manifest><default remote="github"/><project name="prebuilt" revision="' + "a" * 40 + '"/></manifest>')
    content = b"LFS content fixture\n"
    file = checkout / "fixture"
    file.write_bytes(content)
    files = {"files": [{"name": "fixture", "size": len(content), "oid_type": "sha256",
                        "oid": hashlib.sha256(content).hexdigest()}]}
    with patch("subprocess.check_output", return_value=json.dumps(files)):
        verification["verify_lfs"](directory)
        records = json.loads((directory / "source-lfs.json").read_text())
        assert records[0]["path"] == "prebuilt"
        assert commands[1] == ["git-lfs", "fetch", "github", "a" * 40]
        assert records[0]["objects"][0]["oid"] == hashlib.sha256(content).hexdigest()
        file.unlink()
        verification["verify_lfs"](directory)
        assert file.read_bytes() == content
        assert any(command[1] == "smudge" for command in commands)
        file.write_bytes(b"X" * len(content))
        try:
            verification["verify_lfs"](directory)
        except RuntimeError as error:
            assert "digest mismatch" in str(error)
        else:
            raise AssertionError("Wrong LFS object was accepted")

    before = len(commands)
    with patch("subprocess.check_output", side_effect=[json.dumps(files), ""]):
        verification["verify_lfs"](directory)
    assert len(commands) == before
    assert json.loads((directory / "source-lfs.json").read_text()) == []

print("PASS: locked LFS fetch, missing-file recovery, corruption refusal and unfiltered pointer exclusion")
