"""Run a real native Emacs against the rootless namespace launcher on Linux."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

helper, emacs, lisp, tests = map(lambda p: str(Path(p).resolve()), sys.argv[1:])
with tempfile.TemporaryDirectory(prefix='nns-emacs-test-') as base:
    root = Path(base)
    store = root / 'backing'
    (store / 'bin').mkdir(parents=True)
    (store / 'store').symlink_to('/.nns-host/nix/store')
    (store / 'marker').write_text('canonical-store')
    program = store / 'bin/nns-test-program'
    program.write_text(f'#!{sys.executable}\nimport sys\nprint(open("/nix/marker").read()+"|"+sys.argv[1])\n')
    program.chmod(0o755)
    env = dict(os.environ, NNS_TEST_HELPER=helper, NNS_TEST_STORE=str(store), NNS_TEST_TMP=base)
    result = subprocess.run([emacs, '-Q', '--batch', '-L', lisp, '-l', tests,
                             '-f', 'ert-run-tests-batch-and-exit'], env=env, cwd=base, timeout=90)
    assert not list(root.glob('nns.*')), 'launcher scratch directory leaked'
    raise SystemExit(result.returncode)
