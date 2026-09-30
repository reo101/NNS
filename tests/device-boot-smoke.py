#!/usr/bin/env python3
"""Check cheetah's NNS services across a reboot and first unlock."""

import argparse
import os
import shlex
import subprocess
import time


SERIAL = os.environ.get('ANDROID_SERIAL', '27211FDH3004Q4')
SSH_TARGET = 'nix-on-droid@cheetah.lan'
SERVER_SOCKET = '/data/nix/var/emacs-server/server'


def execute(arguments, timeout=10):
    try:
        return subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(arguments, 124, '', 'command timed out')


def adb(command):
    return execute(['adb', '-s', SERIAL, 'shell', command])


def root(command):
    return adb('su -c ' + shlex.quote(command))


def require(result, description):
    if result.returncode != 0:
        raise RuntimeError(f'{description}: {result.stderr.strip() or result.stdout.strip()}')
    return result.stdout.strip()


def wait_for(description, predicate, seconds=180):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(2)
    raise RuntimeError(f'Timed out waiting for {description}')


def prepare():
    previous_boot = require(adb('cat /proc/sys/kernel/random/boot_id'), 'read boot ID')
    require(execute(['adb', '-s', SERIAL, 'reboot']), 'reboot device')
    wait_for('new Android boot', lambda: (result := adb('cat /proc/sys/kernel/random/boot_id')).returncode == 0
             and result.stdout.strip() not in ('', previous_boot))

    def sshd_supervised():
        if adb('getprop sys.user.0.ce_available').stdout.strip() == 'true':
            raise RuntimeError('Device unlocked before pre-unlock checks completed')
        return root('test -p /data/nix/var/nns/services/sshd/supervise/control').returncode == 0

    wait_for('pre-unlock sshd supervision', sshd_supervised)
    require(root('test ! -e /data/nix/var/nns/ready/unlock'), 'unlock marker absent before unlock')
    require(root('test -p /data/nix/var/nns/services/emacs-socket/supervise/control'),
            'Emacs socket service supervised before unlock')
    print('Pre-unlock: sshd supervised; unlock marker absent; Emacs service gated.')
    print('Unlock cheetah, then run: python3 tests/device-boot-smoke.py verify', flush=True)


def verify():
    wait_for('credential-encrypted storage',
             lambda: adb('getprop sys.user.0.ce_available').stdout.strip() == 'true')
    wait_for('unlock marker', lambda: root('test -e /data/nix/var/nns/ready/unlock').returncode == 0)

    emacs_home = '/data/data/org.gnu.emacs/files'
    client_home = '/data/data/com.termux.nix/files/home'
    expected = ':'.join([
        require(root(f'stat -c %u {emacs_home}'), 'Emacs UID'),
        require(root(f'stat -c %g {client_home}'), 'NoD GID'),
        '2710',
        require(root(f'stat -c %C {emacs_home}'), 'Emacs SELinux label'),
    ])
    socket_dir = '/data/nix/var/emacs-server'
    wait_for('Emacs socket directory permissions', lambda: root(
        f'test "$(stat -c %u:%g:%a:%C {socket_dir} 2>/dev/null)" = {shlex.quote(expected)}'
    ).returncode == 0)

    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', '-p', '8022', SSH_TARGET]
    wait_for('NoD SSH login', lambda: execute(ssh + ['true']).returncode == 0)
    require(execute(ssh + [
        'NIX_CONF_DIR=/data/nix/etc/nix NIX_REMOTE=daemon '
        '/nix/var/nix/profiles/default/bin/nix '
        '--extra-experimental-features nix-command store info --store daemon'
    ]), 'query Nix daemon')
    require(adb('am start -n org.gnu.emacs/.EmacsActivity'), 'launch Android Emacs')
    wait_for('live Emacs server socket', lambda: root(
        f'test -S {SERVER_SOCKET} && grep -Fq {SERVER_SOCKET} /proc/net/unix'
    ).returncode == 0, seconds=90)
    client = '/nix/var/nix/profiles/default/bin/emacsclient'
    wait_for('responsive Emacs server', lambda: execute(ssh + [
        f"{client} -s {SERVER_SOCKET} --eval t"
    ], timeout=20).stdout.strip() == 't', seconds=90)
    graphical = require(execute(ssh + [
        f"{client} -s {SERVER_SOCKET} --eval '(display-graphic-p)'"
    ], timeout=20), 'connect to Android Emacs')
    if graphical != 't':
        raise RuntimeError(f'Android Emacs did not report a graphical display: {graphical}')
    print('Post-unlock: marker, SSH, Nix daemon, socket permissions, and graphical Emacs server passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare', 'verify'])
    arguments = parser.parse_args()
    try:
        {'prepare': prepare, 'verify': verify}[arguments.phase]()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'{error}\n')
