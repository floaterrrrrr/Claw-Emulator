#!/usr/bin/env python3
"""Check the produced app bundle; does not validate Apple's account or review answers."""
import plistlib
import argparse
import json
import re
import subprocess
from pathlib import Path
from apple_deployment import verify_ios_deployment
from distribution_config import metadata as distribution_metadata

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("archive", nargs="?", type=Path, default=root / "build/AppStore/Claw.xcarchive")
parser.add_argument("--expected-build")
parser.add_argument("--expected-commit")
parser.add_argument("--expected-bundle")
parser.add_argument("--verify-signature", action="store_true", help="Require valid distribution signatures using macOS codesign")
args = parser.parse_args()
archive = args.archive
metadata = distribution_metadata()
if args.expected_build:
    metadata["build"] = args.expected_build
if args.expected_bundle:
    metadata["bundle_id"] = args.expected_bundle
expected_commit = args.expected_commit or subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
if not re.fullmatch(r"[0-9a-f]{40}", expected_commit):
    parser.error("Expected source commit must be a full Git commit")
apps = list((archive / "Products/Applications").glob("*.app"))
if len(apps) != 1:
    raise SystemExit("Expected exactly one application in the completed archive.")
app = apps[0]
info = plistlib.loads((app / "Info.plist").read_bytes())

expected = {
    "CFBundleDisplayName": metadata["display_name"],
    "CFBundleIdentifier": metadata["bundle_id"],
    "CFBundleShortVersionString": metadata["version"],
    "CFBundleVersion": metadata["build"],
    "ClawSourceCommit": expected_commit,
    "MinimumOSVersion": metadata["minimum_os"],
    "UIDeviceFamily": [1],
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"Archive {key}: expected {value!r}, got {info.get(key)!r}")
if not re.fullmatch(r"iphoneos(?:2[6-9]|[3-9][0-9])\.\d+(?:\.\d+)?", info.get("DTSDKName", "")):
    raise SystemExit("Archive must be built with the current minimum iOS 26 SDK or later")
if int(info.get("DTXcode", "0")) < 2600:
    raise SystemExit("Archive must be built with Xcode 26 or later")
# The linked emulator includes camera/microphone backends even when its startup
# profile selects blank/Null input. Apple's processing checks inspect linked APIs.
for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"]:
    if not isinstance(info.get(key), str) or not info[key].strip():
        raise SystemExit(f"Archive is missing the required privacy purpose string: {key}")
if not (app / info["CFBundleExecutable"]).is_file():
    raise SystemExit("The archived app is missing its executable.")
verify_ios_deployment(app / info["CFBundleExecutable"], metadata["minimum_os"])
for framework in (app / "Frameworks").glob("*.framework"):
    framework_info = plistlib.loads((framework / "Info.plist").read_bytes())
    verify_ios_deployment(framework / framework_info["CFBundleExecutable"], metadata["minimum_os"])
for name in ["ClawmGBA", "ClawNES", "ClawDS"]:
    framework = app / "Frameworks" / (name + ".framework")
    if not (framework / name).is_file():
        raise SystemExit(f"Missing bundled emulator core: {name}")
    revision = (framework / "SourceRevision.txt").read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", revision):
        raise SystemExit(f"Missing core source identity: {name}")
    policy = json.loads((framework / "CorePolicy.json").read_text())
    if policy.get("jit") is not False or policy.get("runtime_core_download") is not False:
        raise SystemExit(f"Invalid interpreter-only core policy: {name}")
    if not (archive / "dSYMs" / (name + ".framework.dSYM")).is_dir():
        raise SystemExit(f"Missing bundled core debug symbols: {name}")

manifest = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
source_manifest = plistlib.loads((root / "App/PrivacyInfo.xcprivacy").read_bytes())
if manifest != source_manifest:
    raise SystemExit("The archived privacy manifest differs from the source.")
for source in (root / "App/Legal").glob("*.txt"):
    if (app / source.name).read_bytes() != source.read_bytes():
        raise SystemExit(f"Missing or stale legal document: {source.name}")
if (app / "CommunityCheats").exists():
    raise SystemExit("The archive must not bundle a community cheat sheet.")
if not (archive / "dSYMs" / f"{app.name}.dSYM").is_dir():
    raise SystemExit("The archive is missing the app's debug symbols.")
if args.verify_signature:
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)
    entitlements = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(app)])
    policy = plistlib.loads(entitlements)
    if policy.get("get-task-allow") is not False:
        raise SystemExit("Distribution archive must disable debugger access")
    for entitlement in ["com.apple.security.cs.allow-jit", "dynamic-codesigning", "com.apple.private.cs.debugger"]:
        if policy.get(entitlement):
            raise SystemExit(f"Distribution archive has forbidden entitlement: {entitlement}")

print(f"PASS: {metadata['name']} {metadata['version']} ({metadata['build']}) archive: "
      "identity, iPhone-only target, executable, privacy purposes/legal resources, and dSYM")
print("Signing, upload eligibility, device gameplay, public URLs, and review answers require separate validation.")
