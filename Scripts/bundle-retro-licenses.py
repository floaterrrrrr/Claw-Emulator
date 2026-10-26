#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bundle notices from the exact locked core source trees, retaining attribution."""
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]
lock = json.loads((ROOT / 'ThirdParty/RetroCores/sources.lock.json').read_text())
sources = {e['name']: ROOT / '.build-retro/sources' / (e['name'] + '-' + e['revision']) for e in lock['sources']}
output = ['Claw additional emulator cores and dependencies',
          'Source identities, archive checksums, local patch and build instructions: ThirdParty/RetroCores in the corresponding source distribution.',
          'No game ROM licence or commercial Nintendo BIOS is supplied. Some notices also cover optional source components.', '']
seen = set()


def add(title, text):
    text = '\n'.join(line.rstrip() for line in text.strip().splitlines())
    if not text or text in seen: return
    seen.add(text); output.extend(['=' * 78, title, '=' * 78, text, ''])


for entry in lock['sources']:
    folder = sources[entry['name']]
    if not folder.is_dir(): raise SystemExit('Run build-retro-cores.py --sources-only first')
    output.extend([entry['name'] + ': ' + entry['repository'] + '/tree/' + entry['revision'], ''])
    for file in sorted(folder.iterdir()):
        if file.is_file() and re.match(r'(?i)^(license|licence|copying|copyright|copying\.txt|copying\.lib|copying\.lesser)(\..*)?$', file.name):
            add(entry['name'] + ' / ' + file.name, file.read_text(errors='replace'))

# The DS project's generated attribution includes nested Teakra, FreeBIOS,
# Dolphin, FatFS, AES, networking and image-library licences.
ds_build = ROOT / '.build-retro/build/host/ds/melondsds-LICENSE.txt'
if not ds_build.exists():
    ds_build = ROOT / '.build-retro/build/iphoneos/ds/melondsds-LICENSE.txt'
if not ds_build.exists(): raise SystemExit('Build the DS core once before bundling its generated notices')
add('melonDS DS complete upstream dependency notices', ds_build.read_text())
add('mGBA / inih', (sources['mgba'] / 'src/third-party/inih/LICENSE.txt').read_text())

# libretro-common licences are per file. Preserve the opening attribution and
# terms for every file in the pinned DS build recipe, plus the FCEUmm copy.
recipe = (sources['melondsds'] / 'cmake/libretro-common.cmake').read_text()
paths = sorted(set(re.findall(r'\$\{libretro-common_SOURCE_DIR\}/([^\s)]+\.[ch])', recipe)))
for path in paths:
    for name, base in [('libretro-common', sources['libretro-common']),
                       ('FCEUmm libretro-common', sources['fceumm'] / 'src/drivers/libretro/libretro-common')]:
        file = base / path
        if not file.exists(): continue
        text = file.read_text(errors='replace')
        prefix = text.split('#include', 1)[0]
        if 'Copyright' in prefix or 'copyright' in prefix:
            add(name + ' / ' + path, prefix)

# Preserve copyright/licence records embedded in the original Open Sans font
# files used solely by the core's error screen. No system font is redistributed.
for font in sorted((sources['melondsds'] / 'src/libretro/assets').glob('*.ttf')):
    data = font.read_bytes(); count = struct.unpack_from('>H', data, 4)[0]
    for i in range(count):
        tag, _, offset, _ = struct.unpack_from('>4sIII', data, 12 + i * 16)
        if tag != b'name': continue
        _, names, storage = struct.unpack_from('>HHH', data, offset)
        texts = {}
        for j in range(names):
            platform_id, _, language, name_id, size, at = struct.unpack_from('>6H', data, offset + 6 + j * 12)
            if name_id not in [0, 13, 14] or platform_id not in [0, 3] or language not in [0, 0x409]: continue
            texts[name_id] = data[offset + storage + at:offset + storage + at + size].decode('utf-16-be', errors='replace')
        for name_id, text in sorted(texts.items()): add(font.name + ' / name record ' + str(name_id), text)
        break

target = ROOT / 'App/Legal/RetroCoreLicenses.txt'
target.write_text('\n'.join(output), encoding='utf-8')
print('Bundled pinned core/dependency notices:', target.stat().st_size, 'bytes')
