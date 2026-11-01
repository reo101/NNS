#!/usr/bin/env bash
set -euo pipefail
lab=$1
exec python3 "$lab/export/tests/rom-storage/hold-console.py" "$lab"
