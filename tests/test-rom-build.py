#!/usr/bin/env python3
"""Check build-driver revision, wiring and neverallow gates without compiling a ROM."""

import hashlib
import json
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
driver = root / "integrations/rom/build-cheetah.py"
build = runpy.run_path(str(driver))
assert "systemimage systemextimage simg2img" in driver.read_text()


def expect_refusal(function, *arguments):
    try:
        function(*arguments)
    except RuntimeError:
        return
    raise AssertionError("Build driver accepted invalid inputs")


with tempfile.TemporaryDirectory(prefix="nns-rom-build-test-") as temporary:
    directory = Path(temporary)
    manifest = directory / "source-manifest.xml"
    resolved = ET.Element("manifest")
    for entry in ET.parse(root / "integrations/rom/cheetah-source.xml").getroot():
        ET.SubElement(resolved, "project", path=entry.get("path"), revision=entry.get("revision"))
    ET.SubElement(resolved, "project", name="art", revision="a" * 40)
    ET.SubElement(resolved, "project", name="bionic", revision="b" * 40)
    ET.ElementTree(resolved).write(manifest)
    revisions = build["validate_manifest"](manifest)
    assert revisions["art"] == "a" * 40 and revisions["bionic"] == "b" * 40
    revision = resolved[0].get("revision")
    for invalid_revision in ("refs/heads/bka", "f" * 40):
        resolved[0].set("revision", invalid_revision)
        ET.ElementTree(resolved).write(manifest)
        expect_refusal(build["validate_manifest"], manifest)
    resolved[0].set("revision", revision)
    duplicate = ET.SubElement(resolved, "project", **resolved[0].attrib)
    ET.ElementTree(resolved).write(manifest)
    expect_refusal(build["validate_manifest"], manifest)
    resolved.remove(duplicate)
    ET.ElementTree(resolved).write(manifest)

    for relative in ("cheetah/BoardConfig.mk", "lineage_cheetah.mk"):
        path = directory / "source/device/google/pantah" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# Existing device configuration\n")
    (directory / "source-lfs.json").write_text("[]\n")
    for name in json.loads((root / "integrations/rom/cheetah-overlay-exclusions.json").read_text()):
        overlay = directory / f"source/vendor/pixel-style/rro_overlays/{name}/Android.bp"
        overlay.parent.mkdir(parents=True)
        prefix = "//\n// SPDX-FileCopyrightText: The LineageOS Project\n// SPDX-License-Identifier: Apache-2.0\n//\n\n" if name.startswith("Glanceable") else ""
        overlay.write_text(prefix + 'runtime_resource_overlay {\n    name: "' + name + '",\n    product_specific: true,\n}\n')
        counterpart = directory / f"source/device/google/gs201/overlay/{name}/Android.bp"
        counterpart.parent.mkdir(parents=True)
        counterpart.write_text(overlay.read_text())
    with patch.dict(build["install_integration"].__globals__, {"install_init_extension": lambda *args: {}}):
        build["install_integration"](directory)
    installed = {path: path.read_bytes() for path in
                 (directory / "source/device/google/pantah").rglob("*.mk")}
    with patch.dict(build["install_integration"].__globals__, {"install_init_extension": lambda *args: {}}):
        build["install_integration"](directory)
    assert all(path.read_bytes() == content for path, content in installed.items())
    assert "runtime_resource_overlay" not in overlay.read_text()
    assert "device/google/gs201" in overlay.read_text()
    for relative in build["FILES"]:
        assert (directory / "source" / build["MODULE_PATH"] / relative).read_bytes() == (
            root / "integrations/rom" / relative).read_bytes()

    specifications = json.loads((root / "integrations/rom/init-extension.json").read_text())
    for relative, specification in specifications.items():
        path = directory / "source" / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        original = "\n".join(previous for previous, replacement in specification["replacements"])
        path.write_text(original)
        specification["sha256"] = hashlib.sha256(original.encode()).hexdigest()
    first = build["install_init_extension"](directory / "source", specifications)
    assert 'whole_static_libs: [\n        "libnns_backing",' in (
        directory / "source/system/core/init/Android.bp").read_text()
    assert build["install_init_extension"](directory / "source", specifications) == first
    assert '"nns_prepare_backing"' in path.read_text()
    path.write_text(path.read_text() + "// unrelated modification\n")
    expect_refusal(build["install_init_extension"], directory / "source", specifications)

    output = build["prepare_output"](directory, "out-cheetah")
    output_link = directory / "source/out-cheetah"
    assert output.is_dir() and output_link.is_dir() and output_link.is_symlink()
    assert build["prepare_output"](directory, "out-cheetah") == output
    (directory / "source/out-cuttlefish").symlink_to("../out-cuttlefish", target_is_directory=True)
    assert build["prepare_output"](directory, "out-cuttlefish").is_dir()
    assert (directory / "source/out-cuttlefish").is_dir()
    (directory / "source/out-conflicting").mkdir()
    expect_refusal(build["prepare_output"], directory, "out-conflicting")
    assert not (directory / "out-conflicting").exists()
    variables = output / "soong/soong.lineage_cheetah.variables"
    variables.parent.mkdir(parents=True)
    configuration = {"DeviceName": "cheetah",
                     "SystemExtPrivateSepolicyDirs": [f'{build["MODULE_PATH"]}/sepolicy']}
    variables.write_text(json.dumps(configuration))
    build["validate_configuration"](output)
    configuration["SelinuxIgnoreNeverallows"] = True
    variables.write_text(json.dumps(configuration))
    expect_refusal(build["validate_configuration"], output)
    configuration["SelinuxIgnoreNeverallows"] = False
    configuration["SystemExtPrivateSepolicyDirs"] = []
    variables.write_text(json.dumps(configuration))
    expect_refusal(build["validate_configuration"], output)

    virtual_variables = output / "soong/soong.lineage_cf_phone_x86_64.variables"
    virtual_variables.write_text(json.dumps({
        "DeviceName": "vsoc_x86_64",
        "SystemExtPrivateSepolicyDirs": [f'{build["MODULE_PATH"]}/sepolicy'],
    }))
    build["validate_configuration"](output, "lineage_cf_phone_x86_64", "vsoc_x86_64")
    expect_refusal(build["validate_configuration"], output, "lineage_cf_phone_x86_64", "cheetah")

    with patch.object(build["subprocess"], "run", side_effect=[
        SimpleNamespace(returncode=3), SimpleNamespace(returncode=0),
    ]):
        expect_refusal(build["wait_for_source"], directory)

print("PASS: resolved revisions, repeat-safe wiring, neverallow/policy gates and failed-sync refusal")
