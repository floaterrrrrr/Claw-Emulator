# Building Claw

## Requirements

- macOS with a released Xcode and its command-line tools.
- An iOS 17 or later SDK and an iPhone for signed-device testing.
- Python 3, Homebrew, CMake, and XcodeGen.
- Your own Apple development team and bundle identifier for signed installation.

The frontend uses Swift 5 language mode; bundled Swift packages require a toolchain supporting Swift 6.2. Native code uses C++23. The deployment target is iOS 17.

## Prepare dependencies

```sh
cp .env.example .env
# Enter your own team and bundle identifier in .env for a signed build.
bash Scripts/prepare-macos.sh --dependencies-only
python3 Scripts/rebuild-ffmpeg-ios.py --output ThirdParty/Dependencies/FFmpeg
```

Preparation downloads checksum-pinned sources and headers and builds the iOS dependencies and interpreter-only retro cores. FFmpeg is rebuilt for both device and Apple Silicon simulator. Its source revision and recipe are recorded in each resulting framework. The public tree does not include the old diagnostic FFmpeg binaries.

Boost binary libraries retain their 1.89.0 ABI; the separately pinned, header-only ICL update fixes interval lookup with libc++ 22. Preserve this combination when changing dependency versions.

## Build or archive

Open `Claw.xcodeproj`, select the `Claw` scheme and your device, and choose your signing team. Keep credentials and generated configuration out of Git.

```sh
bash Scripts/archive-app-store.sh --unsigned
# With your signing configuration:
bash Scripts/archive-app-store.sh
```

The archive script exports locally. It does not submit an App Store release. For local configuration options, see `.env.example` and `Scripts/distribution_config.py`.

## Checks

```sh
bash Scripts/check-build.sh --portable
```

Run dependency preparation before checks that require Boost/fmt headers. Full Apple compile, linking, signing, and device playback require the corresponding Apple toolchain or hardware.

Xcode Cloud runs `ci_scripts/ci_post_clone.sh` and `ci_scripts/ci_post_xcodebuild.sh`. Use the `Claw` project and scheme, supply your own signing configuration, and keep `CLAW_FFMPEG_MODE=source`. Cloud generates the archive build number and verifies framework provenance, signatures, runpaths, and bundled legal/privacy resources.

## Source releases

`SOURCE_SNAPSHOT.json` in a public source release identifies the development commit and exported file hashes. A source-materials ZIP also includes checksum-pinned upstream archives and the local build scripts. Third-party source, license texts, and core modifications are retained. Development logs, historical handoff notes, and signing credentials are excluded from public source snapshots.
