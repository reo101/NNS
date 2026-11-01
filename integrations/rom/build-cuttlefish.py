#!/usr/bin/env python3
"""Build an enforcing Cuttlefish lab from the Cheetah source lock, without deployment."""

import hashlib
import json
from pathlib import Path
import runpy
import subprocess
import sys
import time

INTEGRATION = Path(__file__).resolve().parent
CHEETAH = runpy.run_path(str(INTEGRATION / "build-cheetah.py"))
SYNC = CHEETAH["SYNC"]
INSPECTION = runpy.run_path(str(INTEGRATION / "inspect-cheetah.py"))
PRODUCT_NAME = "lineage_cf_phone_x86_64"
DEVICE = "vsoc_x86_64"
KERNEL = "kernel/prebuilts/6.12/x86_64/kernel-6.12"
KERNEL_SHA256 = "0f6cf8acaf39bc49138677c695d574b3f9f551d0a21a467e560916467f5044f8"
SOURCE_EXTENSIONS = {
    "vendor/lineage/build/target/product/lineage_cf_phone_x86_64.mk": (
        "84152a979e5e479b7ce60ccffb1e40887029a996e2492783b84b56484ecfcfcc",
        "TARGET_RO_FILE_SYSTEM_TYPE := ext4\n"
        "$(call soong_config_set_bool,faceunlock,native_bridge,true)\n"
        "PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/lib64/arm64/libc++.so\n"
        "$(call inherit-product,external/nns-rom/product.mk)",
    ),
    "device/google/cuttlefish/vsoc_x86_64/BoardConfig.mk": (
        "8ca0068ef3b775d1c5d9839d1dd5e9a5e96599f05920be939683f53e62a648d9",
        "NNS_ROM_PATH := external/nns-rom\ninclude $(NNS_ROM_PATH)/BoardConfig.mk\n"
        "PRODUCT_SOONG_NAMESPACES := $(filter-out "
        "vendor/google_devices/common/proprietary/confirmatioui_hal,$(PRODUCT_SOONG_NAMESPACES))",
    ),
}


NATIVE_LIBRARIES = ("libFaceDetectCA", "libmegface_faceunlock", "libMegviiUnlock", "libMegviiUnlock-jni-1.2")
NATIVE_BRIDGE_SPECIFICATIONS = {
    "packages/apps/FaceUnlock/Android.bp": {
        "sha256": "926d94186b46a30a4a89bacdb3fb5d9b199e97bb8aafbec73f489c01e31ab66e",
        "replacements": [
            (f'    name: "{name}",\n',
             f'    name: "{name}",\n    native_bridge_supported: true,\n')
            for name in NATIVE_LIBRARIES
        ] + [(
            "    required: [\n" + "".join(f'        "{name}",\n' for name in NATIVE_LIBRARIES),
            '    required: select(soong_config_variable("faceunlock", "native_bridge"), {\n'
            "        true: [\n" + "".join(f'            "{name}.native_bridge",\n' for name in NATIVE_LIBRARIES) +
            "        ],\n        default: [\n" + "".join(f'            "{name}",\n' for name in NATIVE_LIBRARIES) +
            "        ],\n    }) + [\n",
        )],
    },
}


POLICY_SPECIFICATIONS = {
    "device/google/cuttlefish/shared/sepolicy/vendor/telephony/libcuttlefish_rild.te": {
        "sha256": "3e11e2db337d31fcac7bc320508c0f76aef508d64defea55b3e34b9fc8c62cea",
        "replacements": [(
            "allow libcuttlefish_rild su:{ socket udp_socket } { create_socket_perms_no_ioctl getattr };\n",
            "userdebug_or_eng(`\n"
            "allow libcuttlefish_rild su:{ socket udp_socket } { create_socket_perms_no_ioctl getattr };\n"
            "')\n",
        )],
    },
}


def install_cuttlefish_extension(source):
    hashes = {}
    for relative, (expected, addition) in SOURCE_EXTENSIONS.items():
        path = source / relative
        original = path.read_text().removesuffix("\n" + addition + "\n")
        if hashlib.sha256(original.encode()).hexdigest() != expected:
            raise RuntimeError(f"Cuttlefish source differs from the reviewed baseline: {relative}")
        path.write_text(original + "\n" + addition + "\n")
        hashes[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def wait_for_cheetah(directory):
    command = ["/run/current-system/sw/bin/systemctl", "--user"]
    print("Waiting for Cheetah compilation and image inspection before Cuttlefish", flush=True)
    while subprocess.run(command + ["is-active", "--quiet", "nns-rom-cheetah-build.service"]).returncode == 0:
        SYNC["require_space"](directory)
        time.sleep(30)
    if subprocess.run(command + ["is-failed", "--quiet", "nns-rom-cheetah-build.service"]).returncode == 0:
        raise RuntimeError("Cheetah build failed; Cuttlefish compilation has not started")
    # Transient units can disappear. Require real current artifacts, not a default success status.
    CHEETAH["validate_compilation"](directory / "out-cheetah")
    INSPECTION["inspect_images"](directory)


def main():
    directory = Path(sys.argv[1]).resolve(strict=True)
    wait_for_cheetah(directory)
    source = directory / "source"
    environment = SYNC["download_environment"](directory)
    manifest = directory / "cuttlefish-source-manifest.xml"
    SYNC["run"](["repo", "manifest", "-r", "-o", str(manifest)], source, environment)
    if CHEETAH["validate_manifest"](manifest) != CHEETAH["validate_manifest"](directory / "source-manifest.xml"):
        raise RuntimeError("Cuttlefish checkout revisions differ from the Cheetah source lock")
    hashes = install_cuttlefish_extension(source)
    for relative in CHEETAH["FILES"]:
        content = (source / CHEETAH["MODULE_PATH"] / relative).read_bytes()
        if content != (INTEGRATION / relative).read_bytes():
            raise RuntimeError(f"Installed integration differs from current source: {relative}")
        hashes[relative] = hashlib.sha256(content).hexdigest()
    hashes.update(CHEETAH["install_init_extension"](
        source, json.loads((INTEGRATION / "init-extension.json").read_text())))
    hashes.update(CHEETAH["install_init_extension"](source, NATIVE_BRIDGE_SPECIFICATIONS))
    hashes.update(CHEETAH["install_init_extension"](source, POLICY_SPECIFICATIONS))
    hashes[KERNEL] = hashlib.sha256((source / KERNEL).read_bytes()).hexdigest()
    if hashes[KERNEL] != KERNEL_SHA256:
        raise RuntimeError("Cuttlefish kernel differs from the pinned prebuilt")
    for relative in ("source-manifest.xml", "source-lfs.json", "build-inputs.json"):
        hashes[relative] = hashlib.sha256((directory / relative).read_bytes()).hexdigest()
    for relative in ("build-cuttlefish.py", "build-cheetah.py", "inspect-cheetah.py", "init-extension.json"):
        hashes[relative] = hashlib.sha256((INTEGRATION / relative).read_bytes()).hexdigest()
    (directory / "cuttlefish-build-inputs.json").write_text(json.dumps(hashes, indent=2) + "\n")
    output = CHEETAH["prepare_output"](directory, "out-cuttlefish")
    environment.update(OUT_DIR=output.name, SELINUX_IGNORE_NEVERALLOWS="false",
                       SKIP_KERNEL_BUILD="true", CCACHE_DIR=str(directory / "compiler-cache"),
                       CCACHE_MAXSIZE="50G")
    setup = f"source build/envsetup.sh && lunch {PRODUCT_NAME}-bp4a-userdebug && "
    SYNC["run"](["bash", "-c", setup +
                 "m -j8 SELINUX_IGNORE_NEVERALLOWS=false init_second_stage nns-mount selinux_policy sepolicy_neverallows"],
                source, environment)
    CHEETAH["validate_compilation"](output, PRODUCT_NAME, DEVICE, 62)
    print("PASS: Cuttlefish compiled init/helper/policy and enabled neverallow checks", flush=True)
    SYNC["run"](["bash", "-c", setup + "m -j8 SELINUX_IGNORE_NEVERALLOWS=false"], source, environment)
    SYNC["run"](["bash", "-c", setup + "m -j8 SELINUX_IGNORE_NEVERALLOWS=false cvd-host_package simg2img"],
                source, environment)
    CHEETAH["validate_compilation"](output, PRODUCT_NAME, DEVICE, 62)
    INSPECTION["inspect_images"](directory, "out-cuttlefish", DEVICE)
    if hashlib.sha256((source / KERNEL).read_bytes()).hexdigest() != KERNEL_SHA256:
        raise RuntimeError("Cuttlefish build changed the pinned kernel prebuilt")
    product = output / "target/product" / DEVICE
    if hashlib.sha256((product / "kernel").read_bytes()).hexdigest() != KERNEL_SHA256:
        raise RuntimeError("Cuttlefish output does not contain the pinned kernel prebuilt")
    print("Cuttlefish build and image checks passed. Enforcing boot validation remains pending.", flush=True)


if __name__ == "__main__":
    main()
