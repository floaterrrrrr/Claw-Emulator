# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate the generated artwork and its transparent game-window openings."""
import hashlib
import json
from pathlib import Path
import struct
import zlib


def png(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    width, height, depth, color, compression, filtering, interlace = struct.unpack_from(">IIBBBBB", data, 16)
    assert depth == 8 and compression == filtering == interlace == 0
    return width, height, color


def alpha_rows(data):
    width, height, color = png(data)
    assert color == 6
    compressed = bytearray(); offset = 8
    while offset < len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        if data[offset + 4:offset + 8] == b"IDAT": compressed += data[offset + 8:offset + 8 + size]
        offset += size + 12
    raw = zlib.decompress(compressed); stride = width * 4
    assert len(raw) == (stride + 1) * height
    previous = bytearray(stride)
    for y in range(height):
        base = y * (stride + 1); kind = raw[base]
        row = bytearray(raw[base + 1:base + stride + 1])
        assert kind <= 4
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0; above = previous[x]
            upper_left = previous[x - 4] if x >= 4 else 0
            if kind == 1: predictor = left
            elif kind == 2: predictor = above
            elif kind == 3: predictor = (left + above) // 2
            elif kind == 4:
                p = left + above - upper_left
                distances = [abs(p - left), abs(p - above), abs(p - upper_left)]
                predictor = [left, above, upper_left][distances.index(min(distances))]
            else: predictor = 0
            row[x] = (row[x] + predictor) & 255
        previous = row
        yield row[3::4]

root = Path(__file__).resolve().parents[1]
folder = root / "App/ControllerSkin"
skin = json.loads((folder / "control-deck.json").read_text())
provenance = json.loads((folder / "PROVENANCE.json").read_text())
assert provenance["generator"] == "Scripts/generate-release-artwork.py"
names = {skin["background"]} | {entry["asset"] for entry in skin["controls"]}
assert len(skin["controls"]) == 10
assert len({entry["key"] for entry in skin["controls"]}) == 10
for asset in provenance["assets"]:
    path = root / asset["path"]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == asset["sha256"]
for name in names:
    directory = root / "App/Assets.xcassets" / (name + ".imageset")
    manifest = json.loads((directory / "Contents.json").read_text())
    entry = manifest["images"][0]
    assert entry["scale"] == "3x"
    assert png((directory / entry["filename"]).read_bytes())[2] == 6
landscape = (root / "App/Assets.xcassets/DeckLandscape.imageset/DeckLandscape.png").read_bytes()
assert png(landscape) == (2688, 1242, 6)
rects = [tuple(rect[key] * 3 for key in ("x", "y", "width", "height")) for rect in skin["screens"]]
visible = False
for row_number, alpha in enumerate(alpha_rows(landscape)):
    visible |= any(alpha)
    for x, y, w, h in rects:
        if y <= row_number < y + h: assert not any(alpha[x:x + w])
assert visible
assert not list((root / "App/Assets.xcassets").glob("Atomic*"))
print("PASS: original controller assets, hashes, transparent game windows")
