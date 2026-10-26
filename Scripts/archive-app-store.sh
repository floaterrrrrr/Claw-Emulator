#!/usr/bin/env bash
# Builds and exports locally. Upload is a separate action in Xcode/Transporter.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --help ]]; then
    cat <<'HELP'
Usage: bash Scripts/archive-app-store.sh [--unsigned]

Default: create a signed Claw archive and export an App Store Connect IPA.
--unsigned: compile a complete archive without certificates (cannot upload it).
Requires macOS, a release version of Xcode, and the project build dependencies.
Sign in to Xcode > Settings > Accounts with the existing Salam Labs team first.
The archive uses generic ARM64 instructions for all supported iOS 17 iPhones.
Version and build number are set in App/Info.plist. Increment before reuploading.
HELP
    exit 0
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --unsigned ) ]]; then
    echo 'Unknown argument. Use --help.' >&2
    exit 1
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'App Store archives require macOS with Xcode.' >&2
    exit 2
fi
if [[ "${CLAW_ENV_LOADED:-}" != 1 ]]; then
    exec python3 Scripts/distribution_config.py run -- bash "$PWD/Scripts/archive-app-store.sh" "$@"
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo 'Commit the release source before archiving so the binary has an exact source identity.' >&2
    exit 2
fi
if [[ "${1:-}" != --unsigned ]]; then
    python3 Scripts/distribution_config.py generate --require-signing
fi

bash Scripts/prepare-macos.sh
CLAW_CPU_PROFILE=app-store bash Scripts/validate-apple-compiler.sh
mkdir -p build/AppStore Validation/AppStore
python3 - <<'PY'
import plistlib
import subprocess
from pathlib import Path
from Scripts.distribution_config import apply_encryption_declaration
info = plistlib.loads(Path('App/Info.plist').read_bytes())
info['ClawSourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
apply_encryption_declaration(info)
Path('.build-config/ArchiveInfo.plist').write_bytes(plistlib.dumps(info))
PY
task_signing=(-allowProvisioningUpdates)
if [[ "${1:-}" == --unsigned ]]; then
    task_signing=(CODE_SIGNING_ALLOWED=NO)
fi
python3 Scripts/distribution_config.py xcodebuild -- -project Claw.xcodeproj -scheme Claw -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath .derived \
    -archivePath build/AppStore/Claw.xcarchive \
    CLAW_CPU_TARGET=generic INFOPLIST_FILE=.build-config/ArchiveInfo.plist "${task_signing[@]}" archive \
    2>&1 | tee Validation/AppStore/archive.log
python3 Scripts/validate-app-store-archive.py build/AppStore/Claw.xcarchive

if [[ "${1:-}" == --unsigned ]]; then
    echo 'Unsigned archive built. Signing and App Store validation are still required.'
    exit 0
fi
python3 Scripts/distribution_config.py xcodebuild -- -exportArchive -archivePath build/AppStore/Claw.xcarchive \
    -exportPath build/AppStore/Export -exportOptionsPlist .build-config/ExportOptions.plist \
    -allowProvisioningUpdates 2>&1 | tee Validation/AppStore/export.log
echo 'Exported IPA: build/AppStore/Export. Validate and upload using Xcode or Transporter.'
