#!/usr/bin/env python3
"""Reject stale/mixed FFmpeg artifacts and verify archive identity after signing."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load("ffmpeg_build", "Scripts/rebuild-ffmpeg-ios.py")
verify = load("ffmpeg_archive", "ci_scripts/verify_ffmpeg_archive.py")
selection = load("ffmpeg_selection", "Scripts/select-ffmpeg-build.py")


class CloudFFmpegTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="claw-ffmpeg-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stage = self.root / "staged"
        self.stage.mkdir()
        self.checkout = self.root / "checkout"
        self.target = self.checkout / "ThirdParty/Dependencies/FFmpeg"
        self.target.mkdir(parents=True)
        self.manifest = {"source_revision": build.PIN["revision"], "source_sha256": build.PIN["sha256"],
                         "script_sha256": build.sha256_file(Path(build.__file__)),
                         "slices": {platform: {"configure": ["--enable-gpl"]}
                                    for platform in ("iphoneos", "iphonesimulator")},
                         "binaries": {}, "binary_uuids": {}}
        for platform in self.manifest["slices"]:
            self.manifest["binaries"][platform] = {}
            self.manifest["binary_uuids"][platform] = {}
        for number, name in enumerate(build.LIBRARIES):
            library = "lib" + name
            old = self.target / (library + ".xcframework")
            old.mkdir()
            (old / "old-prebuilt").write_text("must survive a rejected install")
            slices = []
            for platform in ("iphoneos", "iphonesimulator"):
                identifier = "ios-arm64" + ("-simulator" if platform == "iphonesimulator" else "")
                framework = self.stage / f"{library}.xcframework" / identifier / f"{library}.framework"
                framework.mkdir(parents=True)
                binary = framework / library
                binary.write_bytes(f"test binary: {library} {platform}".encode())
                digest = build.sha256_file(binary)
                binary_uuid = f"00000000-0000-0000-0000-{number:012d}"
                self.manifest["binaries"][platform][name] = digest
                self.manifest["binary_uuids"][platform][name] = binary_uuid
                record = {"schema_version": 1, "source_repository": build.PIN["repository"],
                          "source_url": build.PIN["url"], "source_revision": build.PIN["revision"],
                          "source_sha256": build.PIN["sha256"], "script_sha256": self.manifest["script_sha256"],
                          "library": library, "platform": platform, "minimum_ios": "17.0",
                          "build": self.manifest["slices"][platform], "binary_sha256": digest,
                          "binary_uuid": binary_uuid}
                (framework / build.PROVENANCE_FILE).write_text(json.dumps(record))
                entry = {"LibraryIdentifier": identifier, "LibraryPath": f"{library}.framework",
                         "SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]}
                if platform == "iphonesimulator":
                    entry["SupportedPlatformVariant"] = "simulator"
                slices.append(entry)
            (self.stage / f"{library}.xcframework/Info.plist").write_bytes(
                plistlib.dumps({"AvailableLibraries": slices}))
        self.write_manifest()
        self.paths = patch.object(build, "ROOT", self.checkout)
        self.paths.start()
        self.addCleanup(self.paths.stop)

    def write_manifest(self):
        (self.stage / "provenance.json").write_text(json.dumps(self.manifest))

    def framework(self, name="avcodec", simulator=False):
        identifier = "ios-arm64-simulator" if simulator else "ios-arm64"
        return self.stage / f"lib{name}.xcframework/{identifier}/lib{name}.framework"

    def install(self):
        with patch.dict(os.environ, {"CI_XCODE_CLOUD": "TRUE"}), contextlib.redirect_stdout(io.StringIO()):
            build.install_for_cloud(self.stage)

    def assert_old_libraries_untouched(self):
        for name in build.LIBRARIES:
            self.assertTrue((self.target / f"lib{name}.xcframework/old-prebuilt").is_file())

    def archive(self):
        archive = self.root / "Claw.xcarchive"
        frameworks = archive / "Products/Applications/Claw.app/Frameworks"
        frameworks.mkdir(parents=True)
        for name in build.LIBRARIES:
            shutil.copytree(self.framework(name), frameworks / f"lib{name}.framework")
        return archive

    def uuid_reader(self, binary):
        record = json.loads((binary.parent / build.PROVENANCE_FILE).read_text())
        return record["binary_uuid"]

    def test_installs_both_slices_and_keeps_build_records(self):
        self.install()
        for name in build.LIBRARIES:
            installed = self.target / f"lib{name}.xcframework"
            self.assertFalse((installed / "old-prebuilt").exists())
            self.assertTrue((installed / f"ios-arm64/lib{name}.framework/{build.PROVENANCE_FILE}").is_file())
            self.assertTrue((installed / f"ios-arm64-simulator/lib{name}.framework/lib{name}").is_file())

    def test_local_install_is_refused(self):
        with patch.dict(os.environ, {"CI_XCODE_CLOUD": "FALSE"}), self.assertRaisesRegex(RuntimeError, "restricted"):
            build.install_for_cloud(self.stage)
        self.assert_old_libraries_untouched()

    def test_missing_last_simulator_record_prevents_all_replacements(self):
        (self.framework("swscale", True) / build.PROVENANCE_FILE).unlink()
        with self.assertRaises(FileNotFoundError):
            self.install()
        self.assert_old_libraries_untouched()

    def test_changed_binary_is_rejected_before_install(self):
        (self.framework() / "libavcodec").write_bytes(b"a different prebuilt binary")
        with self.assertRaisesRegex(RuntimeError, "binary/provenance mismatch"):
            self.install()
        self.assert_old_libraries_untouched()

    def test_wrong_source_and_recipe_are_rejected(self):
        for field in ("source_revision", "script_sha256"):
            previous = self.manifest[field]
            self.manifest[field] = "0" * len(previous)
            self.write_manifest()
            with self.assertRaises(RuntimeError):
                self.install()
            self.assert_old_libraries_untouched()
            self.manifest[field] = previous

    def test_wrong_architecture_is_rejected(self):
        path = self.stage / "libavcodec.xcframework/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["AvailableLibraries"][1]["SupportedArchitectures"] = ["x86_64"]
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(RuntimeError, "platform/architecture"):
            self.install()
        self.assert_old_libraries_untouched()

    def test_archive_accepts_signing_changes_with_same_uuid(self):
        archive = self.archive()
        binary = archive / "Products/Applications/Claw.app/Frameworks/libavcodec.framework/libavcodec"
        binary.write_bytes(binary.read_bytes() + b"changed signature bytes")
        report = verify.verify_archive(archive, self.uuid_reader)
        self.assertEqual(len(report["binaries"]), 7)
        self.assertNotEqual(report["binaries"][0]["archived_sha256"], self.manifest["binaries"]["iphoneos"]["avcodec"])

    def test_archive_rejects_old_binary_with_different_uuid(self):
        with self.assertRaisesRegex(RuntimeError, "different FFmpeg binary"):
            verify.verify_archive(self.archive(), lambda _: "00000000-0000-0000-0000-999999999999")

    def test_archive_rejects_missing_build_record(self):
        archive = self.archive()
        (archive / "Products/Applications/Claw.app/Frameworks/libavcodec.framework" / build.PROVENANCE_FILE).unlink()
        with self.assertRaisesRegex(RuntimeError, "missing source-built"):
            verify.verify_archive(archive, self.uuid_reader)

    def test_versioned_dylib_can_use_major_only_name(self):
        prefix = self.root / "installed"
        (prefix / "lib").mkdir(parents=True)
        binary = prefix / "lib/libavcodec.62.dylib"
        binary.write_bytes(b"installed library")
        self.assertEqual(build.dylib_for(prefix, "avcodec"), binary)

    def diagnostic_archive(self):
        archive = self.archive()
        app = archive / "Products/Applications/Claw.app"
        (app / "Info.plist").write_bytes(plistlib.dumps({"ClawFFmpegMode": "legacy-diagnostic", "CFBundleExecutable": "Claw"}))
        for name in build.LIBRARIES:
            framework = app / "Frameworks" / f"lib{name}.framework"
            record = json.loads((framework / build.PROVENANCE_FILE).read_text())
            (framework / build.PROVENANCE_FILE).unlink()
            record.update(mode="legacy-diagnostic", baseline_commit="14b50a2a939c65113b7196d1755f2399977248fd", release_candidate=False)
            (framework / "ClawFFmpegDiagnostic.json").write_text(json.dumps(record))
        return archive

    def test_diagnostic_archive_requires_matching_baseline_and_uuid(self):
        archive = self.diagnostic_archive()
        reader = lambda p: json.loads((p.parent / "ClawFFmpegDiagnostic.json").read_text())["binary_uuid"]
        report = verify.verify_archive(archive, reader)
        self.assertEqual(report["mode"], "legacy-diagnostic")
        self.assertFalse(report["release_candidate"])
        with self.assertRaisesRegex(RuntimeError, "does not match Build 102"):
            verify.verify_archive(archive, lambda _: "00000000-0000-0000-0000-999999999999")

    def test_diagnostic_archive_rejects_mixed_source_build(self):
        archive = self.diagnostic_archive()
        framework = archive / "Products/Applications/Claw.app/Frameworks/libavcodec.framework"
        (framework / build.PROVENANCE_FILE).write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "mixes source-built"):
            verify.verify_archive(archive)

    def test_mode_requires_explicit_supported_value_and_can_restore_source(self):
        policy = self.root / "policy.json"
        policy.write_text('{"mode":"legacy-diagnostic"}')
        with patch.object(selection, "POLICY", policy), patch.dict(os.environ, {"CLAW_FFMPEG_MODE": ""}):
            self.assertEqual(selection.selected_mode(), "legacy-diagnostic")
            with patch.dict(os.environ, {"CLAW_FFMPEG_MODE": "source"}):
                self.assertEqual(selection.selected_mode(), "source")
            with patch.dict(os.environ, {"CLAW_FFMPEG_MODE": "ignore-validation"}):
                with self.assertRaisesRegex(RuntimeError, "must be"):
                    selection.selected_mode()

    def test_runtime_check_rejects_missing_framework_dependency(self):
        archive = self.diagnostic_archive()
        commands = "cmd LC_RPATH\n path @executable_path/Frameworks (offset 12)\n"
        links = "libavcodec:\n @rpath/libmissing.framework/libmissing (compatibility version 1.0.0)\n"
        with patch.object(verify.subprocess, "check_output", side_effect=[commands, links]), patch.object(verify.subprocess, "run"):
            with self.assertRaisesRegex(RuntimeError, "Unresolvable archived dependency"):
                verify.verify_runtime_links(archive)

    def test_runtime_check_checks_all_seven_signatures_and_existing_links(self):
        archive = self.diagnostic_archive()
        commands = "cmd LC_RPATH\n path @executable_path/Frameworks (offset 12)\n"
        links = "library:\n @rpath/libavutil.framework/libavutil (compatibility version 1.0.0)\n /usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
        with patch.object(verify.subprocess, "check_output", side_effect=[commands]+[links]*7), patch.object(verify.subprocess, "run") as signing:
            verify.verify_runtime_links(archive)
        self.assertEqual(signing.call_count, 7)
        self.assertTrue(all(call.args[0][:3] == ["codesign", "--verify", "--strict"] for call in signing.call_args_list))

    def test_legacy_validation_rejects_a_changed_slice_before_writing_records(self):
        records=[]
        for name in build.LIBRARIES:
            binary=self.framework(name) / ("lib"+name)
            records.append({"path": str(binary.relative_to(self.root)), "sha256": build.sha256_file(binary)})
        manifests=self.root / "Distribution"; manifests.mkdir()
        (manifests / "ffmpeg-legacy-baseline.json").write_text(json.dumps({"baseline_commit":"baseline", "artifacts":records}))
        (self.framework("swscale") / "libswscale").write_bytes(b"changed binary")
        with patch.object(selection, "ROOT", self.root), patch.dict(os.environ, {"CI_XCODE_CLOUD":"TRUE"}):
            with self.assertRaisesRegex(RuntimeError, "baseline mismatch"):
                selection.prepare_legacy()
        self.assertEqual(list(self.stage.rglob("ClawFFmpegDiagnostic.json")), [])

    def test_configure_failure_emits_diagnostics_and_clears_wrong_sdk(self):
        cache = self.root / "build-cache"
        log = cache / "build/iphoneos/ffbuild/config.log"
        log.parent.mkdir(parents=True)
        log.write_text("compiler rejected a required feature")
        output = io.StringIO()
        with patch.object(build, "output", side_effect=["/selected/iphoneos.sdk", "/tools/clang", "/tools/clang++"]), \
             patch.object(build, "run", side_effect=subprocess.CalledProcessError(1, "configure")) as run, \
             patch.dict(os.environ, {"SDKROOT": "/wrong/simulator.sdk", "MACOSX_DEPLOYMENT_TARGET": "27.0", "CFLAGS": "-march=native"}), \
             contextlib.redirect_stdout(output), self.assertRaises(subprocess.CalledProcessError):
            build.build_slice(self.root / "source", cache, "iphoneos", 2)
        self.assertIn("compiler rejected a required feature", output.getvalue())
        self.assertNotIn("SDKROOT", run.call_args.kwargs["env"])
        self.assertNotIn("MACOSX_DEPLOYMENT_TARGET", run.call_args.kwargs["env"])
        self.assertNotIn("CFLAGS", run.call_args.kwargs["env"])


if __name__ == "__main__":
    unittest.main()
