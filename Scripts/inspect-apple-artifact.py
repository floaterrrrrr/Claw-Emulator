#!/usr/bin/env python3
"""Inspect an IPA or zipped xcarchive on any host. This is not codesign validation.

JSON output deliberately separates structural evidence from signing, source-rights,
Apple review, and device tests. Never use a successful inspection as release approval.
"""
import argparse
import hashlib
import json
import plistlib
import re
import struct
import uuid
import zipfile
from pathlib import Path, PurePosixPath


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def version(value):
    return [value >> 16, (value >> 8) & 255, value & 255]


def privacy_errors(manifest):
    declared = {item.get('NSPrivacyAccessedAPIType'): set(item.get('NSPrivacyAccessedAPITypeReasons', []))
                for item in manifest.get('NSPrivacyAccessedAPITypes', [])}
    required = {'UserDefaults': {'CA92.1'}, 'FileTimestamp': {'C617.1', '3B52.1'},
                'SystemBootTime': {'35F9.1'}, 'DiskSpace': {'E174.1'}}
    return [f'Missing required-reason declaration: {category} {sorted(reasons)}'
            for category, reasons in required.items()
            if not reasons.issubset(declared.get('NSPrivacyAccessedAPICategory' + category, set()))]


def macho(data):
    if data[:4] == b'\xca\xfe\xba\xbe':
        if len(data) < 28 or struct.unpack_from('>I', data, 4)[0] != 1:
            raise ValueError('Expected exactly one arm64 device slice in universal binary')
        cpu, subtype, offset, extent, align = struct.unpack_from('>5I', data, 8)
        if cpu != 0x100000C or subtype not in (0, 1) or offset < 28 or extent < 32 or offset + extent > len(data):
            raise ValueError('Invalid universal arm64 slice extent')
        if align > 31 or offset % (1 << align):
            raise ValueError('Invalid universal slice alignment')
        return thin_macho(data[offset:offset + extent])
    return thin_macho(data)


def thin_macho(data):
    """Read bounded, little-endian arm64 Mach-O load commands without executing it."""
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin 64-bit little-endian Mach-O')
    _, cpu, subtype, filetype, count, size, _, _ = struct.unpack_from('<8I', data)
    if cpu != 0x100000C or subtype not in (0, 1):
        raise ValueError('Expected generic arm64, not arm64e or another architecture')
    end = 32 + size
    if end > len(data) or count > size // 8:
        raise ValueError('Invalid Mach-O load-command extent')
    result = {'architecture': 'arm64', 'filetype': filetype, 'dependencies': [],
              'rpaths': [], 'uuid': None, 'platform': None, 'minimum_os': None,
              'sdk': None, 'code_signature_present': False}
    pos = 32
    for _ in range(count):
        if pos + 8 > end:
            raise ValueError('Truncated Mach-O load command')
        cmd, length = struct.unpack_from('<II', data, pos)
        if length < 8 or length % 4 or pos + length > end:
            raise ValueError('Invalid Mach-O load-command size')
        def string(offset, minimum):
            if offset < minimum or offset >= length:
                raise ValueError('Invalid Mach-O string offset')
            raw = data[pos + offset:pos + length]
            if b'\0' not in raw:
                raise ValueError('Unterminated Mach-O string')
            return raw.split(b'\0', 1)[0].decode('utf-8', errors='strict')
        if cmd == 0x1B:
            if length < 24:
                raise ValueError('Truncated UUID command')
            result['uuid'] = str(uuid.UUID(bytes=data[pos + 8:pos + 24]))
        elif cmd == 0x32:
            if length < 24:
                raise ValueError('Truncated build-version command')
            platform, minimum, sdk, tools = struct.unpack_from('<4I', data, pos + 8)
            if 24 + tools * 8 > length:
                raise ValueError('Truncated build-version tools')
            result.update(platform=platform, minimum_os=version(minimum), sdk=version(sdk))
        elif cmd == 0x25:
            if length < 16:
                raise ValueError('Truncated deployment-version command')
            minimum, sdk = struct.unpack_from('<II', data, pos + 8)
            result.update(platform=2, minimum_os=version(minimum), sdk=version(sdk))
        elif cmd in (0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023):
            if length < 24:
                raise ValueError('Truncated dylib command')
            result['dependencies'].append(string(struct.unpack_from('<I', data, pos + 8)[0], 24))
        elif cmd == 0x8000001C:
            if length < 12:
                raise ValueError('Truncated rpath command')
            result['rpaths'].append(string(struct.unpack_from('<I', data, pos + 8)[0], 12))
        elif cmd == 0x1D:
            if length < 16:
                raise ValueError('Truncated signature command')
            offset, extent = struct.unpack_from('<II', data, pos + 8)
            if extent and offset >= end and offset + extent <= len(data):
                result['code_signature_present'] = True
        pos += length
    if pos != end:
        raise ValueError('Unconsumed Mach-O load commands')
    return result


def inspect(path, expected_build, expected_commit, expected_bundle):
    report = {'artifact_sha256': sha256(path.read_bytes()), 'build': None,
              'source_commit': None, 'bundle_id': None, 'binaries': {}, 'errors': [],
              'not_validated': ['Cryptographic code signatures and provisioning eligibility',
                                'Complete corresponding source and distribution license compatibility',
                                'Device gameplay, performance, stability and accessibility',
                                'Public listing, rights, privacy/export answers and Apple approval'],
              'app_store_ready': False}
    errors = report['errors']
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or any('..' in PurePosixPath(n).parts or
                                               n.startswith('/') or '\\' in n for n in names):
            raise ValueError('Duplicate or unsafe ZIP entry')
        infos = [n for n in names if re.fullmatch(r'(?:Payload|[^/]+\.xcarchive/Products/Applications)/[^/]+\.app/Info.plist', n)]
        if len(infos) != 1:
            raise ValueError('Expected one app in an IPA or xcarchive ZIP')
        app = infos[0].removesuffix('Info.plist')
        info = plistlib.loads(archive.read(infos[0]))
        report.update(build=info.get('CFBundleVersion'), source_commit=info.get('ClawSourceCommit'),
                      bundle_id=info.get('CFBundleIdentifier'), version=info.get('CFBundleShortVersionString'),
                      sdk=info.get('DTSDKName'), xcode=info.get('DTXcode'))
        for key, expected in [('CFBundleVersion', expected_build), ('ClawSourceCommit', expected_commit),
                              ('CFBundleIdentifier', expected_bundle), ('UIDeviceFamily', [1]),
                              ('CFBundleSupportedPlatforms', ['iPhoneOS']), ('MinimumOSVersion', '17.0')]:
            if info.get(key) != expected:
                errors.append(f'{key} does not match the expected candidate')
        try:
            sdk = re.fullmatch(r'iphoneos(\d+)\.\d+(?:\.\d+)?', info.get('DTSDKName', ''))
            if not sdk or int(sdk[1]) < 26:
                errors.append('App must use the current minimum iOS 26 SDK or later')
            if int(info.get('DTXcode', '0')) < 2600:
                errors.append('App must use Xcode 26 or later')
        except (TypeError, ValueError):
            errors.append('Invalid SDK/Xcode identity')
        for key in ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription']:
            if not isinstance(info.get(key), str) or not info[key].strip():
                errors.append(f'Missing purpose string: {key}')
        if any(n.startswith(app + 'CommunityCheats/') for n in names):
            errors.append('Archive still includes the removed game-specific cheat sheet')
        for resource in ['GPL-3.0.txt', 'DependencyLicenses.txt', 'RetroCoreLicenses.txt',
                         'ThirdPartyNotices.txt', 'PrivacyPolicy.txt', 'PrivacyInfo.xcprivacy']:
            if app + resource not in names:
                errors.append(f'Missing bundled resource: {resource}')
        if app + 'PrivacyInfo.xcprivacy' in names:
            report['privacy_manifest'] = plistlib.loads(archive.read(app + 'PrivacyInfo.xcprivacy'))
            errors.extend(privacy_errors(report['privacy_manifest']))
        framework_infos = [n for n in names if n.startswith(app + 'Frameworks/') and
                           n.endswith('.framework/Info.plist')]
        binaries = [(app, info)] + [(n.removesuffix('Info.plist'), plistlib.loads(archive.read(n)))
                                    for n in framework_infos]
        framework_names = {PurePosixPath(n).parent.name for n in framework_infos}
        for core in ['ClawDS', 'ClawNES', 'ClawmGBA']:
            if core + '.framework' not in framework_names:
                errors.append(f'Missing core: {core}')
            else:
                base = app + f'Frameworks/{core}.framework/'
                try:
                    source_id = archive.read(base + 'SourceRevision.txt').decode().strip()
                    policy = json.loads(archive.read(base + 'CorePolicy.json'))
                    if not re.fullmatch(r'[0-9a-f]{64}', source_id):
                        errors.append(f'Invalid source identity for {core}')
                    if policy.get('jit') is not False or policy.get('runtime_core_download') is not False:
                        errors.append(f'Invalid interpreter-only policy for {core}')
                except (KeyError, ValueError):
                    errors.append(f'Missing/invalid core provenance for {core}')
        for base, binary_info in binaries:
            executable = binary_info.get('CFBundleExecutable', '')
            if not executable or '/' in executable or '\\' in executable:
                errors.append(f'Invalid executable name in {base}')
                continue
            try:
                raw = archive.read(base + executable)
                record = macho(raw)
                record['sha256'] = sha256(raw)
                report['binaries'][executable] = record
                if record['uuid'] is None:
                    errors.append(f'{executable}: missing binary UUID')
                if record['filetype'] != (2 if base == app else 6):
                    errors.append(f'{executable}: unexpected Mach-O file type')
                if record['platform'] != 2:
                    errors.append(f'{executable}: not an iOS device binary')
                if record['minimum_os'] is None or record['minimum_os'] > [17, 0, 0]:
                    errors.append(f'{executable}: deployment target exceeds iOS 17.0 or is missing')
                for dependency in record['dependencies']:
                    if not dependency.startswith(('/System/Library/', '/usr/lib/', '@rpath/')):
                        errors.append(f'{executable}: non-distributable dylib path {dependency}')
                    elif dependency.startswith('@rpath/') and app + 'Frameworks/' + dependency[7:] not in names:
                        errors.append(f'{executable}: missing embedded dependency {dependency}')
                for rpath in record['rpaths']:
                    if not rpath.startswith(('@executable_path/', '@loader_path/', '/usr/lib/')):
                        errors.append(f'{executable}: non-distributable rpath {rpath}')
                if '.xcarchive/' in app:
                    archive_root = app.split('/Products/Applications/')[0]
                    dsym = f'{archive_root}/dSYMs/{PurePosixPath(base).name}.dSYM/Contents/Resources/DWARF/{executable}'
                    if dsym in names:
                        record['dsym_uuid_matches'] = macho(archive.read(dsym))['uuid'] == record['uuid'] and record['uuid'] is not None
                        if not record['dsym_uuid_matches']:
                            errors.append(f'{executable}: dSYM UUID mismatch')
                    else:
                        record['dsym_uuid_matches'] = None
                        if executable == info['CFBundleExecutable'] or executable in ['ClawDS', 'ClawNES', 'ClawmGBA']:
                            errors.append(f'{executable}: required dSYM missing')
            except (KeyError, ValueError, struct.error) as error:
                errors.append(f'{executable}: {error}')
    report['structural_checks_passed'] = not errors
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path, help='IPA or zipped xcarchive (not an export wrapper ZIP)')
    parser.add_argument('--expected-build', required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--expected-bundle', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.expected_commit):
        parser.error('--expected-commit must be a full Git commit')
    report = inspect(args.artifact, args.expected_build, args.expected_commit, args.expected_bundle)
    content = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(content, encoding='utf-8')
    print(content)
    raise SystemExit(0 if report['structural_checks_passed'] else 1)


if __name__ == '__main__':
    main()
