#!/usr/bin/env python3
"""Catch archive source drift between project.yml and the checked-in Xcode project."""

from pathlib import Path
import re

project = Path("Claw.xcodeproj/project.pbxproj").read_text()
target = re.search(r"[A-F0-9]{24} /\* ClawNative \*/ = \{(.*?)\n\t\t\};", project, re.S)
if not target:
    raise SystemExit("ClawNative target is missing from the checked-in Xcode project")
phase_id = re.search(r"([A-F0-9]{24}) /\* Sources \*/", target.group(1))
if not phase_id:
    raise SystemExit("ClawNative target has no source phase")
match = re.search(
    re.escape(phase_id.group(1)) + r" /\* Sources \*/ = \{.*?files = \((.*?)\);",
    project,
    re.S,
)
if not match:
    raise SystemExit("ClawNative source phase is missing from the checked-in Xcode project")
sources = match.group(1)
expected = ["ROMArchiveImport.c"] + sorted(
    path.name for path in Path("Native/SevenZipSDK").glob("*.c")
)
missing = [name for name in expected if f"/* {name} in Sources */" not in sources]
if missing:
    raise SystemExit(f"ClawNative is missing archive sources: {', '.join(missing)}")
if project.count("ThirdParty/SharedDependencies/Sources/miniz/include") != 2:
    raise SystemExit("ClawNative needs the miniz header path in Debug and Release")
print(f"PASS: checked-in ClawNative target includes all {len(expected)} archive sources")
