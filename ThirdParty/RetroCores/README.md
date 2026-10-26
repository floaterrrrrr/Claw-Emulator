# Claw's additional bundled cores

mGBA provides GBA, GB and GBC; FCEUmm provides NES; melonDS DS provides DS.
The existing Cytrus 3DS implementation remains separate. Only the selected
signed framework is loaded, from the application's own Frameworks directory.
There is no runtime core download, executable-memory allocator or JIT option.

`sources.lock.json` records the full commit, original repository, archive URL and
SHA-256 for all 14 source trees, including the DS core's transitive dependencies.
`Scripts/build-retro-cores.py --sources-only` retrieves and verifies the matching
source into `.build-retro/sources`. `--platform all` builds ARM64 iPhoneOS and
Simulator frameworks with an iOS 17 deployment target. `--platform host` builds
the same core adapters for Linux functional testing; these are not iOS binaries.

`melondsds-no-pcap.patch` guards PCap-specific
includes/declarations/implementation so upstream's dynamic-library support can
be disabled. Emulated network modes are forced off. Upstream's networking types
and libslirp still compile, but no network mode or multiplayer is exposed.
The DS runtime uses the upstream BSD-licensed replacement BIOS/firmware in DS
mode, not commercial Nintendo BIOS dumps. DSi is outside this release's scope.
`mgba-ios-deployment.patch` prevents mGBA's legacy macOS minimum-version override
from changing the iOS deployment target. Both patches are included in the core
source identity and applied to the verified source before compilation.

CMake capability probes compile and link SDK executables without running them.
Compile-only static-library probes would report missing functions such as
`popcount32` as present and disable mGBA's portable fallback. Reconfiguration
clears cached `HAVE_*` results so a previously failed Cloud build is repaired.

The runtime scopes Clang's documentation-warning suppression to the external
libretro header, whose callback fields use function-style Doxygen comments.
Application warnings-as-errors are restored immediately after that include.

Preserve all upstream authors, copyright notices and licence conditions. mGBA is
MPL-2.0; FCEUmm is GPL-2.0-or-later; melonDS DS/melonDS are GPL-3.0-or-later.
Additional component/font/BIOS notices are in `App/Legal/RetroCoreLicenses.txt`.
Source archives plus the local patch and build scripts form the corresponding
source instructions. A public release must make the exact corresponding source
available to recipients as required; a private GitHub repository alone does not
provide recipients with that access. No licence to game ROMs is supplied.

Core-version-specific snapshots use a distinct CRS header (never passed to the
3DS loader), with game/core/build identity, size bounds, compression and CRC.
Battery saves are separate and survive snapshot-version changes. Source and
framework identities are written into each framework's SourceRevision.txt.
