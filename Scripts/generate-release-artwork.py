#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the original Control Deck controller artwork."""
from pathlib import Path
import hashlib
import json
from PIL import Image, ImageDraw
import PIL

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "App/Assets.xcassets"
SCALE = 3
INK = (235, 240, 255, 255)
ACCENT = (178, 88, 240, 255)
PLATE = (26, 31, 46, 255)
EDGE = (71, 80, 108, 255)

# Original simple grid letterforms. No system or third-party font is embedded.
LETTERS = {
    "A": ["01110", "11011", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
}


def letter(draw, value, box, color=INK):
    x, y, w, h = box
    unit = min(w / 5, h / 7)
    x += (w - unit * 5) / 2
    y += (h - unit * 7) / 2
    for row, pixels in enumerate(LETTERS[value]):
        for col, bit in enumerate(pixels):
            if bit == "1":
                draw.rectangle((x + col * unit, y + row * unit,
                                x + (col + 1) * unit, y + (row + 1) * unit), fill=color)


def surface(width, height):
    image = Image.new("RGBA", (width * SCALE, height * SCALE))
    return image, ImageDraw.Draw(image)


def emit(name, image):
    folder = ASSETS / (name + ".imageset")
    folder.mkdir(parents=True, exist_ok=True)
    image.save(folder / (name + ".png"), optimize=False)
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": name + ".png", "idiom": "universal", "scale": "3x"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    return {"path": str((folder / (name + ".png")).relative_to(ROOT)),
            "sha256": hashlib.sha256((folder / (name + ".png")).read_bytes()).hexdigest()}



def make():
    records = []
    skin = {
        "name": "Control Deck", "creator": "Original project artwork", "background": "DeckLandscape",
        "mappingSize": {"width": 896, "height": 414},
        "screens": [{"x": 216, "y": 20, "width": 466, "height": 349},
                    {"x": 716, "y": 255, "width": 146, "height": 107}],
        "controls": [], "quickSave": {"x": 275, "y": 375, "width": 56, "height": 20},
        "quickLoad": {"x": 563, "y": 375, "width": 56, "height": 20}}
    controls = [("circle", "Thumbstick", 53, 235, 134, 134), ("dpad", "DPad", 57, 70, 125, 125),
                ("a", "A", 814, 108, 50, 50), ("b", "B", 764, 158, 50, 50),
                ("y", "Y", 710, 108, 50, 50), ("x", "X", 764, 57, 50, 50),
                ("l", "L", 22, 20, 54, 38), ("r", "R", 823, 20, 54, 38),
                ("start", "Start", 713, 24, 21, 21), ("select", "Select", 166, 24, 21, 21)]
    for key, label, x, y, w, h in controls:
        skin["controls"].append({"key": key, "asset": "Deck" + label,
                                 "frame": {"x": x, "y": y, "width": w, "height": h}})
        image, draw = surface(w, h)
        W, H = image.size
        if key in {"start", "select"}:
            draw.ellipse((1, 1, W - 2, H - 2), fill=PLATE, outline=EDGE, width=3)
            if key == "start":
                draw.polygon([(W * .40, H * .28), (W * .40, H * .72), (W * .73, H * .50)], fill=INK)
            else:
                for yy in [.38, .60]:
                    draw.line((W * .28, H * yy, W * .72, H * yy), fill=INK, width=4)
        elif key in {"l", "r"}:
            draw.rounded_rectangle((1, 1, W - 2, H - 2), radius=H / 2, fill=PLATE, outline=EDGE, width=3)
            letter(draw, label, (W * .39, H * .23, W * .22, H * .54))
        else:
            draw.ellipse((2, 2, W - 3, H - 3), fill=PLATE, outline=EDGE, width=3)
            if key == "circle":
                draw.ellipse((W * .21, H * .21, W * .79, H * .79), fill=ACCENT)
                draw.arc((W * .28, H * .28, W * .72, H * .72), 205, 315, fill=(223, 182, 251, 255), width=5)
            elif key == "dpad":
                for rotation in range(4):
                    arrow = Image.new("RGBA", image.size)
                    a = ImageDraw.Draw(arrow)
                    a.line((W / 2, H * .18, W / 2, H * .36), fill=INK, width=6)
                    a.line((W * .43, H * .25, W / 2, H * .18, W * .57, H * .25), fill=INK, width=6)
                    image.alpha_composite(arrow.rotate(rotation * 90))
            else:
                letter(draw, label, (W * .37, H * .29, W * .26, H * .42))
        records.append(emit("Deck" + label, image))
    background, draw = surface(896, 414)
    def rr(box, radius, **kw):
        draw.rounded_rectangle(tuple(v * SCALE for v in box), radius=radius * SCALE, **kw)
    rr((26, 62, 205, 390), 34, fill=(12, 16, 26, 180), outline=(40, 48, 70, 220), width=3)
    rr((695, 50, 880, 225), 34, fill=(12, 16, 26, 180), outline=(40, 48, 70, 220), width=3)
    for key in ["quickSave", "quickLoad"]:
        r = skin[key]; x, y, w, h = (r[k] * SCALE for k in ["x", "y", "width", "height"])
        draw.rounded_rectangle((x, y, x+w, y+h), radius=8*SCALE, fill=PLATE, outline=EDGE, width=3)
        # Directional arrows distinguish save and restore without embedding text/fonts.
        xx = x + w/2; yy = y + h/2
        delta = 1 if key == "quickSave" else -1
        draw.line((xx, yy-6*SCALE*delta, xx, yy+5*SCALE*delta), fill=INK, width=4)
        draw.line((xx-4*SCALE, yy+1*SCALE*delta, xx, yy+5*SCALE*delta, xx+4*SCALE, yy+1*SCALE*delta), fill=INK, width=4)
    # Game windows remain fully transparent in the artwork.
    for r in skin["screens"]:
        draw.rectangle(tuple(int(v*SCALE) for v in (r["x"], r["y"], r["x"]+r["width"], r["y"]+r["height"])), fill=(0,0,0,0))
    records.append(emit("DeckLandscape", background))
    folder = ROOT / "App/ControllerSkin"
    folder.mkdir(exist_ok=True)
    (folder / "control-deck.json").write_text(json.dumps(skin, indent=2) + "\n")
    (folder / "PROVENANCE.json").write_text(json.dumps({
        "name": "Control Deck", "created": "2026-10-15", "generator": "Scripts/generate-release-artwork.py",
        "pillow_version": PIL.__version__, "artwork_inputs": "Original geometric paths and letter grids only; no imported artwork or font files",
        "asset_license": "CC0-1.0 to the extent copyright applies; generator source GPL-3.0-or-later",
        "layout": "Functional positions preserve the existing control hit targets and 3DS viewport aspect ratios",
        "assets": records}, indent=2) + "\n")
    (folder / "CREDITS.txt").write_text("Control Deck: original artwork generated from geometric primitives and original letter grids.\nAsset source: Scripts/generate-release-artwork.py\nGenerated artwork: CC0-1.0 to the extent copyright applies.\nNo Atomic/Delta artwork or third-party fonts are included.\n")
    print("Generated original Control Deck resources.")


if __name__ == "__main__":
    make()
