#!/usr/bin/env python3
"""Check guarded Cuttlefish wiring and the Cheetah artifact dependency gate."""

import hashlib
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
build = runpy.run_path(str(root / "integrations/rom/build-cuttlefish.py"))
assert build["PRODUCT_NAME"] == "lineage_cf_phone_x86_64"
assert build["DEVICE"] == "vsoc_x86_64"

fixture_source = (root / "tests/rom-fixture/fixture.c").read_text()
fixture_init = (root / "tests/rom-fixture/init.nns-fixture.rc").read_text()
assert "mkdir /data/nns-fixture 0775 root system encryption=Require" in fixture_init
assert "s.st_uid != 0 || s.st_gid != 1000 || (s.st_mode & 07777) != 0775" in fixture_source

with tempfile.TemporaryDirectory(prefix="nns-cuttlefish-build-test-") as temporary:
    source = Path(temporary)
    extensions = {}
    for relative, (_, addition) in build["SOURCE_EXTENSIONS"].items():
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        original = "# Reviewed source fixture\n"
        path.write_text(original)
        extensions[relative] = (hashlib.sha256(original.encode()).hexdigest(), addition)
    with patch.dict(build["install_cuttlefish_extension"].__globals__, {"SOURCE_EXTENSIONS": extensions}):
        first = build["install_cuttlefish_extension"](source)
        assert build["install_cuttlefish_extension"](source) == first
        product = (source / next(iter(extensions))).read_text()
        assert "TARGET_RO_FILE_SYSTEM_TYPE := ext4" in product
        assert "external/nns-rom/product.mk" in product
        assert "$(call soong_config_set_bool,faceunlock,native_bridge,true)" in product
        assert "PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += system/lib64/arm64/libc++.so\n" in product
        board = path.read_text()
        assert "NNS_ROM_PATH := external/nns-rom" in board
        assert "$(filter-out vendor/google_devices/common/proprietary/confirmatioui_hal," in board
        path.write_text(path.read_text() + "# Unreviewed change\n")
        try:
            build["install_cuttlefish_extension"](source)
        except RuntimeError:
            pass
        else:
            raise AssertionError("Unreviewed Cuttlefish source was accepted")
    for relative, specification in build["NATIVE_BRIDGE_SPECIFICATIONS"].items():
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        original = "".join(previous for previous, _ in specification["replacements"])
        path.write_text(original)
        specifications = {relative: dict(specification, sha256=hashlib.sha256(original.encode()).hexdigest())}
        first = build["CHEETAH"]["install_init_extension"](source, specifications)
        assert build["CHEETAH"]["install_init_extension"](source, specifications) == first
        updated = path.read_text()
        assert updated.count("native_bridge_supported: true") == 4
        assert 'select(soong_config_variable("faceunlock", "native_bridge")' in updated
        translated, native = updated.split("        true: [", 1)[1].split("        default: [", 1)
        native = native.split("        ],", 1)[0]
        assert ".native_bridge" not in native
        for name in build["NATIVE_LIBRARIES"]:
            assert f'"{name}.native_bridge"' in translated
            assert f'"{name}"' in native
        path.write_text(path.read_text() + "# Unreviewed change\n")
        try:
            build["CHEETAH"]["install_init_extension"](source, specifications)
        except RuntimeError:
            pass
        else:
            raise AssertionError("Unreviewed native-bridge source was accepted")
    for relative, specification in build["POLICY_SPECIFICATIONS"].items():
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        original = specification["replacements"][0][0]
        path.write_text(original)
        specifications = {relative: dict(specification, sha256=hashlib.sha256(original.encode()).hexdigest())}
        first = build["CHEETAH"]["install_init_extension"](source, specifications)
        assert build["CHEETAH"]["install_init_extension"](source, specifications) == first
        assert path.read_text() == "userdebug_or_eng(`\n" + original + "')\n"
        path.write_text(path.read_text() + "# Unreviewed change\n")
        try:
            build["CHEETAH"]["install_init_extension"](source, specifications)
        except RuntimeError:
            pass
        else:
            raise AssertionError("Unreviewed Cuttlefish radio policy was accepted")
    with patch.object(build["subprocess"], "run", side_effect=[
        SimpleNamespace(returncode=3), SimpleNamespace(returncode=0),
    ]):
        try:
            build["wait_for_cheetah"](source)
        except RuntimeError:
            pass
        else:
            raise AssertionError("Failed Cheetah build was accepted")

print("PASS: repeat-safe hash-guarded Cuttlefish wiring and failed-Cheetah refusal")
