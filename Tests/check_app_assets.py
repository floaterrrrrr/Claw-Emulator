# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import json
import plistlib
import re
import struct
import zlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root / "App/Info.plist").read_bytes())
assert re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"]), "Build number must be a positive integer"
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", info["CFBundleShortVersionString"])
palette = re.findall(r"case \.(\w+): return 0x([0-9A-Fa-f]{6})", (root / "App/AppIconPolicy.swift").read_text())
alternates = {"AppIcon" + name.capitalize() for name, _ in palette if name != "original"}
catalogs = list((root / "App/Assets.xcassets").glob("*.appiconset"))
assert {p.stem for p in catalogs} == alternates | {"AppIcon"}
hashes = set()
for catalog in catalogs:
    manifest = json.loads((catalog / "Contents.json").read_text())
    assert manifest["info"]["version"] == 1
    icons = [item for item in manifest["images"] if item.get("filename")]
    assert icons
    for item in icons:
        assert (item["idiom"], item["platform"], item["size"]) == ("universal", "ios", "1024x1024")
        data = (catalog / item["filename"]).read_bytes()
        hashes.add(hashlib.sha256(data).hexdigest())
        assert data[:8] == b"\x89PNG\r\n\x1a\n"
        offset = 8
        while offset < len(data):
            size = struct.unpack_from(">I", data, offset)[0]
            kind = data[offset + 4:offset + 8]
            payload = data[offset + 8:offset + 8 + size]
            crc = struct.unpack_from(">I", data, offset + 8 + size)[0]
            assert zlib.crc32(kind + payload) & 0xffffffff == crc
            if kind == b"IHDR":
                width, height, depth, color, *_ = struct.unpack(">IIBBBBB", payload)
                assert (width, height, depth, color) == (1024, 1024, 8, 2), f"{catalog.name} must be opaque RGB"
            assert kind != b"tRNS", "App icon must not contain transparency"
            offset += size + 12
        assert offset == len(data)
assert len(hashes) == len(catalogs), "Icon choices must have distinct artwork"
for project in ["project.yml", "Claw.xcodeproj/project.pbxproj", "Tests/FrontendHarness/project.yml"]:
    contents = (root / project).read_text()
    assert "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES" in contents
    assert "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS" in contents
    assert all(name in contents for name in alternates), f"Missing alternate icon setting in {project}"
print(f"PASS: Version {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}) plist, {len(catalogs)} distinct opaque icons and alternate-icon build settings")
