#!/usr/bin/env python3
"""List explicit app-domain permissions in pinned Android policy sources."""

import re
import sys
from pathlib import Path

DIRECT_APP_ALLOW = re.compile(r"^\s*allow(?:xperm)?\s+(?:appdomain|untrusted_app_all|untrusted_app_27)\b")


def candidate_lines(repository: str, root: Path):
    for source in sorted(root.rglob("*.te")):
        relative = source.relative_to(root)
        if "prebuilts" in relative.parts:
            continue
        for line_number, line in enumerate(source.read_text().splitlines(), 1):
            if DIRECT_APP_ALLOW.match(line):
                yield f"{repository}/{relative}:{line_number}: {line.strip()}"


def main(arguments: list[str]):
    if len(arguments) % 2:
        raise SystemExit("expected repository/path pairs")
    print("# EvolutionX-16.0-20260808-cheetah-11.10-Official.zip")
    print("# OTA metadata: https://github.com/Evolution-X/OTA/blob/bka/builds/cheetah.json")
    print("# OTA SHA-256 from metadata (archive not fetched): dc362df5f1e229b80fed958d6e3ab35a257fe1e62365c8735dd8087c9d884e67")
    print("# Public revisions predate the OTA timestamp; the build manifest is not published.")
    print("# Explicit appdomain/untrusted_app_all/untrusted_app_27 allows only.")
    print("# M4 macros, attribute expansion, other policy inputs and vendor blobs are NOT included.")
    print("# Review candidates manually. This report is never applied as KernelSU policy.\n")
    for index in range(0, len(arguments), 2):
        for candidate in candidate_lines(arguments[index], Path(arguments[index + 1])):
            print(candidate)


if __name__ == "__main__":
    main(sys.argv[1:])
