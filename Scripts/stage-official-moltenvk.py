#!/usr/bin/env python3
"""Stage an official MoltenVK iOS release beside, never over, the app binary.

The upstream release contains only an iPhone device XCFramework slice. It can
be evaluated in an archive, but it cannot replace the simulator dependency.
"""

import argparse
import json
import shutil
import tarfile
from pathlib import Path

from verified_download import fetch_verified, sha256_file


ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / "Distribution/binary-source-candidates.json").read_text())["moltenvk-v1.4.2-official"]
RELEASE_PREFIX = "MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/"
DEVICE_BINARY = "ios-arm64/MoltenVK.framework/MoltenVK"


def copy_member(archive, name, destination):
    member = archive.getmember(name)
    if not member.isfile():
        raise RuntimeError(f"Expected regular file in official MoltenVK release: {name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with archive.extractfile(member) as source, destination.open("wb") as output:
        shutil.copyfileobj(source, output)
    destination.chmod(member.mode & 0o777)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=ROOT / ".build-dependencies/moltenvk-release")
    parser.add_argument("--output", type=Path, default=ROOT / ".build-dependencies/replacements/MoltenVK")
    args = parser.parse_args()
    cache = args.cache.resolve()
    output = args.output.resolve()
    release = fetch_verified(PIN["release_url"], cache / "MoltenVK-v1.4.2-ios.tar",
                             PIN["release_sha256"], max_bytes=64 * 1024 * 1024)
    source = fetch_verified(PIN["url"], cache / "MoltenVK-v1.4.2-source.tar.gz",
                            PIN["sha256"], max_bytes=32 * 1024 * 1024)
    output.mkdir(parents=True, exist_ok=True)
    framework = output / "MoltenVK.xcframework"
    if framework.exists():
        shutil.rmtree(framework)
    with tarfile.open(release) as members:
        for member in members.getmembers():
            if not member.name.startswith(RELEASE_PREFIX) or not member.isfile():
                continue
            relative = Path(member.name.removeprefix(RELEASE_PREFIX))
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError("Unsafe path in official MoltenVK release")
            copy_member(members, member.name, framework / relative)
        copy_member(members, "MoltenVK/LICENSE", output / "LICENSE")
    actual = sha256_file(framework / DEVICE_BINARY)
    if actual != PIN["device_binary_sha256"]:
        raise RuntimeError("Official MoltenVK device binary hash mismatch")
    (output / "provenance.json").write_text(json.dumps({
        "source_revision": PIN["revision"], "source_sha256": sha256_file(source),
        "release_sha256": sha256_file(release), "device_binary_sha256": actual,
        "status": "staged official v1.4.2 device build, not used by the app",
    }, indent=2) + "\n")
    print(f"Staged verified official MoltenVK v1.4.2 iPhone binary in {framework}")
    print("The app still uses its existing v1.4.3 framework. This release has no simulator slice.")


if __name__ == "__main__":
    main()
