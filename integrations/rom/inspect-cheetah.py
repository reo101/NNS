#!/usr/bin/env python3
"""Inspect image contents read-only; this is not a boot or hardware test."""

import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile

SYNC = runpy.run_path(str(Path(__file__).with_name("sync-cheetah.py")))


def debugfs(image, request):
    return subprocess.check_output(["debugfs", "-R", request, str(image)],
                                   env=dict(os.environ, DEBUGFS_PAGER="cat"), text=True)


def check_inode(image, path, kind, context, temporary, gid):
    metadata = debugfs(image, f"stat {path}")
    if not re.search(rf"Type:\s+{kind}\s+Mode:\s+0755\b", metadata):
        raise RuntimeError(f"Image inode has wrong type or mode: {path}")
    if not re.search(rf"User:\s+0\s+Group:\s+{gid}\b", metadata):
        raise RuntimeError(f"Image inode ownership is not 0:{gid}: {path}")
    attribute = temporary / "context"
    attribute.unlink(missing_ok=True)
    debugfs(image, f'ea_get -f "{attribute}" {path} security.selinux')
    if attribute.read_bytes().rstrip(b"\0") != context.encode():
        raise RuntimeError(f"Image inode has wrong SELinux context: {path}")


def inspect_images(directory, output_name="out-cheetah", device="cheetah"):
    output = directory / output_name
    product = output / "target/product" / device
    SYNC["require_space"](directory)
    with tempfile.TemporaryDirectory(prefix="image-inspection-", dir=directory / "temporary") as temporary:
        temporary = Path(temporary)
        images = {}
        for name in ("system", "system_ext"):
            image = product / f"{name}.img"
            with image.open("rb") as stream:
                sparse = stream.read(4) == b"\x3a\xff\x26\xed"
            if sparse:
                raw = temporary / f"{name}.raw"
                SYNC["run"]([str(output / "host/linux-x86/bin/simg2img"), str(image), str(raw)],
                            directory, dict(os.environ))
                image = raw
            images[name] = image
        check_inode(images["system"], "/nix", "directory", "u:object_r:system_data_file:s0", temporary, gid=0)
        entries = debugfs(images["system"], "ls -p /nix").splitlines()
        names = {line.split("/")[5] for line in entries if line.startswith("/")}
        if names != {".", ".."}:
            raise RuntimeError("Image /nix is not an empty directory")
        check_inode(images["system"], "/system/bin/nns-mount", "regular",
                    "u:object_r:nns_mount_exec:s0", temporary, gid=2000)
        check_inode(images["system"], "/system/bin/init", "regular",
                    "u:object_r:init_exec:s0", temporary, gid=2000)
        paths = {
            "system": ("/system/bin/init", "/system/bin/nns-mount", "/system/etc/init/init.nns-mount.rc"),
            "system_ext": ("/etc/selinux/system_ext_sepolicy.cil", "/etc/selinux/system_ext_file_contexts",
                           "/etc/selinux/system_ext_property_contexts", "/etc/build.prop"),
        }
        for name, paths in paths.items():
            for path in paths:
                extracted = temporary / "extracted"
                extracted.unlink(missing_ok=True)
                debugfs(images[name], f'dump {path} "{extracted}"')
                staged = product / path.lstrip("/") if name == "system" else product / name / path.lstrip("/")
                if extracted.read_bytes() != staged.read_bytes():
                    raise RuntimeError(f"Image contents differ from verified build output: {path}")
        if (product / "system_ext/etc/build.prop").read_text().splitlines().count("ro.nns.mount.owner=init") != 1:
            raise RuntimeError("Image lacks the unique ROM mount ownership declaration")
    print("PASS: image /nix metadata/emptiness, init/helper label/mode and packaged binaries/init fragment/policy", flush=True)


if __name__ == "__main__":
    inspect_images(Path(sys.argv[1]).resolve(strict=True))
