# Original core fixtures

`Tests/make-retro-fixtures.py` generates five original homebrew test images in
a temporary directory. The ARM assembly sources and generated LR35902/6502
programs are dedicated to the public domain under CC0-1.0. The generator itself
retains its SPDX licence. No commercial game, game screenshot, Nintendo logo
bitmap, BIOS or firmware dump is supplied by these fixtures.

GBA fills a red framebuffer, turns blue while A is held, changes its hardware
PWM audio clock from 32768 to 65536 Hz while B is held, and increments SRAM
to test autodetected save-size retention. GB/GBC enable MBC1
RAM, initialize a battery byte, and increment it when the game is reopened.
NES initializes its PPU backdrop. DS directly boots an original ARM9 program
that fills the main display; its ARM7 program loops. Functional file signatures
and headers let the upstream cores identify each format.

Generating the ARM programs requires LLVM `clang` and `ld.lld` with ARM support.
Use `CLAW_ARM_CLANG` and `CLAW_ARM_LD` for explicit paths. Test ROMs and build
outputs are not shipped in Claw.
Pass `--no-arm` to generate only the GB, GBC, and NES fixtures on a machine
without those ARM tools.
