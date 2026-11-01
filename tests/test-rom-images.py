#!/usr/bin/env python3
"""Exercise the read-only inspector on disposable ext4 images, not a ROM build."""

import hashlib
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
inspection = runpy.run_path(str(root / "integrations/rom/inspect-cheetah.py"))


def modify(image, request):
    subprocess.run(["debugfs", "-w", "-R", request, str(image)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


with tempfile.TemporaryDirectory(prefix="nns-rom-image-test-") as temporary:
    directory = Path(temporary)
    (directory / "temporary").mkdir()
    product = directory / "out-cheetah/target/product/cheetah"
    contents = {
        "system/bin/nns-mount": b"image-inspection fixture, not an executable\n",
        "system/bin/init": b"init image-inspection fixture, not an executable\n",
        "system/etc/init/init.nns-mount.rc": (root / "integrations/rom/init.nns-mount.rc").read_bytes(),
        "system_ext/etc/selinux/system_ext_sepolicy.cil": b"image-inspection policy fixture\n",
        "system_ext/etc/selinux/system_ext_file_contexts": b"image-inspection contexts fixture\n",
        "system_ext/etc/selinux/system_ext_property_contexts": (
            root / "integrations/rom/sepolicy/property_contexts").read_bytes(),
        "system_ext/etc/build.prop": b"ro.nns.mount.owner=init\n",
    }
    for relative, content in contents.items():
        path = product / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    system = directory / "system-tree"
    system.mkdir()
    (system / "nix").mkdir()
    shutil.copytree(product / "system", system / "system")
    for name in ("init", "nns-mount"):
        (system / "system/bin" / name).chmod(0o755)
    for name, tree in (("system", system), ("system_ext", product / "system_ext")):
        image = product / f"{name}.img"
        with image.open("wb") as stream:
            stream.truncate(16 * 1024**2)
        subprocess.run(["mke2fs", "-q", "-F", "-t", "ext4", "-d", str(tree), str(image)], check=True)
    image = product / "system.img"
    for path, context in (("/nix", "u:object_r:system_data_file:s0"),
                          ("/system/bin/nns-mount", "u:object_r:nns_mount_exec:s0"),
                          ("/system/bin/init", "u:object_r:init_exec:s0")):
        modify(image, f"set_inode_field {path} uid 0")
        modify(image, f"set_inode_field {path} gid {0 if path == '/nix' else 2000}")
        attribute = directory / "context"
        attribute.write_bytes(context.encode() + b"\0")
        modify(image, f'ea_set -f "{attribute}" {path} security.selinux')
    images = [product / "system.img", product / "system_ext.img"]
    hashes = {path: hashlib.sha256(path.read_bytes()).digest() for path in images}
    inspection["inspect_images"](directory)
    assert all(hashlib.sha256(path.read_bytes()).digest() == digest for path, digest in hashes.items())
    raw = directory / "system.raw"
    shutil.copyfile(image, raw)
    subprocess.run(["img2simg", str(raw), str(image)], check=True)
    converter = directory / "out-cheetah/host/linux-x86/bin/simg2img"
    converter.parent.mkdir(parents=True)
    converter.symlink_to(shutil.which("simg2img"))
    hashes = {path: hashlib.sha256(path.read_bytes()).digest() for path in images}
    inspection["inspect_images"](directory)
    assert all(hashlib.sha256(path.read_bytes()).digest() == digest for path, digest in hashes.items())
    virtual_output = directory / "out-cuttlefish"
    (directory / "out-cheetah").rename(virtual_output)
    (virtual_output / "target/product/cheetah").rename(virtual_output / "target/product/vsoc_x86_64")
    inspection["inspect_images"](directory, "out-cuttlefish", "vsoc_x86_64")
    (virtual_output / "target/product/vsoc_x86_64").rename(virtual_output / "target/product/cheetah")
    virtual_output.rename(directory / "out-cheetah")
    shutil.copyfile(raw, image)
    for path, gid in (("/nix", 0), ("/system/bin/nns-mount", 2000), ("/system/bin/init", 2000)):
        for field, invalid, correct in (("uid", 2000, 0), ("gid", 2000 if gid == 0 else 0, gid)):
            modify(image, f"set_inode_field {path} {field} {invalid}")
            try:
                inspection["inspect_images"](directory)
            except RuntimeError as error:
                assert "ownership" in str(error)
            else:
                raise AssertionError(f"Wrong image {field} was accepted: {path}")
            modify(image, f"set_inode_field {path} {field} {correct}")
    modify(image, "set_inode_field /nix mode 040700")
    try:
        inspection["inspect_images"](directory)
    except RuntimeError as error:
        assert "mode" in str(error)
    else:
        raise AssertionError("Wrong image mountpoint mode was accepted")
    modify(image, "set_inode_field /nix mode 040755")
    modify(image, "ea_set /nix security.selinux u:object_r:rootfs:s0")
    try:
        inspection["inspect_images"](directory)
    except RuntimeError as error:
        assert "SELinux context" in str(error)
    else:
        raise AssertionError("Wrong image mountpoint label was accepted")
    attribute.write_bytes(b"u:object_r:system_data_file:s0\0")
    modify(image, f'ea_set -f "{attribute}" /nix security.selinux')
    properties = product / "system_ext/etc/build.prop"
    property_image = product / "system_ext.img"
    original_properties = properties.read_bytes()
    for invalid in (b"", b"ro.nns.mount.owner=init\nro.nns.mount.owner=init\n"):
        properties.write_bytes(invalid)
        modify(property_image, "rm /etc/build.prop")
        modify(property_image, f'write "{properties}" /etc/build.prop')
        try:
            inspection["inspect_images"](directory)
        except RuntimeError as error:
            assert "ownership declaration" in str(error)
        else:
            raise AssertionError("Missing or duplicate mount ownership declaration was accepted")
    properties.write_bytes(original_properties)
    modify(property_image, "rm /etc/build.prop")
    modify(property_image, f'write "{properties}" /etc/build.prop')
    fixture = directory / "occupied"
    fixture.write_bytes(b"occupied target\n")
    modify(image, f'write "{fixture}" /nix/occupied')
    try:
        inspection["inspect_images"](directory)
    except RuntimeError as error:
        assert "empty directory" in str(error)
    else:
        raise AssertionError("Occupied image mountpoint was accepted")

print("PASS: read-only raw/sparse ext4 inspection; wrong ownership/mode/label and occupied /nix refused")
