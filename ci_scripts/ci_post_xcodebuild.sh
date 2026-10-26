#!/bin/bash
set -euo pipefail
if [[ "${CI_XCODEBUILD_EXIT_CODE:-1}" != 0 ]]; then
    echo 'The Xcode action failed; see the build log for the compiler/signing error.'
    exit 0
fi
if [[ "${CI_XCODEBUILD_ACTION:-}" != archive ]]; then
    exit 0
fi
python3 "$(dirname "$0")/verify_ffmpeg_archive.py" "${CI_ARCHIVE_PATH:?Cloud archive path is required}"
# This hook is self-contained because post-build scripts may run without the
# full repository. Archive paths and product identity come from Xcode Cloud.
python3 - <<'PY'
import os
import plistlib
import re
import subprocess
from pathlib import Path
archive = Path(os.environ["CI_ARCHIVE_PATH"])
apps = list((archive / "Products/Applications").glob("*.app"))
if len(apps) != 1:
    raise SystemExit("Expected one app in the Cloud archive")
app = apps[0]
info = plistlib.loads((app / "Info.plist").read_bytes())
expected = {
    "CFBundleIdentifier": os.environ.get("CLAW_BUNDLE_ID") or os.environ["CI_BUNDLE_ID"],
    "CFBundleDisplayName": "Claw", "MinimumOSVersion": "17.0", "UIDeviceFamily": [1],
    "CFBundleVersion": os.environ["CI_BUILD_NUMBER"],
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"Cloud archive has an unexpected {key}")
for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription"]:
    if not isinstance(info.get(key), str) or not info[key].strip():
        raise SystemExit(f"Cloud archive is missing the required privacy purpose string: {key}")
binaries = [app / info["CFBundleExecutable"]]
for framework in (app / "Frameworks").glob("*.framework"):
    details = plistlib.loads((framework / "Info.plist").read_bytes())
    binaries.append(framework / details["CFBundleExecutable"])
for binary in binaries:
    output = subprocess.check_output(["xcrun", "otool", "-l", str(binary)], text=True)
    versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+){0,2})", output, re.M)
    versions += re.findall(r"cmd LC_VERSION_MIN_IPHONEOS\n.*?\n\s*version\s+(\d+(?:\.\d+){0,2})", output)
    if not versions or any(tuple((list(map(int, v.split('.'))) + [0, 0])[:3]) > (17, 0, 0) for v in versions):
        raise SystemExit(f"Cloud archive dependency exceeds iOS 17: {binary.name}")
for name in ["PrivacyInfo.xcprivacy", "PrivacyPolicy.txt", "DependencyLicenses.txt", "GPL-3.0.txt"]:
    if not (app / name).is_file():
        raise SystemExit(f"Cloud archive is missing {name}")
privacy = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
reasons = {entry.get("NSPrivacyAccessedAPIType"): entry.get("NSPrivacyAccessedAPITypeReasons", [])
           for entry in privacy.get("NSPrivacyAccessedAPITypes", [])}
if "E174.1" not in reasons.get("NSPrivacyAccessedAPICategoryDiskSpace", []):
    raise SystemExit("Cloud archive is missing its import disk-space reason")
if "3B52.1" not in reasons.get("NSPrivacyAccessedAPICategoryFileTimestamp", []):
    raise SystemExit("Cloud archive is missing its document-picker file-metadata reason")
if (app / "CommunityCheats").exists():
    raise SystemExit("Cloud archive still bundles the removed game-specific cheat sheet")
if not re.fullmatch(r"[0-9a-f]{40}", info.get("ClawSourceCommit", "")):
    raise SystemExit("Cloud archive has no source commit identity")
if int(info.get("DTXcode", "0")) < 2600 or not re.fullmatch(r"iphoneos(?:2[6-9]|[3-9][0-9])\.\d+(?:\.\d+)?", info.get("DTSDKName", "")):
    raise SystemExit("Cloud archive needs Xcode 26 and iOS 26 SDK or later")
if not (archive / "dSYMs" / f"{app.name}.dSYM").is_dir():
    raise SystemExit("Cloud archive is missing the application dSYM")
print("PASS: Xcode Cloud archive identity, build number, iOS 17 deployment, privacy purposes/legal resources, and dSYM")
PY
