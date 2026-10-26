#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build bundled cores from checksum-pinned source; never runs inside the app."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import shlex
import subprocess
import tarfile
from verified_download import fetch_verified

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.build-retro'
LOCK = ROOT / 'ThirdParty/RetroCores/sources.lock.json'
CORE_NAMES = {'mgba': 'ClawmGBA', 'nes': 'ClawNES', 'ds': 'ClawDS'}
PATCHES = {'mgba': ROOT / 'ThirdParty/RetroCores/mgba-ios-deployment.patch',
           'melondsds': ROOT / 'ThirdParty/RetroCores/melondsds-no-pcap.patch'}


def run(args, **kwargs):
    # Archive sources have no .git directory. Do not let upstream's version
    # probes accidentally report the containing Claw repository's revision.
    env = dict(kwargs.pop('env', os.environ))
    env['GIT_CEILING_DIRECTORIES'] = str(CACHE)
    kwargs['env'] = env
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''): value.update(chunk)
    return value.hexdigest()


def source(entry):
    name = entry['name']
    archive = CACHE / 'archives' / (name + '-' + entry['revision'] + '.tar.gz')
    fetch_verified(entry['url'], archive, entry['sha256'])
    destination = CACHE / 'sources' / (name + '-' + entry['revision'])
    stamp = destination / '.claw-source-sha256'
    patch = PATCHES.get(name)
    source_id = entry['sha256'] + (digest(patch) if patch else '')
    if not stamp.exists() or stamp.read_text() != source_id:
        temporary = destination.with_name(destination.name + '.extracting')
        if temporary.exists(): shutil.rmtree(temporary)
        temporary.mkdir(parents=True)
        links = []
        with tarfile.open(archive) as bundle:
            for member in bundle:
                parts = PurePosixPath(member.name).parts[1:]
                if not parts: continue
                if '..' in parts or member.name.startswith('/'): raise ValueError('Unsafe archive path')
                target = temporary.joinpath(*parts)
                if member.isdir(): target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.extractfile(member) as src, target.open('wb') as dst: shutil.copyfileobj(src, dst)
                    target.chmod(0o755 if member.mode & 0o111 else 0o644)
                elif member.issym():
                    resolved = (target.parent / member.linkname).resolve()
                    if not resolved.is_relative_to(temporary.resolve()): raise ValueError('Unsafe source symlink')
                    links.append((target, member.linkname))
                else: raise ValueError('Unsupported source archive member')
        for target, link in links:
            target.parent.mkdir(parents=True, exist_ok=True); target.symlink_to(link)
        if destination.exists(): shutil.rmtree(destination)
        temporary.rename(destination)
        if patch: run(['patch', '-p1', '-i', patch], cwd=destination)
        stamp.write_text(source_id)
    return name, destination


def cmake_build(cmake, src, build, target, options, jobs):
    # CheckFunctionExists must link its probes. Static-library probes accept
    # unresolved functions and incorrectly hide mGBA's portable fallbacks.
    # Drop previous HAVE_* results before configuring an existing Cloud cache.
    # These executables are linked for the selected SDK, never run on the host.
    run([cmake, '-U', 'HAVE_*', '-S', src, '-B', build, '-G', 'Unix Makefiles', '-DCMAKE_BUILD_TYPE=RelWithDebInfo',
         '-DCMAKE_C_FLAGS_RELWITHDEBINFO=-O3 -g -DNDEBUG', '-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O3 -g -DNDEBUG',
         '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', *options,
         '-DCMAKE_TRY_COMPILE_TARGET_TYPE=EXECUTABLE'])
    run([cmake, '--build', build, '--target', target, '-j', jobs])


def verify_interpreter(core, build):
    if core == 'nes': return  # FCEUmm's 6502 engine is an interpreter.
    entries = json.loads((build / 'compile_commands.json').read_text())
    if any(re.search(r'(ARMJIT|dynarmic|luajit)', entry['file'], re.I) for entry in entries):
        raise ValueError('A JIT source entered the interpreter-only core build: ' + core)
    if core == 'ds':
        cache = (build / 'CMakeCache.txt').read_text()
        if 'ENABLE_JIT:BOOL=OFF' not in cache:
            raise ValueError('DS must be built with ENABLE_JIT=OFF')
        if any(re.search(r'-D(?:JIT_ENABLED|ENABLE_JIT)(?:[ =]|$)', entry['command']) for entry in entries):
            raise ValueError('DS compiler definitions unexpectedly enable JIT')


def build_cores(which, sources, cmake, jobs, core_filter):
    apple = which != 'host'
    darwin = platform.system() == 'Darwin'
    if apple and platform.system() != 'Darwin': raise ValueError('iOS builds require macOS with Xcode')
    output = CACHE / 'Frameworks' / which
    output.mkdir(parents=True, exist_ok=True)
    common = ['-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DBUILD_SHARED_LIBS=OFF']
    compiler = None
    if apple:
        sdk = subprocess.check_output(['xcrun', '--sdk', which, '--show-sdk-path'], text=True).strip()
        compiler = subprocess.check_output(['xcrun', '--sdk', which, '--find', 'clang'], text=True).strip()
        triple = 'arm64-apple-ios17.0' + ('-simulator' if which == 'iphonesimulator' else '')
        common += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0',
                   '-DCMAKE_OSX_SYSROOT=' + sdk,
                   '-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO']
    else:
        sdk = triple = ''
    patch_texts = {key: path.read_text() for key, path in PATCHES.items()}
    flags = hashlib.sha256((LOCK.read_text() + json.dumps(patch_texts, sort_keys=True) + which + Path(__file__).read_text()).encode()).hexdigest()
    for core, name in CORE_NAMES.items():
        if core_filter and core not in core_filter: continue
        build = CACHE / 'build' / which / core
        framework = output / (name + '.framework')
        stamp = framework / 'BuildStamp.txt'
        if stamp.exists() and stamp.read_text() == flags and (framework / name).is_file():
            verify_interpreter(core, build)
            print('Cached:', which, name, flush=True); continue
        build.mkdir(parents=True, exist_ok=True)
        print('Building:', which, name, flush=True)
        if core == 'mgba':
            disabled = ['BUILD_QT', 'BUILD_SDL', 'BUILD_SHARED', 'BUILD_STATIC', 'BUILD_TEST', 'BUILD_SUITE',
                        'BUILD_PERF', 'BUILD_GL', 'BUILD_GLES2', 'USE_FFMPEG', 'USE_LZMA', 'USE_SQLITE3',
                        'USE_LIBZIP', 'USE_MINIZIP', 'USE_ELF', 'USE_LUA', 'USE_PNG', 'USE_ZLIB',
                        'USE_DISCORD_RPC', 'USE_JSON_C', 'USE_EDITLINE', 'USE_FREETYPE']
            cmake_build(cmake, sources['mgba'], build, 'mgba_libretro',
                        common + ['-DBUILD_LIBRETRO=ON'] + ['-D' + v + '=OFF' for v in disabled], jobs)
            binary = build / ('mgba_libretro.dylib' if darwin else 'mgba_libretro.so')
        elif core == 'nes':
            copied = build / 'source'
            if copied.exists(): shutil.rmtree(copied)
            shutil.copytree(sources['fceumm'], copied)
            env = os.environ.copy()
            cc = compiler or env.get('CC', 'cc')
            shared = '-dynamiclib' if darwin else '-shared -Wl,--no-undefined'
            env['CFLAGS'] = '-O3 -g -DNDEBUG' + (' -DIOS' if apple else '')
            if apple: cc = shlex.join([compiler, '-target', triple, '-isysroot', sdk])
            revision = next(e['revision'] for e in json.loads(LOCK.read_text())['sources'] if e['name'] == 'fceumm')
            run(['make', '-f', 'Makefile.libretro', '-j' + str(jobs), 'platform=unix', 'HAVE_NTSC=0',
                 'HAVE_HDPACK=0', 'CC=' + cc, 'SHARED=' + shared, 'GIT_VERSION=' + revision[:12]], cwd=copied, env=env)
            binary = copied / 'fceumm_libretro.so'
        else:
            dependencies = []
            for key, path in sources.items():
                if key in ['mgba', 'fceumm', 'melondsds']: continue
                for variable in sorted({key.upper(), key.upper().replace('-', '_')}):
                    dependencies.append('-DFETCHCONTENT_SOURCE_DIR_' + variable + '=' + str(path))
            # Keep upstream's packet-dispatch types, but compile out host dynamic
            # library loading/PCap. The small bundled patch guards its declarations.
            # Every guest networking mode is forced off in RetroRuntime.
            # This core has large C++ translation units. On Xcode Cloud, four
            # concurrent compiles can exhaust the archive worker, and make
            # the first compiler error hard to find among later job output.
            ds_jobs = 1 if apple else jobs
            cmake_build(cmake, sources['melondsds'], build, 'melondsds_libretro', common + dependencies + [
                '-DENABLE_JIT=OFF', '-DENABLE_OPENGL=OFF', '-DENABLE_COMPUTE_RENDERER=OFF',
                '-DENABLE_NETWORKING=ON', '-DENABLE_DYNAMIC=OFF', '-DENABLE_LTO_RELEASE=OFF',
                '-DENABLE_LTO=OFF', '-DENABLE_THREADED_RENDERER=ON', '-DBUILD_TESTING=OFF',
                '-DBUILD_AS_SHARED_LIBRARY=ON', '-DCMAKE_CXX_FLAGS=-I' + str(sources['melonds'] / 'src/net'),
                '-DMELONDS_REPOSITORY_TAG=' + next(e['revision'] for e in json.loads(LOCK.read_text())['sources'] if e['name'] == 'melonds'),
                '-DCMAKE_MODULE_PATH=' + str(sources['melonds'] / 'cmake') + ';' + str(sources['embed-binaries'] / 'cmake')], ds_jobs)
            binary = build / 'src/libretro' / ('melondsds_libretro.dylib' if darwin else 'melondsds_libretro.so')
        verify_interpreter(core, build)
        framework.mkdir(parents=True, exist_ok=True)
        executable = framework / name; shutil.copy2(binary, executable)
        if apple:
            run(['xcrun', 'install_name_tool', '-id', '@rpath/' + name + '.framework/' + name, executable])
            links = subprocess.check_output(['xcrun', 'otool', '-L', str(executable)], text=True).splitlines()[2:]
            for link in links:
                dependency = link.strip().split(' (', 1)[0]
                if not dependency.startswith(('/usr/lib/', '/System/Library/')):
                    raise ValueError('Unbundled core dependency: ' + dependency)
            run(['xcrun', 'dsymutil', executable, '-o', str(framework) + '.dSYM'])
        info = {'CFBundleExecutable': name, 'CFBundleIdentifier': 'io.claw.cores.' + core,
                'CFBundleName': name, 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1',
                'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '17.0',
                'CFBundleSupportedPlatforms': ['iPhoneSimulator' if which == 'iphonesimulator' else 'iPhoneOS']}
        (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
        # Snapshot compatibility follows this core's sources and ABI, not edits
        # to another core or to this script's formatting/cache diagnostics.
        entries = json.loads(LOCK.read_text())['sources']
        selected = [e for e in entries if e['name'] == ('mgba' if core == 'mgba' else 'fceumm')]
        if core == 'ds': selected = [e for e in entries if e['name'] not in ['mgba', 'fceumm']]
        identity = {'sources': selected, 'patch': patch_texts.get('melondsds' if core == 'ds' else core, ''), 'platform': which,
                    'architecture': 'arm64' if apple else platform.machine(), 'abi': 1,
                    'jit': False, 'opengl': False, 'dynamic': False, 'software': True}
        revision = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        (framework / 'SourceRevision.txt').write_text(revision)
        (framework / 'CorePolicy.json').write_text(json.dumps({
            'core': core, 'jit': False, 'runtime_core_download': False,
            'source_revision': revision, 'platform': which}, indent=2) + '\n')
        stamp.write_text(flags)
        print('Built:', which, name, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['host', 'iphoneos', 'iphonesimulator', 'all'],
                        default='all' if platform.system() == 'Darwin' else 'host')
    parser.add_argument('--sources-only', action='store_true')
    parser.add_argument('--core', action='append', choices=list(CORE_NAMES))
    parser.add_argument('--jobs', type=int, default=min(4, os.cpu_count() or 2))
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    if lock['format'] != 1: raise ValueError('Unsupported source lock format')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
        sources = dict(workers.map(source, lock['sources']))
    print('Verified', len(sources), 'pinned source archives.', flush=True)
    if args.sources_only: return
    cmake = os.environ.get('CLAW_CMAKE') or shutil.which('cmake')
    if not cmake: raise ValueError('Install CMake before building emulator cores.')
    for name in (['iphoneos', 'iphonesimulator'] if args.platform == 'all' else [args.platform]):
        build_cores(name, sources, cmake, max(1, args.jobs), args.core)


if __name__ == '__main__': main()
