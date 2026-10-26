#!/usr/bin/env python3
"""Verify the source-built FFmpeg actually embedded in an Xcode Cloud archive.

Keep this helper in ci_scripts: Cloud can run post-build scripts without the
repository. The per-framework records survive in the downloadable app archive.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import plistlib

LIBRARIES = ("avcodec", "avdevice", "avfilter", "avformat", "avutil", "swresample", "swscale")


def read_uuid(binary):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(binary)], text=True)
    uuids = re.findall(r"UUID: ([0-9A-Fa-f-]{36}) \(arm64\)", output)
    if len(uuids) != 1:
        raise RuntimeError(f"Expected one arm64 UUID: {binary.name}")
    return uuids[0].lower()


def verify_archive(archive, uuid_reader=read_uuid):
    apps = list((archive / "Products/Applications").glob("*.app"))
    if len(apps) != 1:
        raise RuntimeError("Expected one app in the Cloud archive")
    info_file = apps[0] / "Info.plist"
    info = plistlib.loads(info_file.read_bytes()) if info_file.is_file() else {}
    if info.get("ClawFFmpegMode") == "legacy-diagnostic":
        return verify_legacy_archive(apps[0], uuid_reader)
    sources = set()
    binaries = []
    for name in LIBRARIES:
        library = "lib" + name
        framework = apps[0] / "Frameworks" / (library + ".framework")
        record_file = framework / "ClawFFmpegProvenance.json"
        if not record_file.is_file():
            raise RuntimeError(f"Archive is missing source-built FFmpeg provenance: {library}")
        record = json.loads(record_file.read_text())
        if (record.get("schema_version") != 1 or record.get("library") != library or
                record.get("platform") != "iphoneos" or record.get("source_repository") != "FFmpeg/FFmpeg" or
                record.get("minimum_ios") != "17.0" or
                not re.fullmatch(r"[0-9a-f]{40}", record.get("source_revision", "")) or
                record.get("source_url") != "https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/" + record["source_revision"] or
                any(not re.fullmatch(r"[0-9a-f]{64}", record.get(key, ""))
                    for key in ("source_sha256", "script_sha256", "binary_sha256"))):
            raise RuntimeError(f"Archive has invalid FFmpeg provenance: {library}")
        binary = framework / library
        identifier = uuid_reader(binary)
        if identifier != record.get("binary_uuid"):
            raise RuntimeError(f"Archive embedded a different FFmpeg binary: {library}")
        sources.add((record["source_revision"], record["source_sha256"], record["script_sha256"]))
        # CodeSign/strip can change SHA-256 while preserving the Mach-O UUID.
        binaries.append({"library": library, "uuid": identifier,
                         "archived_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()})
    if len(sources) != 1:
        raise RuntimeError("Archive mixes FFmpeg source builds")
    revision, source_hash, recipe_hash = sources.pop()
    return {"source_revision": revision, "source_sha256": source_hash,
            "script_sha256": recipe_hash, "binaries": binaries}


def verify_legacy_archive(app, uuid_reader):
    binaries = []
    baseline = "14b50a2a939c65113b7196d1755f2399977248fd"
    for name in LIBRARIES:
        library = "lib" + name
        framework = app / "Frameworks" / (library + ".framework")
        if (framework / "ClawFFmpegProvenance.json").exists():
            raise RuntimeError("Diagnostic archive mixes source-built and legacy FFmpeg")
        record = json.loads((framework / "ClawFFmpegDiagnostic.json").read_text())
        if (record.get("mode") != "legacy-diagnostic" or record.get("baseline_commit") != baseline or
                record.get("library") != library or record.get("platform") != "iphoneos" or
                record.get("release_candidate") is not False):
            raise RuntimeError("Invalid legacy diagnostic record: " + library)
        binary = framework / library
        identifier = uuid_reader(binary)
        if identifier != record.get("binary_uuid"):
            raise RuntimeError("Diagnostic archive does not match Build 102 FFmpeg: " + library)
        binaries.append({"library": library, "uuid": identifier,
                         "archived_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()})
    return {"mode": "legacy-diagnostic", "baseline_commit": baseline,
            "release_candidate": False, "binaries": binaries}


def verify_runtime_links(archive):
    """Check real archive signatures and every FFmpeg load-command destination."""
    app = next((archive / "Products/Applications").glob("*.app"))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = app / info["CFBundleExecutable"]
    commands = subprocess.check_output(["xcrun", "otool", "-l", str(executable)], text=True)
    if not re.search(r"path @(?:executable|loader)_path/Frameworks \(offset", commands):
        raise RuntimeError("App is missing its Frameworks runpath")
    for name in LIBRARIES:
        library = "lib" + name
        framework = app / "Frameworks" / (library + ".framework")
        binary = framework / library
        subprocess.run(["codesign", "--verify", "--strict", str(framework)], check=True)
        links = subprocess.check_output(["xcrun", "otool", "-L", str(binary)], text=True)
        for line in links.splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/usr/lib/", "/System/Library/")): continue
            if dependency.startswith("@rpath/"):
                target = app / "Frameworks" / dependency.removeprefix("@rpath/")
                if target.is_file() and target.resolve().is_relative_to((app / "Frameworks").resolve()): continue
            raise RuntimeError(f"Unresolvable archived dependency in {library}: {dependency}")
    return "All seven embedded FFmpeg signatures and load-command paths verified"


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: verify_ffmpeg_archive.py /path/to/Claw.xcarchive")
    report = verify_archive(Path(sys.argv[1]))
    report["runtime_link_checks"] = verify_runtime_links(Path(sys.argv[1]))
    print("CLAW_FFMPEG_ARCHIVE_BEGIN")
    print(json.dumps(report, indent=2))
    print("CLAW_FFMPEG_ARCHIVE_END")
    if report.get("mode") == "legacy-diagnostic":
        print("warning: PASS: archived FFmpeg matches Build 102; this is a diagnostic build, not a release candidate")
    else:
        print("PASS: archived FFmpeg UUIDs match the source-built frameworks")


if __name__ == "__main__":
    main()
