#!/usr/bin/env bash
# Read-only validation of an existing archive/IPA. Does not upload or submit.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 4 ]]; then
    echo 'Usage: bash Scripts/validate-release-on-mac.sh /path/Claw.xcarchive /path/Claw.ipa BUILD FULL_SOURCE_COMMIT' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Signature verification requires macOS and Xcode command-line tools.' >&2
    exit 2
fi
task_archive="$1"
task_ipa="$2"
task_build="$3"
task_commit="$4"
if [[ ! "$task_build" =~ ^[1-9][0-9]*$ || ! "$task_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo 'Supply a positive build number and full Git commit.' >&2
    exit 2
fi
task_result=0
task_evidence="$PWD/Validation/AppStore/build-$task_build"
mkdir -p "$task_evidence"
xcodebuild -version > "$task_evidence/xcode.txt"
python3 Tests/test_apple_artifact.py
python3 Scripts/audit-public-tree.py
python3 Scripts/package-pinned-source.py
# Zip without extracting/re-signing the original archive or changing its modes.
ditto -c -k --keepParent "$task_archive" "$task_evidence/candidate.xcarchive.zip"
task_bundle="$(python3 - "$task_archive" <<'PY'
import plistlib, sys
from pathlib import Path
apps = list((Path(sys.argv[1]) / 'Products/Applications').glob('*.app'))
if len(apps) != 1:
    raise SystemExit('Expected one app')
print(plistlib.loads((apps[0] / 'Info.plist').read_bytes())['CFBundleIdentifier'])
PY
)"
python3 Scripts/inspect-apple-artifact.py "$task_evidence/candidate.xcarchive.zip" \
    --expected-build "$task_build" --expected-commit "$task_commit" --expected-bundle "$task_bundle" \
    --output "$task_evidence/archive.json" > "$task_evidence/archive-output.txt" || task_result=1
python3 Scripts/inspect-apple-artifact.py "$task_ipa" \
    --expected-build "$task_build" --expected-commit "$task_commit" --expected-bundle "$task_bundle" \
    --output "$task_evidence/ipa.json" > "$task_evidence/ipa-output.txt" || task_result=1
python3 Scripts/validate-app-store-archive.py "$task_archive" \
    --expected-build "$task_build" --expected-commit "$task_commit" --expected-bundle "$task_bundle" || task_result=1
# Verify the exported distribution app, because Cloud archives may be unsigned.
task_unpacked="$(mktemp -d "$task_evidence/export.XXXXXX")"
ditto -x -k "$task_ipa" "$task_unpacked"
python3 - "$task_unpacked" "$task_evidence" <<'PY'
import plistlib, subprocess, sys
from pathlib import Path
root, evidence = map(Path, sys.argv[1:])
apps = list((root / 'Payload').glob('*.app'))
if len(apps) != 1:
    raise SystemExit('Expected one app in exported IPA')
app = apps[0]
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], check=True)
data = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)])
policy = plistlib.loads(data)
if policy.get('get-task-allow') is not False or any(policy.get(k) for k in
        ['com.apple.security.cs.allow-jit', 'dynamic-codesigning', 'com.apple.private.cs.debugger']):
    raise SystemExit('Unexpected distribution entitlements')
(evidence / 'entitlements.plist').write_bytes(plistlib.dumps(policy))
print('PASS: exported app signatures and distribution entitlement checks')
PY
printf 'Technical evidence: %s\nSource rights, public URLs, questionnaires, device tests and Apple review remain separate gates.\n' "$task_evidence"
exit "$task_result"
