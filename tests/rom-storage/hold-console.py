#!/usr/bin/env python3
"""Keep the VM console raw so boot output cannot echo back as shell commands."""
import os
from pathlib import Path
import sys
import time
import tty

lab = Path(sys.argv[1]).resolve(strict=True)
if lab.parent != Path('/home/jeeves/Builds/nns-rom/temporary/module-btrfs/storage-vm'):
    raise SystemExit('A disposable storage VM lab is required')
console = lab / 'runtime/cuttlefish/instances/cvd-1/console'
while True:
    try:
        descriptor = os.open(console, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except FileNotFoundError:
        time.sleep(0.25)
        continue
    try:
        tty.setraw(descriptor)
        identity = os.fstat(descriptor)
        while True:
            try:
                current = console.stat()
            except FileNotFoundError:
                break
            if (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino):
                break
            time.sleep(0.5)
    finally:
        os.close(descriptor)
