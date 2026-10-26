#!/usr/bin/env python3
"""Verify the ICL overlay preserves Boost binary headers and refreshes old caches."""
from hashlib import sha256
import importlib.util
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
spec = importlib.util.spec_from_file_location("boost_headers", ROOT / "Scripts/prepare-boost-headers.py")
headers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(headers)


class BoostHeadersTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="claw-boost-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "boost-1.89.0"
        (self.source / "boost/icl").mkdir(parents=True)
        (self.source / "boost/icl/obsolete.hpp").write_text("old ICL")
        (self.source / "boost/iostreams").mkdir()
        (self.source / "boost/iostreams/keep.hpp").write_text("1.89 ABI headers")
        self.archive = self.root / "icl.tar.gz"
        with tarfile.open(self.archive, "w:gz") as tar:
            data = b"pinned heterogeneous lookup fix"
            member = tarfile.TarInfo("icl-commit/include/boost/icl/detail/assoc_container_adaptor.hpp")
            member.size = len(data)
            tar.addfile(member, io.BytesIO(data))
        self.item = {"url": "https://example.invalid/unused",
                     "sha256": sha256(self.archive.read_bytes()).hexdigest()}

    def apply(self):
        headers.apply_icl_override(self.source, self.archive, self.item)

    def test_old_cache_is_replaced_but_binary_headers_stay_unchanged(self):
        self.apply()
        self.assertFalse((self.source / "boost/icl/obsolete.hpp").exists())
        self.assertTrue((self.source / "boost/icl/detail/assoc_container_adaptor.hpp").is_file())
        self.assertEqual((self.source / "boost/iostreams/keep.hpp").read_text(), "1.89 ABI headers")
        self.assertEqual((self.source / ".claw-icl-source-sha256").read_text(), self.item["sha256"])

    def test_matching_cache_needs_no_download_and_missing_header_is_repaired(self):
        self.apply()
        with patch.object(headers, "fetch_verified", side_effect=AssertionError("unnecessary fetch")):
            self.apply()
        (self.source / "boost/icl/detail/assoc_container_adaptor.hpp").unlink()
        self.apply()
        self.assertTrue((self.source / "boost/icl/detail/assoc_container_adaptor.hpp").is_file())

    def test_failed_copy_has_no_success_stamp_and_can_be_retried(self):
        self.apply()
        (self.source / ".claw-icl-source-sha256").write_text("older source")
        with patch.object(headers.shutil, "copytree", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.apply()
        self.assertFalse((self.source / ".claw-icl-source-sha256").exists())
        self.apply()
        self.assertTrue((self.source / "boost/icl/detail/assoc_container_adaptor.hpp").is_file())


if __name__ == "__main__":
    unittest.main()
