#!/usr/bin/env python3
"""Fail if the tracked release tree contains known console credentials or retail images."""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
tracked = set(subprocess.check_output(["git", "ls-files"], cwd=ROOT, text=True).splitlines())
required_licenses = {
    "LICENSE", "ThirdParty/Cytrus/LICENSE", "ThirdParty/SharedDependencies/LICENSE",
    "App/Legal/GPL-3.0.txt", "App/Legal/DependencyLicenses.txt",
    "App/Legal/RetroCoreLicenses.txt", "App/Legal/ThirdPartyNotices.txt",
}
missing_licenses = sorted(required_licenses - tracked)
if missing_licenses:
    raise SystemExit("Missing tracked license files:\n" + "\n".join(missing_licenses))
forbidden = {
    "ThirdParty/Cytrus/include/core/hw/default_keys.h",
    "ThirdParty/Cytrus/include/core/hle/service/http/ctr-common-1-key.h",
    "ThirdParty/Cytrus/include/core/hle/service/http/ctr-common-1-cert.h",
    "App/AutomaticCoverArt.swift",
}
game_extensions = {"3ds", "cia", "cci", "cxi", "3dsx", "nds", "gba", "gb", "gbc", "nes", "srl"}
violations = sorted(path for path in tracked if path in forbidden or
                    path.startswith("App/CommunityCheats/") or
                    Path(path).suffix.lower().lstrip(".") in game_extensions)
if violations:
    raise SystemExit("Forbidden tracked release files:\n" + "\n".join(violations))

source = (ROOT / "ThirdParty/Cytrus/core/hle/service/http/http_c.cpp").read_text()
if "ctr_common_1_key_bin" in source or "ctr_common_1_cert_bin" in source:
    raise SystemExit("The HTTP service still references bundled credentials")
if "AutomaticCoverArt.swift" in (ROOT / "Claw.xcodeproj/project.pbxproj").read_text():
    raise SystemExit("The Xcode project still references the removed cover downloader")
if any("libretro-thumbnails" in (ROOT / path).read_text(errors="ignore").lower()
       for path in tracked if path.startswith("App/") and Path(path).suffix == ".swift"):
    raise SystemExit("The app still references the remote cover catalogue")
print("PASS: no tracked console credentials, retail game images, cheat sheet or cover downloader")
