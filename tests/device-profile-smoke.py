#!/usr/bin/env python3
"""Test a staged Android launcher without activating or replacing the installed system."""
import argparse
from pathlib import Path
import shlex
import subprocess


NOD_HOME = '/data/data/com.termux.nix/files/home'
EMACS_HOME = '/data/data/org.gnu.emacs/files'
ETC = '/data/nix/var/daemon-etc'
INSTALLED = '/data/nix/bin/nix-enter'
IDENTITY = r'''
set -eu
[ "$NNS_PROFILE" = "$1" ]
[ "$(/system/bin/id -u)" = "$2" ]
[ "$(/system/bin/id -g)" = "$3" ]
[ "$HOME" = "$4" ]
[ "$PWD" = "$5" ]
[ -d /var/empty ]
[ "$(/system/bin/stat -c %u:%g:%a /var/empty)" = "$2:$3:755" ]
[ -z "$(/system/bin/ls -A /var/empty)" ]
/system/bin/touch /var/empty/namespace-marker
if [ "$2" != 0 ]; then
  /system/bin/grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status
  /system/bin/grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status
fi
printf 'identity uid=%s gid=%s HOME=%s PROFILE=%s\n' "$2" "$3" "$HOME" "$NNS_PROFILE"
if [ "$6" = tools ]; then
  [ "$(command -v git)" = "$NNS_PROFILE/bin/git" ]
  [ "$(command -v bash)" = "$NNS_PROFILE/bin/bash" ]
  git --version
  bash --noprofile --norc -c 'test "$HOME" = "$1"' profile-home "$HOME"
fi
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--launcher', type=Path, required=True)
    args = parser.parse_args()
    executable = args.launcher.resolve()
    header = executable.read_bytes()[:20]
    if header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[18:20], 'little') != 183:
        parser.error('--launcher must be the AArch64 Linux executable')

    def remote(arguments, check=True):
        result = subprocess.run(['adb', '-s', args.serial, 'shell', shlex.join(arguments)],
                                text=True, capture_output=True, timeout=45)
        if check and result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return result

    def shell(script, check=True):
        return remote(['/system/bin/sh', '-c', script], check)

    def snapshot():
        return shell('''
set -eu
/system/bin/sha256sum /proc/self/mountinfo /data/nix/etc/nix/nix.conf
for profile in system-profile nix-on-droid nns-system development; do
  printf '%s=' "$profile"
  if [ -L "/data/nix/var/nix/profiles/$profile" ]; then
    /system/bin/readlink "/data/nix/var/nix/profiles/$profile"
  else printf 'absent\n'; fi
done
for file in /data/nix/var/nix/daemon.pid /data/nix/var/nns/runsvdir.pid /data/nix/var/nns/supervisor.pid /data/nix/var/sshd/sshd.pid; do
  printf '%s=' "$file"
  if [ -f "$file" ]; then /system/bin/cat "$file"; else printf 'absent\n'; fi
done
if [ -e /var ] || [ -L /var ]; then /system/bin/stat -c '%n %u:%g %a' /var; fi
''').stdout

    if remote(['/system/bin/id', '-u']).stdout.strip() != '0':
        parser.error('the selected adbd shell must already have root access')
    if remote(['/system/bin/getprop', 'ro.product.device']).stdout.strip() != 'cheetah':
        parser.error('this test is limited to cheetah')
    before = snapshot()
    work = remote(['/system/bin/mktemp', '-d', '/data/nix/var/nns-validation.XXXXXXXX']).stdout.strip()
    if not work.startswith('/data/nix/var/nns-validation.') or '/' in work.rsplit('/', 1)[1]:
        raise RuntimeError('invalid temporary directory returned by device')
    try:
        remote(['/system/bin/chmod', '755', work])
        subprocess.run(['adb', '-s', args.serial, 'push', str(executable), work + '/nix-enter'],
                       check=True, capture_output=True, text=True, timeout=30)
        remote(['/system/bin/chmod', '755', work + '/nix-enter'])

        def namespace(script, check=True):
            return remote([work + '/nix-enter', '--etc', ETC, '--', '/system/bin/sh', '-c', script], check)

        nod, infrastructure = namespace(
            f'/system/bin/readlink -f {shlex.quote(NOD_HOME)}/.nix-profile; '
            '/system/bin/readlink -f /nix/var/nix/profiles/system-profile').stdout.splitlines()
        if not all(path.startswith('/nix/store/') and '\n' not in path for path in (nod, infrastructure)):
            raise RuntimeError('existing environments did not resolve into the store')
        identities = [(0, 0, work + '/root-home')]
        for home in (NOD_HOME, EMACS_HOME):
            uid, gid = map(int, remote(['/system/bin/stat', '-c', '%u:%g', home]).stdout.strip().split(':'))
            identities.append((uid, gid, home))
        backing = work + '/backing'
        profiles = backing + '/var/nix/profiles'
        shell('set -eu; ' + '; '.join([
            shlex.join(['/system/bin/mkdir', '-p', backing + '/store', profiles, identities[0][2]]),
            shlex.join(['/system/bin/ln', '-s', nod, profiles + '/development-1-link']),
            shlex.join(['/system/bin/ln', '-s', infrastructure, profiles + '/development-2-link']),
            shlex.join(['/system/bin/ln', '-s', 'development-1-link', profiles + '/development']),
            shlex.join(['/system/bin/ln', '-s', infrastructure, profiles + '/system-profile']),
        ]))
        remote(['/system/bin/mkdir', '-p', work + '/client-conf'])
        shell("printf '%s\\n' 'experimental-features = nix-command' > " + shlex.quote(work + '/client-conf/nix.conf'))
        daemon_failures = []
        for uid, gid, home in identities:
            scratch = work + f'/scratch-{uid}'
            remote(['/system/bin/mkdir', '-p', scratch])
            remote(['/system/bin/chown', f'{uid}:{gid}', scratch])
            remote(['/system/bin/chmod', '700', scratch])

            def selected(options, target, tools=True, check=True):
                child = [infrastructure + '/bin/chpst', '-u', f':{uid}:{gid}', '/system/bin/env', 'HOME=' + home, 'NIX_REMOTE=daemon',
                         work + '/nix-enter', '--store', backing, '--etc', ETC, '--tmpdir', scratch,
                         *options, '--', '/system/bin/sh', '-c', IDENTITY, 'profile-smoke',
                         target, str(uid), str(gid), home, work, 'tools' if tools else 'identity']
                script = ('set -eu; cd ' + shlex.quote(work) + '; ' +
                          shlex.join(['/system/bin/mount', '--bind', '/data/nix/store', backing + '/store']) +
                          '; exec ' + shlex.join(child))
                return namespace(script, check)

            print(selected(['--profile', 'development'], nod).stdout, end='')
            print(selected(['--profile', 'development', '--generation', '1'], nod).stdout, end='')
            print(selected(['--profile', 'development', '--generation', '2'], infrastructure, False).stdout, end='')
            print(selected(['--profile', nod], nod).stdout, end='')
            for options in (['--profile', 'missing'], ['--profile', 'development', '--generation', '0'],
                            ['--profile', home]):
                rejected = selected(options, nod, check=False)
                if rejected.returncode == 0:
                    raise RuntimeError(f'invalid selection accepted: {options}')
            ping = [infrastructure + '/bin/chpst', '-u', f':{uid}:{gid}', '/system/bin/env', 'HOME=' + home,
                    'NIX_CONF_DIR=' + work + '/client-conf', 'NIX_USER_CONF_FILES=/dev/null',
                    work + '/nix-enter', '--etc', ETC, '--tmpdir', scratch, '--profile', nod, '--',
                    infrastructure + '/bin/nix', '--extra-experimental-features', 'nix-command',
                    'store', 'info', '--store', 'daemon']
            response = namespace(shlex.join(ping), check=False)
            if response.returncode:
                daemon_failures.append((uid, response.stderr.strip() or response.stdout.strip()))
            print(f'daemon uid={uid}: ' + ('PASS' if response.returncode == 0 else daemon_failures[-1][1]))

        remote(['/system/bin/ln', '-sfn', 'development-2-link', profiles + '/development'])
        print(selected(['--profile', 'development'], infrastructure, False).stdout, end='')
        print(selected(['--profile', nod], nod).stdout, end='')

        # A generated test host key and isolated NSS files, no listener or production key access.
        ssh = work + '/ssh'
        script = f'''
set -eu
umask 077
/system/bin/mkdir -p {ssh}/etc
printf '%s\\n' 'root:x:0:0:root:{work}/root-home:/system/bin/sh' \
  'sshd:x:9999:9999:sshd:/var/empty:/system/bin/sh' > {ssh}/etc/passwd
printf '%s\\n' 'root:x:0:' 'sshd:x:9999:' > {ssh}/etc/group
{nod}/bin/ssh-keygen -q -t ed25519 -N '' -f {ssh}/key
printf '%s\\n' 'HostKey {ssh}/key' 'UsePAM no' 'PidFile {ssh}/pid' > {ssh}/config
exec {work}/nix-enter --etc {ssh}/etc -- {nod}/bin/sshd -t -f {ssh}/config
'''
        print(namespace(script).stdout, end='')
        print('PASS: root and numeric app UID profiles, generations, HOME, cwd, private /var/empty, stock sshd -t')
        if daemon_failures:
            raise RuntimeError(f'isolated client configuration could not reach the existing daemon: {daemon_failures}')
        print('UID probes inherit adbd\'s SELinux domain. Native app-domain execution is a separate test.')
    finally:
        remote(['/system/bin/rm', '-r', '--', work])
        if snapshot() != before:
            raise RuntimeError('production mount table, configuration, profile pointers, or service PIDs changed')


if __name__ == '__main__':
    main()
