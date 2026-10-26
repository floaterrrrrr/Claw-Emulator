#!/usr/bin/env python3
"""Export one audited Git revision without private history or legacy FFmpeg binaries."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import zipfile
from verified_download import fetch_verified
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = ('ThirdParty/Dependencies/FFmpeg/', '.github/workflows/', 'Docs/Archive/', 'Docs/UI_DESIGN_FOLLOWUP.md', 'Docs/UI_REDESIGN.md', 'Validation/', 'Distribution/build-110-launch-investigation.md', 'Distribution/release-handoff.md', 'Distribution/build-102-validation.json', 'Distribution/encryption-assessment.md', 'Distribution/encryption-source-evidence.json')
FORBIDDEN_NAMES = {'.env', '.env.local', '.git', '.build-config', '.secrets', 'output'}
SECRET_PATTERNS = [rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', rb'gh[pousr]_[A-Za-z0-9]{30,}', rb'github_pat_[A-Za-z0-9_]{30,}', rb'AKIA[0-9A-Z]{16}']


def excluded_path(name):
    first = PurePosixPath(name).parts[0]
    return name.startswith(EXCLUDED) or "xcuserdata" in PurePosixPath(name).parts or (first.endswith(".xcodeproj") and first != "Claw.xcodeproj")


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def export(revision, destination, bundle_path=None):
    commit = git('rev-parse', revision+'^{commit}').decode().strip()
    destination = destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise ValueError('Export directory must be empty; no existing checkout will be overwritten')
    destination.mkdir(parents=True,exist_ok=True)
    archive = git('-c','core.autocrlf=false','archive','--format=tar',commit)
    exclusions=[]; files={}; modes={}
    with tarfile.open(fileobj=io.BytesIO(archive),mode='r:') as source:
        for item in source:
            parts=PurePosixPath(item.name).parts
            if item.isdir(): continue
            if not item.isfile() or item.name.startswith('/') or '..' in parts:
                raise ValueError('Unexpected archive entry: '+item.name)
            if excluded_path(item.name):
                exclusions.append(item.name); continue
            if any(p in FORBIDDEN_NAMES for p in parts) or Path(item.name).suffix.lower() in {'.p8','.p12','.pfx','.mobileprovision','.ipa'}:
                raise ValueError('Private artifact in export: '+item.name)
            data=source.extractfile(item).read()
            # Match only real-looking credentials; never print matching contents.
            # The regex source itself is text and does not match these patterns.
            if any(re.search(pattern,data) for pattern in SECRET_PATTERNS):
                raise ValueError('Credential-like content requires review in: '+item.name)
            target=destination/item.name; target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes(data)
            target.chmod(item.mode)
            files[item.name]=hashlib.sha256(data).hexdigest()
            modes[item.name]=format(0o100000 | (item.mode & 0o777), 'o')
    with (destination/'.gitignore').open('a',encoding='utf-8') as output:
        output.write('\n# Recreated from pinned source in this public snapshot\nThirdParty/Dependencies/FFmpeg/\n')
    snapshot={'development_commit':commit,'history_included':False,'export_changes':['Claw branding and public build instructions retained','.gitignore excludes rebuilt FFmpeg outputs','Legacy FFmpeg prebuilts and private-repository CI workflows omitted'], 'excluded_file_count':len(exclusions),'file_modes':modes,'file_sha256':{str(p.relative_to(destination)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(destination.rglob('*')) if p.is_file() and p.name != 'SOURCE_SNAPSHOT.json'}}
    (destination/'SOURCE_SNAPSHOT.json').write_text(json.dumps(snapshot,indent=2)+'\n',encoding='utf-8')
    if bundle_path:
        spec=importlib.util.spec_from_file_location('source_package',ROOT/'Scripts/package-pinned-source.py'); module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        entries=module.pinned_sources(); bundle_path=bundle_path.resolve();bundle_path.parent.mkdir(parents=True,exist_ok=True)
        with zipfile.ZipFile(bundle_path,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as bundle:
            for p in sorted(destination.rglob('*')):
                if p.is_file(): bundle.write(p,'claw/'+p.relative_to(destination).as_posix())
            for name,item in entries:
                cache=ROOT/'.build-dependencies/source-archives'/f"{item['sha256']}.tar.gz"
                fetch_verified(item['url'],cache,item['sha256'],max_bytes=384*1024*1024)
                bundle.write(cache,'upstream/'+name+'.tar.gz')
            manifest={'development_commit':commit,'snapshot_file':'claw/SOURCE_SNAPSHOT.json','pinned_sources':{name:{k:item[k] for k in ('url','revision','sha256')} for name,item in entries},'coverage':'Claw source, vendored modified cores, pinned upstream archives, patches and build scripts. Legacy FFmpeg binaries excluded. MoltenVK/Boost distributed with recorded prebuilt provenance; no upstream binary reproduction claim. See source-readiness.md for release checks.'}
            bundle.writestr('SOURCE_MANIFEST.json',json.dumps(manifest,indent=2)+'\n')
        print(json.dumps({'bundle':str(bundle_path),'sha256':hashlib.sha256(bundle_path.read_bytes()).hexdigest(),'size':bundle_path.stat().st_size}))
    print(json.dumps({'development_commit':commit,'snapshot':str(destination),'files':len(snapshot['file_sha256']),'excluded':len(exclusions)}))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--revision',default='HEAD');p.add_argument('--output',type=Path,required=True);p.add_argument('--bundle',type=Path)
    a=p.parse_args();export(a.revision,a.output,a.bundle)
