#!/usr/bin/env python3
"""Bundle a Git commit and its checksum-pinned upstream source archives.

This bundle is not yet a complete Corresponding Source offer: see
Distribution/source-readiness.md for binary dependencies still needing provenance.
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from verified_download import fetch_verified


ROOT = Path(__file__).resolve().parents[1]


def pinned_sources():
    dependencies = json.loads((ROOT / "Distribution/dependency-sources.json").read_text())
    retro = json.loads((ROOT / "ThirdParty/RetroCores/sources.lock.json").read_text())
    data = json.loads((ROOT / "Distribution/bundled-data-sources.json").read_text())
    candidates = json.loads((ROOT / "Distribution/binary-source-candidates.json").read_text())
    headers = json.loads((ROOT / "Distribution/header-sources.json").read_text())
    entries = [(f"dependencies/{name}", item) for name, item in dependencies.items()]
    entries += [(f"retro/{item['name']}", item) for item in retro["sources"]]
    entries += [(f"data/{name}", item) for name, item in data.items()]
    entries += [(f"binary-candidates/{name}", item) for name, item in candidates.items()]
    entries += [(f"headers/{name}", item) for name, item in headers.items()]
    if len({name for name, _ in entries}) != len(entries):
        raise ValueError("Duplicate source name in source manifests")
    for name, item in entries:
        if not item["url"].startswith("https://") or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
            raise ValueError(f"Unpinned or non-HTTPS source: {name}")
        if not re.fullmatch(r"[0-9a-f]{40}", item["revision"]):
            raise ValueError(f"Source has no exact revision: {name}")
    return sorted(entries)


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def download(item, target):
    fetch_verified(item["url"], target, item["sha256"], max_bytes=384 * 1024 * 1024)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write a ZIP with this Git commit and pinned source archives")
    parser.add_argument("--cache", type=Path, default=ROOT / ".build-dependencies/source-archives")
    parser.add_argument("--fetch-only", action="store_true", help="Verify/cache source archives before the final commit")
    args = parser.parse_args()
    entries = pinned_sources()
    print(f"Verified manifests for {len(entries)} pinned upstream source archives")
    if args.fetch_only:
        if args.output:
            parser.error("Use --fetch-only or --output")
        for name, item in entries:
            download(item, args.cache / f"{item['sha256']}.tar.gz")
            print(f"Verified {name}", flush=True)
        return
    if args.output is None:
        return
    subprocess.run([sys.executable, "Scripts/audit-public-tree.py"], cwd=ROOT, check=True)
    if git("status", "--porcelain"):
        parser.error("Commit or discard local changes before packaging an exact source revision")
    commit = git("rev-parse", "HEAD")
    destination = args.output.resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="claw-source-", dir=destination.parent) as temporary:
        temporary = Path(temporary)
        repository = temporary / "repository.tar"
        with repository.open("wb") as output:
            subprocess.run(["git", "archive", "--format=tar", "HEAD"], cwd=ROOT,
                           stdout=output, check=True)
        staged = temporary / "source-bundle.zip"
        with zipfile.ZipFile(staged, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
            bundle.write(repository, "repository.tar")
            for name, item in entries:
                archive = args.cache / f"{item['sha256']}.tar.gz"
                download(item, archive)
                bundle.write(archive, f"upstream/{name}.tar.gz")
                print(f"Verified {name}", flush=True)
            manifest = {
                "repository_commit": commit,
                "pinned_sources": {name: {key: item[key] for key in ("url", "revision", "sha256")}
                                   for name, item in entries},
                "corresponding_source_complete": False,
                "binary_candidates_unverified": sorted(name for name, _ in entries
                                                       if name.startswith("binary-candidates/")),
                "remaining_review": "See repository.tar:Distribution/source-readiness.md",
            }
            bundle.writestr("SOURCE_MANIFEST.json", json.dumps(manifest, indent=2) + "\n")
        staged.replace(destination)
    print(f"Wrote {destination} for {commit}; unresolved source/license gates remain")


if __name__ == "__main__":
    main()
