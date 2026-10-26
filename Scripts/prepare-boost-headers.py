#!/usr/bin/env python3
"""Use ABI-matched Boost 1.89 headers with the pinned libc++ 22 ICL fix."""

import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from verified_download import fetch_verified


ROOT = Path(__file__).resolve().parents[1]
HEADERS = ROOT / ".build-headers"
SOURCE = HEADERS / "boost-1.89.0"
LINK = HEADERS / "boost"


def matching_headers(expected_sha256):
    version = SOURCE / "boost/version.hpp"
    stamp = SOURCE / ".claw-source-sha256"
    return (version.is_file() and stamp.is_file() and
            stamp.read_text() == expected_sha256 and
            re.search(r'#define BOOST_LIB_VERSION "1_89"', version.read_text()) is not None)


def apply_icl_override(source, archive, item):
    """ICL is header-only; do not change iostreams/serialization's binary ABI."""
    stamp = source / ".claw-icl-source-sha256"
    adaptor = source / "boost/icl/detail/assoc_container_adaptor.hpp"
    if stamp.is_file() and stamp.read_text() == item["sha256"] and adaptor.is_file():
        return
    fetch_verified(item["url"], archive, item["sha256"])
    with tempfile.TemporaryDirectory(prefix="boost-icl-", dir=source.parent) as temporary:
        extracted = Path(temporary)
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(extracted),
                        "--strip-components=1"], check=True)
        headers = extracted / "include/boost/icl"
        if not (headers / "detail/assoc_container_adaptor.hpp").is_file():
            raise RuntimeError("Pinned Boost.ICL source is missing the libc++ lookup fix")
        stamp.unlink(missing_ok=True)
        destination = source / "boost/icl"
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(headers, destination)
        stamp.write_text(item["sha256"])


def main():
    item = json.loads((ROOT / "Distribution/binary-source-candidates.json").read_text())["boost-1.89.0"]
    HEADERS.mkdir(exist_ok=True)
    if not matching_headers(item["sha256"]):
        archive = HEADERS / "boost-1.89.0.tar.gz"
        fetch_verified(item["url"], archive, item["sha256"])
        with tempfile.TemporaryDirectory(prefix="boost-1.89.0-", dir=HEADERS) as temporary:
            extracted = Path(temporary)
            subprocess.run(["tar", "-xzf", str(archive), "-C", str(extracted),
                            "--strip-components=1"], check=True)
            version = extracted / "boost/version.hpp"
            if not version.is_file() or 'BOOST_LIB_VERSION "1_89"' not in version.read_text():
                raise RuntimeError("Downloaded Boost headers are not version 1.89.0")
            (extracted / ".claw-source-sha256").write_text(item["sha256"])
            if SOURCE.exists():
                shutil.rmtree(SOURCE)
            shutil.move(extracted, SOURCE)
    icl = json.loads((ROOT / "Distribution/header-sources.json").read_text())["boost-icl"]
    apply_icl_override(SOURCE, HEADERS / "boost-icl.tar.gz", icl)
    if LINK.is_symlink():
        LINK.unlink()
    elif LINK.exists():
        raise RuntimeError(f"Expected a symlink or empty path for {LINK}")
    LINK.symlink_to(SOURCE, target_is_directory=True)
    print(f"Using Boost 1.89.0 headers + header-only ICL fix {icl['revision']}")


if __name__ == "__main__":
    main()
