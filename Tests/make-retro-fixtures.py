#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build small original test ROMs. No retail games, Nintendo logo image or BIOS."""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parent


def arm(source, base, destination, tools):
    obj = destination.with_suffix('.o')
    subprocess.run([tools[0], '--target=arm-none-eabi', '-c', str(source), '-o', str(obj)], check=True)
    subprocess.run([tools[1], '-Ttext=' + base, '--entry=_start', '--oformat=binary', str(obj), '-o', str(destination)], check=True)
    return bytearray(destination.read_bytes())


def crc16(data):
    result = 0xffff
    for value in data:
        result ^= value
        for _ in range(8):
            result = (result >> 1) ^ (0xa001 if result & 1 else 0)
    return result


def generate(out, tools):
    out.mkdir(parents=True, exist_ok=True)
    if tools:
        gba = arm(ROOT / 'RetroFixtures/gba.S', '0x08000000', out / 'fixture.gba', tools)
        gba += bytes(max(0, 32768 - len(gba)))
        gba[0xa0:0xac] = b'CLAW TEST   '
        gba[0xb2] = 0x96
        gba[0xbd] = (-sum(gba[0xa0:0xbd]) - 0x19) & 255
        (out / 'fixture.gba').write_bytes(gba)
    for ext in ['gb', 'gbc']:
        gb = bytearray(32768)
        gb[0x100:0x104] = bytes([0, 0xc3, 0x50, 1])
        # Four-byte container recognition signature; the logo bitmap is absent.
        gb[0x104:0x108] = bytes([0xce, 0xed, 0x66, 0x66])
        gb[0x134:0x13d] = b'CLAW TEST'
        gb[0x143] = 0x80 if ext == 'gbc' else 0
        gb[0x147] = 3  # MBC1 + RAM + battery
        gb[0x149] = 2  # 8 KiB RAM
        # Enable RAM, initialize an erased save to 0x42, increment on reopening.
        program = bytes([0xf3, 0x31, 0xfe, 0xff, 0x3e, 0x0a, 0xea, 0, 0,
                         0xfa, 0, 0xa0, 0xfe, 0xff, 0x20, 4, 0x3e, 0x41, 0x18, 0,
                         0x3c, 0xea, 0, 0xa0,
                         0x3e, 0xe4, 0xe0, 0x47, 0x3e, 0x91, 0xe0, 0x40, 0x18, 0xfe])
        gb[0x150:0x150 + len(program)] = program
        gb[0x14d] = (-sum(gb[0x134:0x14d]) - 0x19) & 255
        struct.pack_into('>H', gb, 0x14e, (sum(gb) - gb[0x14e] - gb[0x14f]) & 0xffff)
        (out / ('fixture.' + ext)).write_bytes(gb)
    prg = bytearray([0xea] * 16384)
    # Mask interrupts, wait for vblank, set universal backdrop red, then loop.
    program = bytes.fromhex('78 d8 a2 ff 9a a9 00 8d 00 20 8d 01 20 2c 02 20 10 fb a9 3f 8d 06 20 a9 00 8d 06 20 a9 16 8d 07 20 4c 21 80')
    prg[:len(program)] = program
    for offset in [0x3ffa, 0x3ffc, 0x3ffe]: struct.pack_into('<H', prg, offset, 0x8000)
    (out / 'fixture.nes').write_bytes(b'NES\x1a' + bytes([1, 1]) + bytes(10) + prg + bytes(8192))
    if tools:
        arm9 = arm(ROOT / 'RetroFixtures/nds-arm9.S', '0x02000000', out / 'arm9.bin', tools)
        arm7 = struct.pack('<I', 0xeafffffe)
        nds = bytearray(0x10000)
        nds[:12] = b'CLAW DS TEST'
        nds[12:16] = b'####'  # homebrew, not a retail title identifier
        struct.pack_into('<4I', nds, 0x20, 0x200, 0x02000000, 0x02000000, len(arm9))
        struct.pack_into('<4I', nds, 0x30, 0x400, 0x03800000, 0x03800000, len(arm7))
        struct.pack_into('<2I', nds, 0x80, len(nds), 0x200)
        nds[0x200:0x200+len(arm9)] = arm9
        nds[0x400:0x400+len(arm7)] = arm7
        struct.pack_into('<H', nds, 0x15e, crc16(nds[:0x15e]))
        (out / 'fixture.nds').write_bytes(nds)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    parser.add_argument('--no-arm', action='store_true', help='Generate GB/GBC/NES without an ARM assembler')
    args = parser.parse_args()
    tools = None if args.no_arm else [os.environ.get('CLAW_ARM_CLANG') or shutil.which('clang'), os.environ.get('CLAW_ARM_LD') or shutil.which('ld.lld')]
    if tools is not None and not all(tools): raise SystemExit('Fixture generation requires clang and ld.lld with ARM support; use --no-arm for GB/GBC/NES only.')
    generate(args.output, tools)
