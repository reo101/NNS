import subprocess
import sys
import tempfile
from pathlib import Path


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / "private").mkdir()
    (root / "prebuilts" / "api").mkdir(parents=True)
    (root / "private" / "app.te").write_text(
        "allow appdomain devpts:dir read;\n"
        "allow unrelated devpts:dir write;\n"
        "allow untrusted_app_27 self:unix_dgram_socket create;\n"
    )
    (root / "prebuilts" / "api" / "app.te").write_text("allow appdomain old:file read;\n")
    report = subprocess.check_output(
        [sys.executable, sys.argv[1], "policy@revision", str(root)], text=True
    )
    assert "policy@revision/private/app.te:1: allow appdomain devpts:dir read;" in report
    assert "policy@revision/private/app.te:3: allow untrusted_app_27 self:unix_dgram_socket create;" in report
    assert "unrelated" not in report
    assert "prebuilts" not in report
