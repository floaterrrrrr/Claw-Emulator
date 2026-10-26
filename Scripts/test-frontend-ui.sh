#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Validation/Frontend
if [[ -e Validation/Frontend/UI.xcresult ]]; then
    mv Validation/Frontend/UI.xcresult "Validation/Frontend/UI-$(date -u +%Y%m%dT%H%M%SZ).xcresult"
fi
xcrun simctl list devices available --json > Validation/Frontend/devices.json
python3 - <<'PY'
import json
from pathlib import Path
out = Path('Validation/Frontend')
values = json.loads((out/'devices.json').read_text())['devices']
phones = [(runtime, device) for runtime, devices in values.items() if '.iOS-' in runtime
          for device in devices if device['name'].startswith('iPhone') and device.get('isAvailable')]
if not phones: raise SystemExit('ERROR: macOS runner has no available iOS Simulator runtime')
phones.sort(key=lambda x: (x[1]['name'] == 'iPhone 17', x[0], x[1]['name']), reverse=True)
runtime, device = phones[0]
(out/'destination.txt').write_text(device['udid'])
(out/'selected-device.json').write_text(json.dumps({'runtime':runtime, 'name':device['name'], 'udid':device['udid']}, indent=2))
print('Frontend fixture:', device['name'], runtime)
PY
xcodegen --spec Tests/FrontendHarness/project.yml --project Tests/FrontendHarness
xcodebuild -project Tests/FrontendHarness/ClawFrontend.xcodeproj -scheme ClawFrontend \
    -destination "platform=iOS Simulator,id=$(cat Validation/Frontend/destination.txt)" \
    -derivedDataPath .derived-frontend -resultBundlePath Validation/Frontend/UI.xcresult \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test 2>&1 | tee Validation/Frontend/ui-test.log
# Xcode shuts the test Simulator down after the suite and may use a clone.
# Read only our fixture's diagnostic file from this ephemeral runner's devices;
# querying a shutdown Simulator with simctl get_app_container is invalid.
python3 - <<'PY'
import json
from pathlib import Path
root = Path.home()/'Library/Developer/CoreSimulator/Devices'
logs = list(root.glob('*/data/Containers/Data/Application/*/Documents/frontend-events.jsonl'))
if not logs: raise SystemExit('ERROR: no frontend fixture native-event log was produced')
events = [json.loads(line) for p in logs for line in p.read_text().splitlines()]
out = Path('Validation/Frontend/frontend-events.jsonl')
out.write_text(''.join(json.dumps(e) + '\n' for e in events))
assert any(e['event'] == 'volume' and abs(e['volume'] - 0.25) <= 0.03 for e in events)
assert all(e['mix'] == 1 for e in events if e['event'] == 'load')
assert all(e['paused'] == 1 for e in events if e['event'] in ('save', 'restore'))
assert any(e['event'] == 'joined_stop' for e in events)
assert any(e['event'] == 'autosave' for e in events)
print('PASS: native frontend event audit: mixed audio, game volume, paused manual states, background autosaves, joined teardown')
PY
