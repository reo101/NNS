#!/usr/bin/env python3
"""Materialize and verify LFS objects from the resolved source manifest."""

import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SYNC = runpy.run_path(str(Path(__file__).with_name("sync-cheetah.py")))


def verify_lfs(directory):
    environment = SYNC["download_environment"](directory)
    manifest = ET.parse(directory / "source-manifest.xml").getroot()
    default = manifest.find("default")
    records = []
    for project in manifest.findall("project"):
        path = project.get("path", project.get("name"))
        checkout = directory / "source" / path
        revision = project.get("revision")
        SYNC["require_space"](directory)
        files = json.loads(subprocess.check_output(
            ["git-lfs", "ls-files", "--json", revision], cwd=checkout,
            env=environment, text=True))["files"]
        if not files:
            continue
        # Some source trees contain literal pointer fixtures without an LFS
        # filter. They are Git content, not objects to expand or download.
        tracking = subprocess.check_output(["git-lfs", "track"], cwd=checkout,
                                           env=environment, text=True)
        if not tracking.strip():
            continue
        remote = project.get("remote") or default.get("remote")
        print(f"Verifying {len(files)} LFS objects: {path}", flush=True)
        SYNC["run"](["git-lfs", "install", "--local", "--force"], checkout, environment)
        SYNC["run"](["git-lfs", "fetch", remote, revision], checkout, environment)
        SYNC["run"](["git-lfs", "checkout"], checkout, environment)
        objects = []
        for entry in files:
            file = checkout / entry["name"]
            if not file.exists():
                # An interrupted initial checkout can leave the index incomplete;
                # LFS checkout/pull then silently omit files that still exist in HEAD.
                pointer = (f'version https://git-lfs.github.com/spec/v1\n'
                           f'oid sha256:{entry["oid"]}\nsize {entry["size"]}\n').encode()
                file.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryFile() as source, file.open("xb") as output:
                    source.write(pointer)
                    source.seek(0)
                    try:
                        SYNC["run"](["git-lfs", "smudge", "--", entry["name"]], checkout, environment,
                                    stdin=source, stdout=output)
                    except BaseException:
                        file.unlink()
                        raise
            if entry["oid_type"] != "sha256" or file.stat().st_size != entry["size"]:
                raise RuntimeError(f"LFS object has wrong format or size: {file}")
            with file.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            if digest != entry["oid"]:
                raise RuntimeError(f"LFS object digest mismatch: {file}")
            objects.append({key: entry[key] for key in ("name", "size", "oid")})
        records.append({"path": path, "revision": revision, "objects": objects})
    (directory / "source-lfs.json").write_text(json.dumps(records, indent=2) + "\n")
    print(f"PASS: verified LFS objects in {len(records)} source projects", flush=True)


if __name__ == "__main__":
    verify_lfs(Path(sys.argv[1]).resolve(strict=True))
