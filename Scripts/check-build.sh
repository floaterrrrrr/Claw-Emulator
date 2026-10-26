#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Tests/test_verified_download.py
python3 Tests/test_apple_artifact.py
python3 Tests/test_release_layout.py
python3 Tests/test_boost_headers.py
python3 Tests/test_ffmpeg_cloud.py
python3 Scripts/audit-public-tree.py
bash Scripts/test-cheat-parser.sh
bash Scripts/test-native.sh
bash Scripts/test-bridge-state.sh
bash Scripts/test-mobile-profile.sh
bash Scripts/test-performance.sh
bash Scripts/test-mobile-runtime.sh
bash Scripts/test-apple-audio.sh
bash Scripts/test-audio-session.sh
bash Scripts/test-compiler-profile.sh
bash Scripts/test-metalfx.sh
bash Scripts/test-gameplay-layout.sh
bash Scripts/test-handheld-controls.sh
bash Scripts/test-controller-skin.sh
bash Scripts/test-imported-skins.sh
bash Scripts/test-mobile-presentation.sh
bash Scripts/test-mobile-device-profile.sh
bash Scripts/test-advanced-states.sh
python3 Tests/test_session_controls.py
python3 Tests/test_core_failure_diagnostic.py
python3 Tests/test_ffmpeg_loader.py
python3 Tests/test_framework_probe.py
python3 Tests/test_rasterizer_page_cache.py
bash Scripts/test-game-artwork.sh
bash Scripts/test-six-systems.sh
python3 Tests/test_distribution_config.py
bash Scripts/benchmark.sh
if [[ "${1:-}" == --portable ]]; then exit 0; fi
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
    echo "BLOCKED: full iOS compile/link requires macOS and Xcode; portable checks above passed." >&2
    exit 2
fi
bash Scripts/validate-apple-compiler.sh
bash Scripts/prepare-macos.sh
bash Scripts/test-metalfx-interop.sh
mkdir -p Validation
xcodebuild -project Claw.xcodeproj -scheme Claw -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath .derived \
    CLAW_CPU_TARGET="$(cat Validation/cpu-target.txt)" \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | tee Validation/xcode-build.log
