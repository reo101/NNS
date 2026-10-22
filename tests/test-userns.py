"""Run outside the Nix build sandbox: test real, unprivileged Linux namespaces."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

HELPER = str(Path(sys.argv.pop(1)).resolve())


class NamespaceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nns-test-')
        self.base = Path(self.temp.name)
        self.store = self.base / 'backing'
        self.store.mkdir()
        # Let the host's Nix-linked test interpreter run through the new /nix.
        (self.store / 'store').symlink_to('/.nns-host/nix/store')
        (self.store / 'marker').write_text('canonical-store')
        self.profile_target = Path(sys.executable).resolve().parents[1]
        self.profiles = self.store / 'var/nix/profiles'
        self.profiles.mkdir(parents=True)
        for name in ('system-profile', 'work', 'work-7-link'):
            (self.profiles / name).symlink_to('/nix/store/' + self.profile_target.name)
        self.cwd = self.base / 'cwd'
        self.cwd.mkdir()
        self.mounts = Path('/proc/self/mountinfo').read_text()
        self.userns = os.readlink('/proc/self/ns/user')

    def tearDown(self):
        self.assertEqual(list(self.base.glob('nns.*')), [], 'scratch directory leaked')
        self.assertEqual(Path('/proc/self/mountinfo').read_text(), self.mounts,
                         'parent mount namespace changed')
        self.temp.cleanup()

    def run_code(self, code, *args, explicit=True, store=None, env=None, options=(), umask=-1):
        result = subprocess.run([
            HELPER, *(['--userns'] if explicit else []), *options,
            '--store', str(store or self.store), '--tmpdir', str(self.base),
            '--', sys.executable, '-c', code, *args,
        ], cwd=self.cwd, text=True, capture_output=True, timeout=20, env=env, umask=umask)
        return result

    def test_profile_selection_and_path_precedence(self):
        code = '''
import json, os
print(json.dumps([os.environ['NNS_PROFILE'], os.environ['PATH'],
                  os.environ.get('HOME'), os.getcwd()]))
'''
        expected = '/nix/store/' + self.profile_target.name
        inherited_path = '/custom/bin:/usr/bin'
        for options, resolved in [
            ((), '/nix/var/nix/profiles/system-profile'),
            (('--profile', 'work'), expected),
            (('--profile', 'work', '--generation', '7'), expected),
            (('--profile', expected), expected),
        ]:
            r = self.run_code(code, options=options, env=dict(os.environ, HOME='/tmp/app-home', PATH=inherited_path))
            self.assertEqual(r.returncode, 0, r.stderr)
            profile, prefix, home, cwd = json.loads(r.stdout)
            self.assertEqual(profile, resolved)
            self.assertEqual(prefix, ':'.join(['/data/nix/var/nns/bin', resolved + '/bin',
                                                '/nix/var/nix/profiles/system-profile/bin', inherited_path]))
            self.assertEqual(home, '/tmp/app-home')
            self.assertTrue(os.path.samefile(cwd, self.cwd))

    def test_private_var_empty_preserves_other_var_entries(self):
        marker = 'nns-private-' + self.base.name
        host_marker = Path('/var/empty') / marker
        existed = host_marker.exists()
        code = '''
import json, os, stat, sys
from pathlib import Path
empty = Path('/var/empty')
assert list(empty.iterdir()) == []
mode = empty.stat()
(empty / sys.argv[1]).write_text('namespace-only')
mirrored = all(os.path.samefile('/var/' + name, '/.nns-host/var/' + name)
               for name in os.listdir('/.nns-host/var') if name != 'empty')
print(json.dumps([mode.st_uid, mode.st_gid, stat.S_IMODE(mode.st_mode), mirrored, os.umask(0)]))
'''
        for _ in range(2):
            result = self.run_code(code, marker, umask=0o077)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), [os.getuid(), os.getgid(), 0o755, True, 0o077])
            self.assertEqual(host_marker.exists(), existed)

    def test_private_var_when_original_var_is_absent(self):
        result = self.run_code('''
import os, subprocess, sys
# Rename only the launcher's own tmpfs directory, never the host /var.
assert os.path.isdir('/.nns-host')
os.rename('/var', '/var-original')
result = subprocess.run([sys.argv[1], '--store', '/.nns-host/nix',
    '--tmpdir', sys.argv[2], '--', sys.executable, '-c',
    'from pathlib import Path; assert list(Path("/var/empty").iterdir()) == []'],
    text=True, capture_output=True)
print(result.stderr, end='')
sys.exit(result.returncode)
''', HELPER, str(self.base))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_synthetic_caller_account_records(self):
        original = Path('/etc/passwd').read_bytes()
        result = self.run_code('''
import grp, json, os, pwd, stat
from pathlib import Path
account = pwd.getpwuid(os.getuid())
group = grp.getgrgid(os.getgid())
assert not os.path.samefile('/etc/passwd', '/.nns-host/etc/passwd')
assert all(os.path.samefile('/etc/' + name, '/.nns-host/etc/' + name)
           for name in os.listdir('/.nns-host/etc') if name not in ('passwd', 'group'))
print(json.dumps([account.pw_name, account.pw_uid, account.pw_gid,
    account.pw_dir, account.pw_shell, group.gr_gid,
    stat.S_IMODE(Path('/etc/passwd').stat().st_mode), os.umask(0)]))
with open('/etc/passwd', 'a') as output:
    output.write('# namespace-only\\n')
''', env=dict(os.environ, USER='hosting-user', HOME='/tmp/hosting-home', SHELL='/bin/sh'),
            umask=0o077)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            'root' if os.getuid() == 0 else 'hosting-user', os.getuid(), os.getgid(),
            '/tmp/hosting-home', '/bin/sh', os.getgid(), 0o644, 0o077])
        self.assertEqual(Path('/etc/passwd').read_bytes(), original)

    def publish_account_records(self, records):
        infrastructure = self.base / 'infrastructure'
        registry = infrastructure / 'etc/nns/passwd'
        registry.parent.mkdir(parents=True)
        registry.write_text(records)
        (self.profiles / 'system-profile').unlink()
        (self.profiles / 'system-profile').symlink_to(infrastructure)

    def test_registered_account_name_preserves_numeric_identity_and_home(self):
        name = 'root' if os.getuid() == 0 else 'emacs'
        self.publish_account_records(
            f'other:x:{os.getuid() + 1}:{os.getgid()}:other:/other:/bin/false\n'
            f'{name}:x:{os.getuid()}:{os.getgid()}:editor:/configured-home:/bin/false\n')
        result = self.run_code('''
import grp, json, os, pwd
account = pwd.getpwuid(os.getuid())
print(json.dumps([account.pw_name, grp.getgrgid(os.getgid()).gr_name,
    os.getuid(), os.getgid(), account.pw_dir, account.pw_shell,
    os.environ['USER'], os.environ['LOGNAME']]))
''', env=dict(os.environ, USER='inherited-name', LOGNAME='inherited-login',
              HOME='/tmp/caller-home', SHELL='/bin/sh'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [name, name, os.getuid(), os.getgid(),
            '/tmp/caller-home', '/bin/sh', name, name])

    def test_unregistered_uid_keeps_inherited_name(self):
        self.publish_account_records(
            f'other:x:{os.getuid() + 1}:{os.getgid()}:other:/other:/bin/false\n')
        result = self.run_code('''
import json, os, pwd
print(json.dumps([pwd.getpwuid(os.getuid()).pw_name,
    os.environ['USER'], os.environ['LOGNAME']]))
''', env=dict(os.environ, USER='inherited-name', LOGNAME='inherited-login'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            'root' if os.getuid() == 0 else 'inherited-name', 'inherited-name', 'inherited-login'])

    def test_registered_group_does_not_change_actual_gid(self):
        self.publish_account_records(
            f'editor:x:{os.getuid()}:{os.getgid() + 1}:editor:/other:/bin/false\n')
        result = self.run_code('''
import grp, json, os
print(json.dumps([os.getgid(), grp.getgrgid(os.getgid()).gr_name]))
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [os.getgid(),
            'root' if os.getgid() == 0 else f'gid{os.getgid()}'])

    def test_explicit_etc_keeps_supplied_account_records(self):
        self.publish_account_records(
            f'configured:x:{os.getuid()}:{os.getgid()}:ignored:/ignored:/bin/false\n')
        directory = self.base / 'etc'
        directory.mkdir()
        record = f'explicit-user:x:{os.getuid()}:{os.getgid()}:explicit:/explicit-home:/bin/sh\n'
        (directory / 'passwd').write_text(record)
        (directory / 'group').write_text(f'explicit-group:x:{os.getgid()}:\n')
        result = self.run_code('''
import json, os, pwd
from pathlib import Path
account = pwd.getpwuid(os.getuid())
print(json.dumps([account.pw_name, account.pw_dir, Path('/etc/passwd').read_text()]))
''', options=('--etc', str(directory)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ['explicit-user', '/explicit-home', record])

    def test_account_record_delimiters_are_rejected(self):
        for key, value in [('HOME', '/tmp/invalid:home'), ('USER', 'invalid\nuser'),
                           ('SHELL', '/bin/sh\ninvalid')]:
            if key == 'USER' and os.getuid() == 0:
                continue  # Root keeps its administrative account name.
            result = self.run_code('raise Exception("must not execute")',
                                   env=dict(os.environ, **{key: value}))
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('must not execute', result.stderr)

    def test_namespace_bootstrap_without_infrastructure_profile(self):
        (self.profiles / 'system-profile').unlink()
        result = self.run_code('print("bootstrap")')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'bootstrap')

    def test_inherited_configuration_defaults(self):
        env = dict(os.environ, NIX_CONF_DIR='/custom/nix-config', NIX_REMOTE='custom-remote')
        r = self.run_code('import os,json; print(json.dumps([os.environ["NIX_CONF_DIR"], os.environ["NIX_REMOTE"]]))', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), ['/custom/nix-config', 'custom-remote'])
        for missing, defaults in [('NIX_CONF_DIR', ['/data/nix/etc/nix', 'custom-remote']),
                                  ('NIX_REMOTE', ['/custom/nix-config', 'daemon' if os.getuid() != 0 else 'local'])]:
            partial = dict(env)
            partial.pop(missing)
            r = self.run_code('import os,json; print(json.dumps([os.environ["NIX_CONF_DIR"], os.environ["NIX_REMOTE"]]))', env=partial)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(json.loads(r.stdout), defaults)
        env.pop('NIX_CONF_DIR')
        env.pop('NIX_REMOTE')
        r = self.run_code('import os,json; print(json.dumps([os.environ["NIX_CONF_DIR"], os.environ["NIX_REMOTE"]]))', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), ['/data/nix/etc/nix', 'daemon' if os.getuid() != 0 else 'local'])

    def test_bare_command_uses_constructed_path(self):
        inherited_bin = self.base / 'inherited-bin'
        inherited_bin.mkdir()
        decoy = inherited_bin / 'python3'
        decoy.write_text('#!/bin/sh\nprintf inherited-path\n')
        decoy.chmod(0o755)
        env = dict(os.environ, PATH=str(inherited_bin))
        r = subprocess.run([
            HELPER, '--profile', 'work', '--store', str(self.store),
            '--tmpdir', str(self.base), '--', 'python3', '-c',
            'import os; print(os.environ["NNS_PROFILE"])',
        ], cwd=self.cwd, text=True, capture_output=True, timeout=20, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), '/nix/store/' + self.profile_target.name)

    def test_invalid_and_missing_profiles_are_rejected(self):
        for options in [
            ('--profile', '../escape'),
            ('--profile', '-invalid'),
            ('--profile', '.invalid'),
            ('--profile', 'work', '--generation', '0'),
            ('--profile', 'work', '--generation', '1x'),
            ('--profile', '/nix/store/missing-profile'),
            ('--profile', 'missing'),
            ('--profile', '/nix/store/missing-profile', '--generation', '1'),
        ]:
            r = self.run_code('raise Exception("must not execute")', options=options)
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('must not execute', r.stderr)

    def test_identity_cwd_canonical_path_and_caps(self):
        r = self.run_code('''
import json, os
from pathlib import Path
s = dict(line.split(':', 1) for line in Path('/proc/self/status').read_text().splitlines())
print(json.dumps([os.getuid(), os.getgid(), os.getcwd(),
  Path('/nix/marker').read_text(), os.readlink('/proc/self/ns/user'),
  s['NoNewPrivs'].strip(), s['CapEff'].strip()]))
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        uid, gid, cwd, marker, namespace, nnp, caps = json.loads(r.stdout)
        self.assertEqual((uid, gid), (os.getuid(), os.getgid()))
        self.assertTrue(os.path.samefile(cwd, self.cwd))
        self.assertEqual(marker, 'canonical-store')
        self.assertNotEqual(namespace, self.userns)
        self.assertEqual(nnp, '1')
        if os.getuid() != 0:
            self.assertEqual(int(caps, 16), 0)

    @unittest.skipIf(os.getuid() == 0, 'automatic userns applies to non-root callers')
    def test_non_root_automatically_uses_userns(self):
        r = self.run_code('import os; print(os.readlink("/proc/self/ns/user"))', explicit=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotEqual(r.stdout.strip(), self.userns)

    def test_arguments_and_exit_status(self):
        r = self.run_code('import sys; print(sys.argv[1:]); sys.exit(37)', 'has spaces', '')
        self.assertEqual(r.returncode, 37, r.stderr)
        self.assertEqual(r.stdout.strip(), "['has spaces', '']")
        r = self.run_code('import os,signal; os.kill(os.getpid(), signal.SIGTERM)')
        self.assertEqual(r.returncode, 128 + signal.SIGTERM, r.stderr)

    def test_dns_preload_environment(self):
        bridge = str(self.store / 'lib/libnns-dns.so')
        env = dict(os.environ, LD_PRELOAD='/no/such/preload.so', NNS_TEST_ENV='preserved')
        code = 'import os,json; print(json.dumps([os.environ["LD_PRELOAD"], os.environ["NNS_TEST_ENV"]]))'
        r = self.run_code(code, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), ['/no/such/preload.so', 'preserved'])
        (self.store / 'lib').mkdir()
        # The loader ignores this empty test DSO; we only test launcher env
        # construction here. The real DSO is covered by test-dns.py.
        (self.store / 'lib/libnns-dns.so').touch()
        r = self.run_code(code, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), [bridge + ':/no/such/preload.so', 'preserved'])
        env['LD_PRELOAD'] = bridge
        r = self.run_code(code, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), [bridge, 'preserved'])
        del env['LD_PRELOAD']
        r = self.run_code(code, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), [bridge, 'preserved'])

    def test_setup_failure_is_clean(self):
        r = self.run_code('raise Exception("must not execute")', store=self.base / 'absent')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('mount', r.stderr)
        self.assertNotIn('must not execute', r.stderr)

    def test_userns_does_not_grant_parent_filesystem_privileges(self):
        secret = self.base / 'unreadable'
        secret.write_text('private')
        secret.chmod(0)
        try:
            r = self.run_code('''
import sys
try:
    open(sys.argv[1]).read()
except PermissionError:
    sys.exit(0)
sys.exit(99)
''', str(secret))
            self.assertEqual(r.returncode, 0, r.stderr)
        finally:
            secret.chmod(0o600)


unittest.main()
