#!/usr/bin/env bash
# Xcode collects archive dSYMs from this build-products directory.
set -euo pipefail
if [[ "${PLATFORM_NAME:-}" != iphoneos && "${PLATFORM_NAME:-}" != iphonesimulator ]]; then exit 0; fi
task_symbol_source="${SRCROOT:?}/.build-retro/Frameworks/$PLATFORM_NAME"
task_symbol_destination="${DWARF_DSYM_FOLDER_PATH:?}"
mkdir -p "$task_symbol_destination"
for task_core in ClawmGBA ClawNES ClawDS; do
    task_bundle="$task_symbol_source/$task_core.framework.dSYM"
    if [[ ! -d "$task_bundle" ]]; then
        echo "Missing $task_core debug symbols. Run Scripts/prepare-macos.sh." >&2
        exit 1
    fi
    /usr/bin/ditto "$task_bundle" "$task_symbol_destination/$task_core.framework.dSYM"
done
