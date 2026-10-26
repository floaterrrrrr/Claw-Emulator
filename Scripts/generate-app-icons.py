#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Regenerate bundled alternate icons from the original Claw vector mark.

Requires Inkscape; generation is a developer task, never an app runtime task.
The palette is read from the same Swift policy used by Appearance settings.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
template = (root / "Scripts/Assets/claw-icon.svg").read_text()
policy = (root / "App/AppIconPolicy.swift").read_text()
palette = re.findall(r"case \.(\w+): return 0x([0-9A-Fa-f]{6})", policy)
with tempfile.TemporaryDirectory(prefix="claw-icons-") as temporary:
    directory = Path(temporary)
    environment = dict(os.environ, INKSCAPE_PROFILE_DIR=str(directory / "profile"),
                       XDG_CACHE_HOME=str(directory / "cache"))
    for name, rgb in palette:
        if name == "original":
            continue
        catalog = root / "App/Assets.xcassets" / f"AppIcon{name.capitalize()}.appiconset"
        catalog.mkdir(exist_ok=True)
        source = directory / f"{name}.svg"
        source.write_text(template.replace("__ACCENT__", "#" + rgb))
        subprocess.run([
            "inkscape", str(source), "--export-type=png", "--export-width=1024",
            "--export-height=1024", "--export-png-color-mode=RGB_8",
            "--export-filename=" + str(catalog / "Icon-1024.png"),
        ], check=True, env=environment)
        manifest = {
            "images": [{"filename": "Icon-1024.png", "idiom": "universal",
                        "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        }
        (catalog / "Contents.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Generated eight opaque alternate Claw icons")
