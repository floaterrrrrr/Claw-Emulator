#!/bin/bash
set -Eeuo pipefail
task_ci_step="Xcode Cloud setup"
trap 'task_ci_result=$?; printf "error: Claw post-clone step failed: %s (exit %s, line %s)\n" "$task_ci_step" "$task_ci_result" "$LINENO" >&2; exit "$task_ci_result"' ERR
run_step() {
    task_ci_step="$1"
    shift
    printf 'Claw CI: %s\n' "$task_ci_step"
    "$@"
}
cd "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud must provide the repository path}"
if [[ "${CI_XCODE_CLOUD:-}" != TRUE ]]; then
    echo 'This hook is intended for Xcode Cloud.' >&2
    exit 1
fi
export HOMEBREW_NO_AUTO_UPDATE=1
# Apple's product association supplies these values; custom workflow settings
# may override them without putting account identifiers in the public project.
export CLAW_APPLE_TEAM_ID="${CLAW_APPLE_TEAM_ID:-${CI_TEAM_ID:-}}"
export CLAW_BUNDLE_ID="${CLAW_BUNDLE_ID:-${CI_BUNDLE_ID:-}}"
if [[ -z "$CLAW_APPLE_TEAM_ID" || -z "$CLAW_BUNDLE_ID" || "$CLAW_BUNDLE_ID" == com.example.claw ]]; then
    echo 'Configure the Claw product/team, or set CLAW_APPLE_TEAM_ID and CLAW_BUNDLE_ID in the workflow.' >&2
    exit 1
fi
run_step "Signing configuration" python3 Scripts/distribution_config.py generate --require-signing
run_step "Xcode project sources" python3 Tests/check_project_sources.py
run_step "Claw release layout" python3 Tests/test_release_layout.py
run_step "Release source audit" python3 Scripts/audit-public-tree.py
run_step "MoltenVK provenance and notices" python3 Scripts/verify-moltenvk-provenance.py
run_step "Apple artifact parser tests" python3 Tests/test_apple_artifact.py
run_step "Boost header overlay tests" python3 Tests/test_boost_headers.py
run_step "FFmpeg source pipeline tests" python3 Tests/test_ffmpeg_cloud.py
run_step "Imported cheat parser tests" bash Scripts/test-cheat-parser.sh
# Keep the checked-in project and lockfile intact: dependency resolution is
# managed by Xcode Cloud after this hook, using the committed Package.resolved.
run_step "Build dependencies" bash Scripts/prepare-macos.sh --dependencies-only
run_step "FFmpeg build selection" python3 -u Scripts/select-ffmpeg-build.py
run_step "FFmpeg Cytrus symbol compatibility" python3 Scripts/check-ffmpeg-api.py
task_ci_step="Find macOS host compiler"
# Xcode Cloud may enter this hook with an iPhoneSimulator SDK selected for the
# later archive. These checks build and run on the Mac host, so give Clang and
# Swift the matching SDK before compiling any host-side C++ test.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
task_ci_clang="$(xcrun --sdk macosx --find clang++)"
printf '#include <array>\nint main() { return std::array<int, 1>{}[0]; }\n' | \
    "$task_ci_clang" -std=c++20 -x c++ -fsyntax-only -
CXX="$task_ci_clang" run_step "Fast-forward core tests" python3 Tests/test_fast_forward_core.py
CXX="$task_ci_clang" run_step "Session save and restore tests" python3 Tests/test_session_controls.py
CXX="$task_ci_clang" run_step "Critical core diagnostic tests" python3 Tests/test_core_failure_diagnostic.py
CXX="$task_ci_clang" run_step "FFmpeg binding and iOS loader tests" python3 Tests/test_ffmpeg_loader.py
CXX="$task_ci_clang" run_step "Runtime framework probe tests" python3 Tests/test_framework_probe.py
CXX="$task_ci_clang" run_step "Rasterizer page cache and libc++ interval regression" python3 Tests/test_rasterizer_page_cache.py
CXX="$task_ci_clang" run_step "Interpreter invalidation tests" bash Scripts/test-fastinterp-invalidation.sh
CXX="$task_ci_clang" run_step "Descriptor binding tests" bash Scripts/test-descriptor-binding-range.sh
CXX="$task_ci_clang" run_step "Vulkan presentation cache tests" bash Scripts/test-vulkan-presentation-cache.sh
run_step "Apple audio tests" bash Scripts/test-apple-audio.sh
run_step "Retro failure handling tests" bash Scripts/test-retro-failures.sh
run_step "Retro presentation tests" bash Scripts/test-retro-presentation.sh
run_step "ROM archive tests" bash Scripts/test-rom-archives.sh
run_step "Library edit tests" bash Scripts/test-library-edits.sh
run_step "Console library tests" bash Scripts/test-console-library.sh
run_step "Game Boy control tests" bash Scripts/test-handheld-controls.sh
run_step "App asset checks" python3 Tests/check_app_assets.py
run_step "Local artwork tests" bash Scripts/test-game-artwork.sh
run_step "Imported skin tests" bash Scripts/test-imported-skins.sh
run_step "Thermal policy tests" bash Scripts/test-thermal-policy.sh
run_step "Device profile tests" bash Scripts/test-mobile-device-profile.sh
run_step "Rasterizer address tests" bash Scripts/test-rasterizer-addresses.sh
CLAW_CPU_PROFILE=app-store run_step "App Store compiler checks" bash Scripts/validate-apple-compiler.sh
run_step "Distribution configuration tests" python3 Tests/test_distribution_config.py
run_step "Archive metadata" python3 - <<'PY'
import os
import plistlib
import subprocess
from pathlib import Path
from Scripts.distribution_config import apply_encryption_declaration
import importlib.util
number = os.environ.get("CI_BUILD_NUMBER", "")
if not number.isdigit() or int(number) < 1:
    raise SystemExit("Xcode Cloud must provide a positive CI_BUILD_NUMBER")
path = Path("App/Info.plist")
info = plistlib.loads(path.read_bytes())
info["CFBundleVersion"] = number
info["ClawSourceCommit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
spec = importlib.util.spec_from_file_location("ffmpeg_selection", "Scripts/select-ffmpeg-build.py")
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)
info["ClawFFmpegMode"] = selection.selected_mode()
declaration = apply_encryption_declaration(info)
if declaration is None:
    print("warning: Encryption declaration is unset. Complete export compliance in App Store Connect before TestFlight distribution.")
else:
    print(f"Configured ITSAppUsesNonExemptEncryption={str(declaration).lower()} from the committed plist or an explicit distribution override.")
path.write_bytes(plistlib.dumps(info))
print("Configured the archive to use the Xcode Cloud build number.")
PY
