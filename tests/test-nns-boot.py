from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HELPER = str(Path(sys.argv.pop(1)).resolve())
SCRIPT = Path(__file__).resolve().parents[1] / 'module/system-generation.sh'
RUNTIME_SCRIPT = Path(__file__).resolve().parents[1] / 'module/stage-android-runtime.sh'
PROGRAM = r'''
test -d /.nns-host || exit 90
mkdir -p /data
mount -t tmpfs -o mode=755 tmpfs /data || exit 91
if [ "$2" = android-runtime ]; then
  set -eu
  mkdir -p /data/nix/etc /data/system/environ
  printf '%s\n' 'export BOOTCLASSPATH /apex/art/core.jar:/system/framework/framework.jar' \
    'export DEX2OATBOOTCLASSPATH /apex/art/core.jar' \
    'export SYSTEMSERVERCLASSPATH /system/framework/services.jar' > /data/system/environ/classpath
  "$3" "$4"
  . /data/nix/etc/android-runtime.env
  test "$BOOTCLASSPATH" = /apex/art/core.jar:/system/framework/framework.jar
  test "$DEX2OATBOOTCLASSPATH" = /apex/art/core.jar
  test -z "${SYSTEMSERVERCLASSPATH:-}"
  cp /data/nix/etc/android-runtime.env /data/previous.env
  printf '%s\n' 'export BOOTCLASSPATH /bad.jar;touch /data/injected' > /data/system/environ/classpath
  if "$3" "$4"; then exit 92; fi
  cmp /data/previous.env /data/nix/etc/android-runtime.env
  test ! -e /data/injected
  chmod 777 /data/nix/etc
  if "$3" "$4"; then exit 93; fi
  exit 0
fi
if [ "$2" = ssh-check ]; then
  set -eu
  umask 077
  mkdir -p /data/nns-ssh-test/etc
  printf '%s\n' 'root:x:0:0:root:/data/nns-ssh-test:/bin/sh' \
    'sshd:x:9999:9999:sshd:/var/empty:/bin/sh' > /data/nns-ssh-test/etc/passwd
  printf '%s\n' 'root:x:0:' 'sshd:x:9999:' > /data/nns-ssh-test/etc/group
  "${3%/*}/ssh-keygen" -q -t ed25519 -N '' -f /data/nns-ssh-test/key
  printf '%s\n' 'HostKey /data/nns-ssh-test/key' 'UsePAM no' \
    'PidFile /data/nns-ssh-test/pid' > /data/nns-ssh-test/config
  exec "$4" --store /nix --tmpdir "$5" --etc /data/nns-ssh-test/etc -- \
    "$3" -t -f /data/nns-ssh-test/config
fi
mkdir -p /data/nix/store/mock-generation /data/nix/var/nix/profiles
chmod 755 /data/nix /data/nix/store /data/nix/var /data/nix/var/nix /data/nix/var/nix/profiles /data/nix/store/mock-generation
if [ "$2" != direct-no-nns-dirs ]; then
  mkdir -p /data/nix/var/nns/bin /data/nix/var/nns/services
  chmod 755 /data/nix/var/nns /data/nix/var/nns/bin /data/nix/var/nns/services
fi
case $2 in
  absent) ;;
  versioned) ln -s nns-system-1-link /data/nix/var/nix/profiles/nns-system
            ln -s /nix/store/mock-generation /data/nix/var/nix/profiles/nns-system-1-link ;;
  writable-store-parent) chmod 777 /data/nix/store
            ln -s /nix/store/mock-generation /data/nix/var/nix/profiles/nns-system ;;
  writable-store-group) chmod 775 /data/nix/store
            ln -s /nix/store/mock-generation /data/nix/var/nix/profiles/nns-system ;;
  writable-generation-other) chmod 757 /data/nix/store/mock-generation
            ln -s /nix/store/mock-generation /data/nix/var/nix/profiles/nns-system ;;
  writable-generation) chmod 777 /data/nix/store/mock-generation
            ln -s /nix/store/mock-generation /data/nix/var/nix/profiles/nns-system ;;
  mutable-target) mkdir -p /data/somewhere
            ln -s /data/somewhere /data/nix/var/nix/profiles/nns-system ;;
  symlink-generation) mkdir -p /data/real-generation
            rmdir /data/nix/store/mock-generation
            ln -s /data/real-generation /data/nix/store/mock-generation
            ln -s /nix/store/mock-generation /data/nix/var/nix/profiles/nns-system ;;
  traversal) ln -s /nix/store/mock-generation/../elsewhere /data/nix/var/nix/profiles/nns-system ;;
  *) ln -s /nix/store/mock-generation /data/nix/var/nix/profiles/nns-system ;;
esac
. "$1"
if [ "$2" = absent ]; then
  nns_system_selected
  exit $?
fi
case $2 in
  direct|versioned|direct-no-nns-dirs) nns_system_selected ;;
  *) if (nns_system_selected); then exit 92; else exit 0; fi ;;
esac
'''


class SystemGenerationBootTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nns-boot-')
        self.base = Path(self.temp.name)
        self.mounts = Path('/proc/self/mountinfo').read_text()
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.assert_parent_mounts_unchanged)

    def assert_parent_mounts_unchanged(self):
        self.assertEqual(Path('/proc/self/mountinfo').read_text(), self.mounts,
                         'parent mount namespace changed')
        self.assertEqual(list(self.base.glob('nns.*')), [], 'scratch directory leaked')

    def run_case(self, case, *arguments, shell='/bin/sh'):
        result = subprocess.run([
            'unshare', '--user', '--map-root-user', '--mount', '--fork', HELPER,
            '--store', '/nix', '--tmpdir', str(self.base), '--', shell, '-c',
            PROGRAM, 'boot-test', str(SCRIPT), case, *arguments,
        ], text=True, capture_output=True, timeout=30)
        if result.returncode and any(message in result.stderr.lower() for message in (
                'operation not permitted', 'unshare failed', 'user namespaces are not enabled',
                'namespace setup')):
            self.skipTest(f'user/mount namespaces unavailable: {result.stderr.strip()}')
        return result

    def test_stock_sshd_accepts_private_var_empty(self):
        sshd = shutil.which('sshd')
        if not sshd:
            self.skipTest('OpenSSH server unavailable')
        result = self.run_case('ssh-check', str(Path(sshd).resolve()), HELPER, str(self.base))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_android_runtime_classpath_publication(self):
        shell = shutil.which('mksh')
        if not shell:
            self.skipTest('mksh unavailable')
        result = self.run_case('android-runtime', shell, str(RUNTIME_SCRIPT))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_direct_profile_target(self):
        result = self.run_case('direct')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_versioned_profile_target(self):
        result = self.run_case('versioned')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_profile_selection_without_optional_nns_directories(self):
        result = self.run_case('direct-no-nns-dirs')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_absent_profile_is_not_selected(self):
        result = self.run_case('absent')
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_rejects_untrusted_generation_paths(self):
        for case in ('writable-store-parent', 'writable-store-group',
                     'writable-generation', 'writable-generation-other', 'mutable-target',
                     'symlink-generation', 'traversal'):
            with self.subTest(case=case):
                result = self.run_case(case)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_mksh_profile_selection(self):
        shell = shutil.which('mksh')
        if not shell:
            self.skipTest('mksh unavailable')
        for case in ('direct', 'versioned', 'writable-store-group', 'writable-generation-other'):
            with self.subTest(case=case):
                result = self.run_case(case, shell=shell)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
