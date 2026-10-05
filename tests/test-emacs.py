"""Run a real native Emacs against the rootless namespace launcher on Linux."""
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

helper, emacs, lisp, tests = map(lambda p: str(Path(p).resolve()), sys.argv[1:])
with tempfile.TemporaryDirectory(prefix='nns-emacs-test-') as base:
    root = Path(base)
    store = root / 'backing'
    mock_store = store / 'store'
    mock_store.mkdir(parents=True)
    # Mirror only the interpreter closures, not the machine's whole store.
    roots = {str(Path(path).resolve().parents[1]) for path in (sys.executable, '/bin/sh', shutil.which('id'))}
    references = subprocess.check_output(['nix-store', '--query', '--requisites', *sorted(roots)], text=True)
    for reference in references.splitlines():
        (mock_store / Path(reference).name).symlink_to('/.nns-host' + reference)
    base_profile = mock_store / 'nns-emacs-base'
    (base_profile / 'bin').mkdir(parents=True)
    (store / 'marker').write_text('canonical-store')
    program = base_profile / 'bin/nns-test-program'
    program.write_text(f'#!{sys.executable}\nimport sys\nprint(open("/nix/marker").read()+"|"+sys.argv[1])\n')
    program.chmod(0o755)
    profiles = store / 'var/nix/profiles'
    profiles.mkdir(parents=True)
    infrastructure = mock_store / 'nns-emacs-infrastructure'
    (infrastructure / 'bin').mkdir(parents=True)
    (infrastructure / 'bin/id').symlink_to(str(Path(shutil.which('id')).resolve()))
    (profiles / 'system-profile').symlink_to('/nix/store/nns-emacs-infrastructure')
    for generation, name in ((1, 'first'), (2, 'second')):
        environment = mock_store / f'nns-emacs-{name}'
        (environment / 'bin').mkdir(parents=True)
        (environment / 'etc/nns').mkdir(parents=True)
        (environment / 'etc/nns/environment').write_text(f'export NNS_TEST_SELECTION={name}\n')
        executable = environment / 'bin/nns-profile-program'
        executable.write_text(f'#!{sys.executable}\nimport os\nprint(os.environ["NNS_TEST_SELECTION"]+"|"+os.environ["HOME"])\n')
        executable.chmod(0o755)
        (profiles / f'development-{generation}-link').symlink_to(f'/nix/store/nns-emacs-{name}')
    (profiles / 'development').symlink_to('development-1-link')
    env = dict(os.environ, NNS_TEST_HELPER=helper, NNS_TEST_STORE=str(store), NNS_TEST_TMP=base)
    result = subprocess.run([emacs, '-Q', '--batch', '-L', lisp, '-l', tests,
                             '-f', 'ert-run-tests-batch-and-exit'], env=env, cwd=base, timeout=90)
    assert not list(root.glob('nns.*')), 'launcher scratch directory leaked'
    raise SystemExit(result.returncode)
