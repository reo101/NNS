#!/usr/bin/env python3
"""The sync driver must refuse low space before launching a subprocess."""

import importlib.util
from pathlib import Path
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "integrations/rom/sync-cheetah.py"
specification = importlib.util.spec_from_file_location("rom_source_sync", path)
module = importlib.util.module_from_spec(specification)
specification.loader.exec_module(module)

with patch.object(module.shutil, "disk_usage") as disk_usage:
    disk_usage.return_value.free = module.MINIMUM_FREE_BYTES - 1
    with patch.object(module.subprocess, "Popen") as launch:
        try:
            module.run(["repo", "sync"], path.parent, {})
        except RuntimeError as error:
            assert "150 GiB" in str(error)
        else:
            raise AssertionError("Low-space source sync was allowed")
        launch.assert_not_called()
    disk_usage.return_value.free = module.MINIMUM_FREE_BYTES
    module.require_space(path.parent)

with patch.object(module.shutil, "disk_usage") as disk_usage:
    disk_usage.return_value.free = module.MINIMUM_FREE_BYTES
    with patch.object(module.subprocess, "Popen") as launch:
        process = launch.return_value
        process.pid = 123
        process.poll.return_value = None
        with patch.object(module, "require_space", side_effect=[None, RuntimeError("low space")]):
            with patch.object(module.os, "killpg") as terminate:
                try:
                    module.run(["repo", "sync"], path.parent, {})
                except RuntimeError:
                    pass
                else:
                    raise AssertionError("Running sync ignored low space")
                terminate.assert_called_once_with(123, module.signal.SIGTERM)
                process.wait.assert_called_once_with(timeout=10)

print("PASS: low-space launch refused; boundary accepted; running sync terminated")
