#!/usr/bin/env python3
"""Choose source FFmpeg or the explicitly pinned, testing-only Build 102 baseline."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / 'Distribution/ffmpeg-build-policy.json'

def selected_mode():
    mode=os.environ.get('CLAW_FFMPEG_MODE') or json.loads(POLICY.read_text())['mode']
    if mode not in ('source','legacy-diagnostic'):
        raise RuntimeError('CLAW_FFMPEG_MODE must be source or legacy-diagnostic')
    return mode

def prepare_legacy():
    if os.environ.get('CI_XCODE_CLOUD','').upper() != 'TRUE':
        raise RuntimeError('Legacy preparation only writes to the temporary Xcode Cloud checkout')
    manifest=json.loads((ROOT/'Distribution/ffmpeg-legacy-baseline.json').read_text())
    # Validate the whole set before adding any diagnostic record. Never mix builds.
    for entry in manifest['artifacts']:
        binary=ROOT/entry['path']
        if hashlib.sha256(binary.read_bytes()).hexdigest()!=entry['sha256']:
            raise RuntimeError('Build 102 baseline mismatch: '+entry['path'])
    for entry in manifest['artifacts']:
        record=dict(entry,mode='legacy-diagnostic',baseline_commit=manifest['baseline_commit'],release_candidate=False)
        (ROOT/entry['path']).with_name('ClawFFmpegDiagnostic.json').write_text(json.dumps(record,indent=2)+'\n')
    print('warning: TESTING ONLY: using the exact checked-in Build 102 FFmpeg artifacts; source provenance is not claimed.',flush=True)
    print('CLAW_FFMPEG_LEGACY_BASELINE_BEGIN',flush=True)
    print(json.dumps(manifest,indent=2),flush=True)
    print('CLAW_FFMPEG_LEGACY_BASELINE_END',flush=True)

def main():
    if len(sys.argv)==2 and sys.argv[1]=='--print-mode':
        print(selected_mode());return
    mode=selected_mode()
    print('Selected FFmpeg mode: '+mode,flush=True)
    if mode=='legacy-diagnostic': prepare_legacy()
    else:
        subprocess.run([sys.executable,'-u',str(ROOT/'Scripts/rebuild-ffmpeg-ios.py'),
                        '--jobs',os.environ.get('CLAW_FFMPEG_BUILD_JOBS','6'),'--install-for-cloud'],check=True)

if __name__=='__main__': main()
