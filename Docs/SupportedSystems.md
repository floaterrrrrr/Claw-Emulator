# Supported systems

Claw integrates six emulated systems. The table below identifies the cores and
native display formats used by this source snapshot.

| System | Core | Files | Display |
| --- | --- | --- | --- |
| 3DS | Existing Cytrus | `.3ds`, `.cci`, `.cxi`, `.app` | Existing runtime resolution/MetalFX settings |
| DS | melonDS DS / melonDS | `.nds`, `.srl` | Two native 256 × 192 screens |
| GBA | mGBA | `.gba` | Native 240 × 160 |
| GB | mGBA | `.gb` | Native 160 × 144 |
| GBC | mGBA | `.gbc` | Native 160 × 144 |
| NES | FCEUmm | `.nes` | Native 256 × 240, displayed at 4:3 |

All six use interpreters. DS is compiled with `ENABLE_JIT=OFF`; build auditing
rejects JIT sources/definitions. mGBA's Lua integration is disabled. FCEUmm uses
its 6502 interpreter. The 3DS interpreter build/exclusions are preserved.
The frontend explicitly reports JIT unavailable and has no executable-memory
service or runtime-download path. New Apple frontend code requires the existing
`DISABLE_JIT=1` and `STRICT_INTERPRETER=1` build definitions. This configuration
does not by itself establish App Store approval.

## Integration

The existing `Game` JSON remains readable; entries without `system` stay 3DS.
Imports choose the core from the extracted file extension. A system filter and
system labels distinguish the library entries. ZIP extraction and network cover
scraping are not added. Existing 3DS embedded-icon extraction and manual cover
import remain available; added systems can use manually imported cover images.

`GameEngine` dispatches frontend commands to the selected runtime. It leaves
the 3DS guest clock, renderer, audio implementation and save format unchanged.
Only the selected additional, bundled signed framework is opened. Loading,
unloading and joining use the frontend's existing serial lifecycle worker.

New cores run on their own paced worker. Software frames are converted to BGRA
and presented with ordinary Metal textures on a separate worker, with at most
two GPU submissions in flight. Display updates coalesce accelerated frames.
The audio producer resamples core PCM using the existing Apple converter into
a bounded output buffer; the hardware callback does not allocate or access
files. The native rate follows each core, 2× changes pitch, and 4× mutes game
audio, as in the existing frontend. These are speed targets, not guaranteed FPS.

Touch and external-controller input reuse the Claw controls. DS/3DS show both
screens and XY; GBA retains LR; GB/GBC/NES hide unsupported controls. The DS
touch surface maps to the lower half of the stacked core framebuffer.

## Saves

The shared confirmations, eight manual slots, three rotating five-minute
autosave slots, names, timestamps, history list and continuation prompts work
through the selected runtime. New imports have stable, system-specific save
identities based on their library UUID; duplicate imports intentionally have
separate saves. Original 3DS title IDs and existing saves are preserved.

New snapshot files use a distinct `CRS` version-1 header and include game, core,
source-build identity, payload bounds and CRC. The UI lists both formats, but
the runtimes do not interchange their state payloads. A version mismatch is
rejected before applying state. Core capture/restore must run at a coordinated
emulation boundary and can briefly interrupt emulation; compression, PNG
encoding and state-file I/O run on a separate disk task. State previews contain
the actual captured frame (DS main display), not generated artwork.

Battery RAM and RTC data live in `EmulationData/BatterySaves/<identity>/`.
They are snapshotted periodically and on joined shutdown, and written atomically
off the guest worker. Failed writes retain the last committed data and retry.
An unexpected existing save size is preserved and reported rather than erased.
Battery saves remain separate from version-sensitive snapshots. Force-quitting
before the next periodic write can lose the most recent battery-only changes.

## Building and validating on a Mac

1. Check out `feature/six-systems` and retain the existing local `.env` signing
   settings. Use a released Xcode with iOS 17+ SDK/device support.
2. Run `bash Scripts/prepare-macos.sh`. It builds the pinned source frameworks
   for ARM64 iPhoneOS and Apple Silicon Simulator, then generates the project.
   These cached builds are not committed binaries.
3. Open `Claw.xcodeproj`, select scheme `Claw`, and build/run locally.
   The app embeds and signs the cores without linking their overlapping public
   APIs into one executable. Archive builds stage their dSYMs as well.
4. Run `bash Scripts/test-frontend-ui.sh` for the real frontend/mocked-core
   Simulator suite, including the added-system controls and screen geometry.
5. Run `bash Scripts/archive-app-store.sh --unsigned` to check the full Apple
   compile/link/archive and bundled resources, or omit `--unsigned` for a local
   signed archive. This script does not upload or submit it.
6. Test your own compatible games on iPhone 14 and 17: input and DS touch, native
   frame/audio timing, 1×/2×/4×, background/resume, save/load/overwrite/delete,
   autosave/continuation, battery/RTC retention, rotation, and 3DS regressions.
   Use Instruments/device measurements for CPU, battery and thermals.

The existing Xcode Cloud post-clone hook also prepares these frameworks when
this branch is deliberately selected for a build. No GitHub Actions workflow
is added or dispatched. Do not replace the build in beta review to test this
development branch.

## Portable evidence and remaining limits

`bash Scripts/check-build.sh --portable` covers the existing portable checks,
six-system metadata/layouts and the concurrent stereo ring. With a C++23
compiler, zlib, CMake and LLVM ARM tools available,
`bash Scripts/test-six-systems.sh --real-cores` builds the exact pinned cores
and runs original homebrew fixtures on all five new systems. It checks video,
audio delivery, GBA input, save/preview/restore, CRC/version rejection, joined
stop/reopen, and GBA/GB/GBC battery retention. It does not establish retail-game
compatibility, audible device output, touch latency, Apple signing, GPU behavior
or sustained phone performance.

This development environment has no Apple SDK, Xcode or iOS Simulator. Apple
Objective-C++ compilation, Simulator UI execution, archive/signature validation
and on-device gameplay remain required before merging or uploading.

See [the source lock, patches and licences](../ThirdParty/RetroCores/README.md).
DS uses the upstream replacement BIOS in DS mode; DSi and networking are not
exposed. No commercial BIOS, game ROMs or retail artwork is included in this
integration. Corresponding-source delivery must accompany public distribution.
