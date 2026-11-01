#!/usr/bin/env python3
"""Build Cheetah helper/policy, then images, without deploying anything."""

import hashlib
import json
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

INTEGRATION = Path(__file__).resolve().parent
SYNC = runpy.run_path(str(INTEGRATION / "sync-cheetah.py"))
FILES = (
    "Android.bp", "BoardConfig.mk", "product.mk", "init.nns-mount.rc",
    "nns-mount.c", "nns-backing.c", "nns-backing.h", "nns-init.inc",
    "sepolicy/file_contexts", "sepolicy/nns_mount.te", "sepolicy/property_contexts",
)
MODULE_PATH = "external/nns-rom"


def wait_for_source(directory):
    command = ["/run/current-system/sw/bin/systemctl", "--user"]
    print("Waiting for nns-rom-source-sync.service to finish", flush=True)
    while subprocess.run(command + ["is-active", "--quiet", "nns-rom-source-sync.service"]).returncode == 0:
        SYNC["require_space"](directory)
        time.sleep(15)
    if subprocess.run(command + ["is-failed", "--quiet", "nns-rom-source-sync.service"]).returncode == 0:
        raise RuntimeError("Source sync failed; compilation has not started")
    return validate_manifest(directory / "source-manifest.xml")


def validate_manifest(path):
    projects = ET.parse(path).getroot().findall("project")
    revisions = {project.get("path", project.get("name")): project.get("revision") for project in projects}
    if not projects or not all(revisions) or len(revisions) != len(projects):
        raise RuntimeError("Resolved source manifest is empty or has duplicate paths")
    if any(not re.fullmatch(r"[0-9a-f]{40}", revision or "") for revision in revisions.values()):
        raise RuntimeError("Source manifest still contains unresolved revisions")
    for project in ET.parse(INTEGRATION / "cheetah-source.xml").getroot():
        if revisions.get(project.get("path")) != project.get("revision"):
            raise RuntimeError(f"Source revision mismatch: {project.get('path')}")
    return revisions


def install_init_extension(source, specifications):
    hashes = {}
    for relative, specification in specifications.items():
        path = source / relative
        original = path.read_text()
        for previous, replacement in specification["replacements"]:
            original = original.replace(replacement, previous)
        if hashlib.sha256(original.encode()).hexdigest() != specification["sha256"]:
            raise RuntimeError(f"Init source differs from the reviewed baseline: {relative}")
        updated = original
        for previous, replacement in specification["replacements"]:
            if updated.count(previous) != 1:
                raise RuntimeError(f"Init extension anchor is not unique: {relative}")
            updated = updated.replace(previous, replacement)
        path.write_text(updated)
        hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def install_integration(directory):
    source = directory / "source"
    destination = source / MODULE_PATH
    hashes = {}
    for relative in FILES:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(INTEGRATION / relative, target)
        hashes[relative] = hashlib.sha256(target.read_bytes()).hexdigest()
    includes = {
        "device/google/pantah/cheetah/BoardConfig.mk":
            f"NNS_ROM_PATH := {MODULE_PATH}\ninclude $(NNS_ROM_PATH)/BoardConfig.mk",
        "device/google/pantah/lineage_cheetah.mk":
            f"$(call inherit-product,{MODULE_PATH}/product.mk)",
    }
    for relative, addition in includes.items():
        path = source / relative
        original = path.read_text()
        if addition not in original:
            path.write_text(original + "\n" + addition + "\n")
        hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    exclusions = json.loads((INTEGRATION / "cheetah-overlay-exclusions.json").read_text())
    for name, expected_hash in exclusions.items():
        overlay = f"vendor/pixel-style/rro_overlays/{name}/Android.bp"
        path = source / overlay
        replacement = f"// Cheetah validation uses the device/google/gs201 {name}.\n"
        if not (source / f"device/google/gs201/overlay/{name}/Android.bp").is_file():
            raise RuntimeError(f"Device overlay counterpart is missing: {name}")
        if path.read_text() != replacement:
            if hashlib.sha256(path.read_bytes()).hexdigest() != expected_hash:
                raise RuntimeError(f"Conflicting generic overlay differs from the reviewed baseline: {name}")
            path.write_text(replacement)
        hashes[overlay] = hashlib.sha256(path.read_bytes()).hexdigest()
    hashes.update(install_init_extension(source, json.loads((INTEGRATION / "init-extension.json").read_text())))
    for name in ("source-manifest.xml", "source-lfs.json"):
        hashes[name] = hashlib.sha256((directory / name).read_bytes()).hexdigest()
    for relative in ("flake.lock", "nix/rom-build-environment.nix",
                     "integrations/rom/build-cheetah.py", "integrations/rom/sync-cheetah.py",
                     "integrations/rom/inspect-cheetah.py", "integrations/rom/verify-source-lfs.py",
                     "integrations/rom/cheetah-source.xml", "integrations/rom/cheetah-overlay-exclusions.json",
                     "integrations/rom/init-extension.json"):
        hashes[relative] = hashlib.sha256((INTEGRATION.parents[1] / relative).read_bytes()).hexdigest()
    (directory / "build-inputs.json").write_text(json.dumps(hashes, indent=2) + "\n")


def prepare_output(directory, name):
    output = directory / name
    output_link = directory / "source" / name
    if output_link.exists() or output_link.is_symlink():
        if output_link.resolve() != output:
            raise RuntimeError("Source output path conflicts with the build workspace")
    output.mkdir(exist_ok=True)
    if not output_link.exists():
        output_link.symlink_to(f"../{name}", target_is_directory=True)
    return output


def validate_configuration(output, product_name="lineage_cheetah", device="cheetah"):
    variables = json.loads((output / f"soong/soong.{product_name}.variables").read_text())
    if variables.get("DeviceName") != device:
        raise RuntimeError(f"Build configuration does not target {device}")
    if variables.get("SelinuxIgnoreNeverallows", False):
        raise RuntimeError("Neverallow checks were disabled; images will not be built")
    if f"{MODULE_PATH}/sepolicy" not in variables.get("SystemExtPrivateSepolicyDirs", []):
        raise RuntimeError("NNS policy directory was not passed to Soong")


def validate_compilation(output, product_name="lineage_cheetah", device="cheetah", elf_machine=183):
    validate_configuration(output, product_name, device)
    product = output / "target/product" / device
    init = (product / "system/bin/init").read_bytes()
    if b"nns_prepare_backing\0" not in init or b"NNS backing preparation failed" not in init:
        raise RuntimeError("Built init lacks the creation-only NNS builtin")
    helper = (product / "system/bin/nns-mount").read_bytes()
    if helper[:6] != b"\x7fELF\x02\x01" or int.from_bytes(helper[18:20], "little") != elf_machine:
        raise RuntimeError(f"Helper is not an ELF64 executable for machine {elf_machine}")
    headers = subprocess.check_output(["readelf", "-l", str(product / "system/bin/nns-mount")], text=True)
    if "INTERP" in headers:
        raise RuntimeError("Helper unexpectedly requires a dynamic interpreter")
    if (product / "system/etc/init/init.nns-mount.rc").read_bytes() != (INTEGRATION / "init.nns-mount.rc").read_bytes():
        raise RuntimeError("Installed init fragment differs from the integration")
    policy = (product / "system_ext/etc/selinux/system_ext_sepolicy.cil").read_text()
    if "(type nns_mount)" not in policy or "(type nns_mount_owner_prop)" not in policy:
        raise RuntimeError("Compiled system_ext policy lacks NNS mount or property types")
    properties = (product / "system_ext/etc/build.prop").read_text().splitlines()
    if properties.count("ro.nns.mount.owner=init") != 1:
        raise RuntimeError("Built system_ext lacks the unique ROM mount ownership declaration")
    if not re.search(r"\(typetransition\s+init(?:_[0-9]+)?\s+nns_mount_exec\s+process\s+nns_mount\)", policy):
        raise RuntimeError("Compiled policy lacks the init-to-helper domain transition")
    contexts = {tuple(line.split()) for line in
                (product / "system_ext/etc/selinux/system_ext_file_contexts").read_text().splitlines()}
    for line in (INTEGRATION / "sepolicy/file_contexts").read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#") and tuple(line.split()) not in contexts:
            raise RuntimeError(f"Compiled file contexts lack: {line}")
    property_contexts = {tuple(line.split()) for line in
                         (product / "system_ext/etc/selinux/system_ext_property_contexts").read_text().splitlines()}
    for line in (INTEGRATION / "sepolicy/property_contexts").read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#") and tuple(line.split()) not in property_contexts:
            raise RuntimeError(f"Compiled property contexts lack: {line}")
    neverallows = output / "soong/.intermediates/system/sepolicy/sepolicy_neverallows/android_common/policy"
    if not neverallows.is_file() or not neverallows.stat().st_size:
        raise RuntimeError("Neverallow test did not produce its checked binary policy")


def main():
    directory = Path(sys.argv[1]).resolve(strict=True)
    revisions = wait_for_source(directory)
    environment = SYNC["download_environment"](directory)
    build_manifest = directory / "build-source-manifest.xml"
    SYNC["run"](["repo", "manifest", "-r", "-o", str(build_manifest)],
                directory / "source", environment)
    if validate_manifest(build_manifest) != revisions:
        raise RuntimeError("Checkout revisions differ from the successful source-sync lock")
    runpy.run_path(str(INTEGRATION / "verify-source-lfs.py"))["verify_lfs"](directory)
    SYNC["require_space"](directory)
    install_integration(directory)
    output = prepare_output(directory, "out-cheetah")
    environment.update(OUT_DIR=output.name, SELINUX_IGNORE_NEVERALLOWS="false",
                       SKIP_KERNEL_BUILD="true", CCACHE_DIR=str(directory / "compiler-cache"),
                       CCACHE_MAXSIZE="50G")
    setup = "source build/envsetup.sh && lunch lineage_cheetah-bp4a-user && "
    SYNC["run"](["bash", "-c", setup +
                 "m -j8 SELINUX_IGNORE_NEVERALLOWS=false init_second_stage nns-mount selinux_policy sepolicy_neverallows"],
                directory / "source", environment)
    validate_compilation(output)
    print("PASS: creation-only init builtin, static AArch64 helper, installed init fragment, compiled domain and enabled neverallow checks", flush=True)
    SYNC["run"](["bash", "-c", setup +
                 "m -j8 SELINUX_IGNORE_NEVERALLOWS=false systemimage systemextimage simg2img"],
                directory / "source", environment)
    validate_compilation(output)
    for name in ("system.img", "system_ext.img"):
        image = output / "target/product/cheetah" / name
        if not image.is_file() or not image.stat().st_size:
            raise RuntimeError(f"Image was not produced: {name}")
    runpy.run_path(str(INTEGRATION / "inspect-cheetah.py"))["inspect_images"](directory)
    print("Cheetah build and image-content checks passed. Boot validation remains pending.", flush=True)


if __name__ == "__main__":
    main()
