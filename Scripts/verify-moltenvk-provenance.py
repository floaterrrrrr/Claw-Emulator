#!/usr/bin/env python3
"""Verify the recorded Folium MoltenVK artifacts and bundled upstream notices."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
record = json.loads((ROOT / 'Distribution/moltenvk-provenance.json').read_text())
for artifact in record['artifacts']:
    blob = (ROOT / artifact['path']).read_bytes()
    if len(blob) != artifact['size']:
        raise SystemExit('MoltenVK size changed: ' + artifact['path'])
    sha = hashlib.sha256(blob).hexdigest()
    git_blob = hashlib.sha1(b'blob ' + str(len(blob)).encode() + b'\0' + blob).hexdigest()
    if sha != artifact['sha256'] or git_blob != artifact['upstream_git_blob']:
        raise SystemExit('MoltenVK identity changed; re-establish provenance: ' + artifact['path'])
notices = (ROOT / 'App/Legal/ThirdPartyNotices.txt').read_text(encoding='utf-8')
for license in record['license_texts']:
    body = (ROOT / license['path']).read_text(encoding='utf-8')
    if hashlib.sha256(body.encode()).hexdigest() != license['sha256_lf_utf8']:
        raise SystemExit('License content changed: ' + license['path'])
    if body.strip() not in notices:
        raise SystemExit('License missing from in-app notices: ' + license['path'])
for attribution in ['The Brenwill Workshop Ltd.', 'Copyright 2015-2021 Arm Limited']:
    if attribution not in notices:
        raise SystemExit('Missing MoltenVK/SPIRV-Cross attribution: ' + attribution)
print('PASS: both MoltenVK slices match pinned Folium blobs; licenses are included in app notices')
