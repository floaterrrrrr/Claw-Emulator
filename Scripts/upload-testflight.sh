#!/usr/bin/env bash
# Uploads an existing archive for TestFlight; does not submit an App Store release.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --help ]]; then
    echo 'Usage: bash Scripts/upload-testflight.sh [archive-path]'
    echo 'Default archive: build/AppStore/Claw.xcarchive'
    echo 'Uploads to Apple for TestFlight processing using the signed-in Xcode account.'
    exit 0
fi
if [[ $# -gt 1 ]]; then
    echo 'Use --help for usage.' >&2
    exit 1
fi
if [[ "${CLAW_ENV_LOADED:-}" != 1 ]]; then
    exec python3 Scripts/distribution_config.py run -- bash "$PWD/Scripts/upload-testflight.sh" "$@"
fi
python3 Scripts/distribution_config.py generate --require-signing
task_archive="${1:-build/AppStore/Claw.xcarchive}"
python3 Scripts/validate-app-store-archive.py "$task_archive"
mkdir -p Validation/AppStore
python3 Scripts/distribution_config.py xcodebuild -- -exportArchive -archivePath "$task_archive" \
    -exportOptionsPlist .build-config/TestFlightUploadOptions.plist \
    -allowProvisioningUpdates 2>&1 | tee Validation/AppStore/testflight-upload.log
echo 'Upload completed. Check TestFlight processing and tester availability in App Store Connect.'
