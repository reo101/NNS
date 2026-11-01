#!/usr/bin/env python3
"""Sync candidate Cheetah sources; export a full revision lock only on success."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

MINIMUM_FREE_BYTES = 150 * 1024**3
MANIFEST_REVISION = "871b8e82353de09027c69b8479324a41f02c976e"
USER_AGENT = "OpenAI File Downloader, XaiImageApiFetch/1.0"


def require_space(directory):
    if shutil.disk_usage(directory).free < MINIMUM_FREE_BYTES:
        raise RuntimeError("ROM build workspace has less than 150 GiB free")


def run(arguments, directory, environment, *, stdin=None, stdout=None):
    require_space(directory)
    print("Running:", " ".join(arguments), flush=True)
    process = subprocess.Popen(
        arguments, cwd=directory, env=environment, start_new_session=True,
        stdin=stdin, stdout=stdout
    )
    try:
        while process.poll() is None:
            require_space(directory)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                pass
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, arguments)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


def download_environment(directory):
    temporary = directory / "temporary"
    temporary.mkdir(exist_ok=True)
    environment = dict(os.environ, TMPDIR=str(temporary), GIT_TERMINAL_PROMPT="0",
                       GIT_HTTP_USER_AGENT=USER_AGENT, GIT_LFS_HTTP_USER_AGENT=USER_AGENT)
    # Scoped Git configuration, never changes the remote account's dotfiles.
    configuration = {"user.name": "ROM Source Validator",
                     "user.email": "rom-build@localhost", "http.userAgent": USER_AGENT,
                     "http.extraHeader": f"User-Agent: {USER_AGENT}"}
    environment["GIT_CONFIG_COUNT"] = str(len(configuration))
    for index, (key, value) in enumerate(configuration.items()):
        environment[f"GIT_CONFIG_KEY_{index}"] = key
        environment[f"GIT_CONFIG_VALUE_{index}"] = value
    curl_directory = directory / "http-config"
    curl_directory.mkdir(exist_ok=True)
    (curl_directory / ".curlrc").write_text(f'user-agent = "{USER_AGENT}"\n')
    environment["CURL_HOME"] = str(curl_directory)
    return environment


def main():
    directory = Path(sys.argv[1]).resolve(strict=True)
    source = directory / "source"
    source.mkdir(exist_ok=True)
    environment = download_environment(directory)
    run(["repo", "init", "-u", "https://github.com/Evolution-X/manifest",
         "-b", MANIFEST_REVISION, "--depth=1", "--git-lfs", "--no-clone-bundle",
         "--repo-rev=v2.66.1"], source, environment)
    manifests = source / ".repo/local_manifests"
    manifests.mkdir(exist_ok=True)
    shutil.copyfile(Path(__file__).with_name("cheetah-source.xml"),
                    manifests / "nns-cheetah.xml")
    run(["repo", "sync", "-c", "-j4", "--fail-fast", "--no-clone-bundle",
         "--no-tags"], source, environment)
    run(["repo", "manifest", "-r", "-o", str(directory / "source-manifest.xml")],
        source, environment)
    print("Source sync complete; source-manifest.xml records resolved revisions.",
          flush=True)


if __name__ == "__main__":
    main()
