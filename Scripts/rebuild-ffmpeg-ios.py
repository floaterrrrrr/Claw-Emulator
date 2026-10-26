#!/usr/bin/env python3
"""Stage iOS FFmpeg frameworks from a checksum-pinned upstream source archive.

By default, output is staged separately. --install-for-cloud replaces the
frameworks in the temporary Xcode Cloud checkout so its app uses this build.
Device compatibility and distribution licensing still need separate review.
"""

import argparse
import hashlib
import json
import os
import platform as host_platform
import plistlib
import re
import shlex
import shutil
import subprocess
import tarfile
from pathlib import Path

from verified_download import fetch_verified, sha256_file
from apple_deployment import verify_ios_deployment


ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / "Distribution/binary-source-candidates.json").read_text())["ffmpeg-n8.1.2"]
MINIMUM_IOS = "17.0"
LIBRARIES = ("avcodec", "avdevice", "avfilter", "avformat", "avutil", "swresample", "swscale")
CONFIGURE_FLAGS = (
    "--target-os=darwin", "--arch=aarch64", "--enable-cross-compile",
    "--enable-shared", "--disable-static", "--enable-pic", "--enable-asm",
    "--enable-optimizations", "--enable-small", "--enable-pthreads", "--enable-gpl",
    "--disable-autodetect", "--disable-programs", "--disable-doc", "--disable-debug",
    "--disable-avfoundation", "--disable-videotoolbox",
    "--disable-audiotoolbox", "--disable-coreimage", "--disable-appkit",
    "--disable-openssl", "--disable-zlib", "--disable-bzlib", "--disable-iconv",
    "--install-name-dir=@rpath",
)
PROVENANCE_FILE = "ClawFFmpegProvenance.json"


def run(*args, cwd=None, env=None):
    command = [str(arg) for arg in args]
    print("FFmpeg command: " + shlex.join(command), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def output(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def fetch_source(cache):
    archive = cache / "ffmpeg-n8.1.2.tar.gz"
    fetch_verified(PIN["url"], archive, PIN["sha256"], max_bytes=128 * 1024 * 1024)
    source = cache / "source"
    stamp = source / ".claw-revision"
    if stamp.is_file() and stamp.read_text() == PIN["revision"]:
        return archive, source
    with tarfile.open(archive) as members:
        for member in members.getmembers():
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk():
                raise RuntimeError("Unsafe path or link in FFmpeg source archive")
    if source.exists():
        shutil.rmtree(source)
    source.mkdir(parents=True)
    run("tar", "-xzf", archive, "-C", source, "--strip-components=1")
    if not (source / "configure").is_file() or not (source / "COPYING.GPLv3").is_file():
        raise RuntimeError("Incomplete FFmpeg source archive")
    stamp.write_text(PIN["revision"])
    return archive, source


def make_compiler_wrapper(path, executable, target, sdk):
    command = [executable, "-target", target, "-isysroot", sdk]
    path.write_text("#!/bin/sh\nexec " + " ".join(map(shlex.quote, command)) + ' "$@"\n')
    path.chmod(0o755)


def build_slice(source, cache, platform, jobs):
    target = f"arm64-apple-ios{MINIMUM_IOS}"
    if platform == "iphonesimulator":
        target += "-simulator"
    sdk = output("xcrun", "--sdk", platform, "--show-sdk-path")
    clang = output("xcrun", "--sdk", platform, "--find", "clang")
    clangxx = output("xcrun", "--sdk", platform, "--find", "clang++")
    build = cache / "build" / platform
    prefix = cache / "installed" / platform
    build.mkdir(parents=True, exist_ok=True)
    prefix.mkdir(parents=True, exist_ok=True)
    cc = build / "claw-cc"
    cxx = build / "claw-cxx"
    make_compiler_wrapper(cc, clang, target, sdk)
    make_compiler_wrapper(cxx, clangxx, target, sdk)
    flags = [f"--prefix={prefix}", f"--cc={cc}", f"--cxx={cxx}",
             f"--as={cc}", f"--ld={cc}",
             "--extra-ldflags=-Wl,-headerpad_max_install_names", *CONFIGURE_FLAGS]
    # Cloud can inherit the SDK selected for a different action. The compiler
    # wrappers above explicitly select this slice's target and sysroot.
    build_env = dict(os.environ)
    for key in ("SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET",
                "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"):
        build_env.pop(key, None)
    print(f"FFmpeg slice: {platform}; target={target}; SDK={sdk}", flush=True)
    try:
        run(source / "configure", *flags, cwd=build, env=build_env)
    except subprocess.CalledProcessError:
        for config_log in (build / "ffbuild/config.log", build / "config.log"):
            if config_log.is_file():
                print(f"FFmpeg configure failure: last lines of {config_log}", flush=True)
                print(config_log.read_text(errors="replace")[-16000:], flush=True)
                break
        raise
    run("make", "-j", str(jobs), cwd=build, env=build_env)
    run("make", "install", cwd=build, env=build_env)
    return build, prefix, flags


def dylib_for(prefix, name):
    matches = [path for path in (prefix / "lib").glob(f"lib{name}*.dylib")
               if path.is_file() and not path.is_symlink()
               and re.fullmatch(rf"lib{name}\.\d+(?:\.\d+)*\.dylib", path.name)]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one versioned lib{name} dylib, got: {matches}")
    return matches[0]


def rewrite_framework_links(binary):
    run("install_name_tool", "-id", f"@rpath/{binary.parent.name}/{binary.name}", binary)
    for line in output("otool", "-L", binary).splitlines()[1:]:
        old = line.strip().split(" (", 1)[0]
        match = re.fullmatch(r"lib(avcodec|avdevice|avfilter|avformat|avutil|swresample|swscale)\.\d+(?:\.\d+)*\.dylib",
                             Path(old).name)
        if match:
            name = "lib" + match.group(1)
            run("install_name_tool", "-change", old, f"@rpath/{name}.framework/{name}", binary)
    for line in output("otool", "-L", binary).splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if re.search(r"lib(?:av|sw)[^/]*\.\d+(?:\.\d+)*\.dylib$", dependency):
            raise RuntimeError(f"Unrewritten FFmpeg dependency in {binary}: {dependency}")
        if not dependency.startswith(("/usr/lib/", "/System/Library/", "@rpath/lib")):
            raise RuntimeError(f"Non-distributable FFmpeg dependency in {binary}: {dependency}")


def binary_uuid(binary):
    identifiers = re.findall(r"UUID: ([0-9A-Fa-f-]{36}) \(arm64\)",
                             output("xcrun", "dwarfdump", "--uuid", binary))
    if len(identifiers) != 1:
        raise RuntimeError(f"Expected one arm64 UUID in {binary}")
    return identifiers[0].lower()


def make_framework(prefix, stage, platform, name):
    framework_name = "lib" + name
    framework = stage / platform / f"{framework_name}.framework"
    framework.mkdir(parents=True)
    binary = framework / framework_name
    shutil.copy2(dylib_for(prefix, name), binary)
    shutil.copytree(prefix / "include" / framework_name, framework / "Headers")
    plist = {
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": framework_name,
        "CFBundleIdentifier": f"io.claw.ffmpeg.{framework_name}",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": framework_name,
        "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "8.1.2",
        "CFBundleVersion": "1", "MinimumOSVersion": MINIMUM_IOS,
        "CFBundleSupportedPlatforms": ["iPhoneOS" if platform == "iphoneos" else "iPhoneSimulator"],
    }
    (framework / "Info.plist").write_bytes(plistlib.dumps(plist))
    rewrite_framework_links(binary)
    verify_ios_deployment(binary, MINIMUM_IOS)
    return framework


def validate_cloud_artifacts(destination):
    """Check the entire staged set before touching the checkout's old libraries."""
    manifest = json.loads((destination / "provenance.json").read_text())
    if manifest.get("source_revision") != PIN["revision"] or manifest.get("source_sha256") != PIN["sha256"]:
        raise RuntimeError("FFmpeg build does not match the pinned source")
    if manifest.get("script_sha256") != sha256_file(Path(__file__)):
        raise RuntimeError("FFmpeg build was made by a different rebuild recipe")
    for name in LIBRARIES:
        library = "lib" + name
        artifact = destination / f"{library}.xcframework"
        info = plistlib.loads((artifact / "Info.plist").read_bytes())
        slices = info.get("AvailableLibraries", [])
        if len(slices) != 2:
            raise RuntimeError(f"Expected device and simulator slices for {library}")
        seen = set()
        for entry in slices:
            variant = entry.get("SupportedPlatformVariant")
            if entry.get("SupportedPlatform") != "ios" or entry.get("SupportedArchitectures") != ["arm64"] or variant not in (None, "simulator"):
                raise RuntimeError(f"Unexpected platform/architecture for {library}")
            platform = "iphonesimulator" if variant == "simulator" else "iphoneos"
            identifier = entry["LibraryIdentifier"]
            if platform in seen or identifier not in ("ios-arm64", "ios-arm64-simulator") or entry["LibraryPath"] != f"{library}.framework":
                raise RuntimeError(f"Unexpected XCFramework layout for {library}")
            seen.add(platform)
            framework = artifact / identifier / entry["LibraryPath"]
            record = json.loads((framework / PROVENANCE_FILE).read_text())
            digest = sha256_file(framework / library)
            if (record.get("library") != library or record.get("platform") != platform or
                    record.get("source_revision") != PIN["revision"] or record.get("source_sha256") != PIN["sha256"] or
                    record.get("script_sha256") != manifest["script_sha256"] or
                    record.get("build") != manifest["slices"][platform] or
                    record.get("binary_uuid") != manifest["binary_uuids"][platform][name] or
                    record.get("binary_sha256") != digest or digest != manifest["binaries"][platform][name]):
                raise RuntimeError(f"FFmpeg staged binary/provenance mismatch: {library} {platform}")
    return manifest


def install_for_cloud(destination):
    if os.environ.get("CI_XCODE_CLOUD", "").upper() != "TRUE":
        raise RuntimeError("--install-for-cloud is restricted to the temporary Xcode Cloud checkout")
    manifest = validate_cloud_artifacts(destination)
    target = ROOT / "ThirdParty/Dependencies/FFmpeg"
    if target.is_symlink() or not target.resolve().is_relative_to(ROOT.resolve()):
        raise RuntimeError("Refusing to replace FFmpeg outside the repository checkout")
    target.mkdir(parents=True, exist_ok=True)
    paths = [(destination / f"lib{name}.xcframework", target / f"lib{name}.xcframework")
             for name in LIBRARIES]
    # Verify every resolved removal target before replacing any old framework.
    for source, installed in paths:
        if installed.is_symlink() or installed.resolve().parent != target.resolve() or source.resolve() == installed.resolve():
            raise RuntimeError(f"Unsafe FFmpeg installation target: {installed}")
    for source, installed in paths:
        if installed.exists():
            shutil.rmtree(installed)
        shutil.copytree(source, installed)
    shutil.copy2(destination / "provenance.json", target / "provenance.json")
    print("Installed seven source-built FFmpeg XCFrameworks into the Xcode Cloud checkout", flush=True)
    print("CLAW_FFMPEG_PROVENANCE_BEGIN", flush=True)
    print(json.dumps(manifest, indent=2), flush=True)
    print("CLAW_FFMPEG_PROVENANCE_END", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch-only", action="store_true", help="verify and unpack the pinned source on any host")
    parser.add_argument("--cache", type=Path, default=ROOT / ".build-dependencies/ffmpeg-rebuild")
    parser.add_argument("--output", type=Path, default=ROOT / ".build-dependencies/replacements/FFmpeg")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 4))
    parser.add_argument("--install-for-cloud", action="store_true", help="Use the generated frameworks in this Xcode Cloud checkout")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.install_for_cloud and os.environ.get("CI_XCODE_CLOUD", "").upper() != "TRUE":
        parser.error("--install-for-cloud requires CI_XCODE_CLOUD=TRUE")
    if args.install_for_cloud and args.fetch_only:
        parser.error("--install-for-cloud cannot be used with --fetch-only")
    archive, source = fetch_source(args.cache.resolve())
    print(f"Verified FFmpeg source {PIN['revision']} ({sha256_file(archive)})", flush=True)
    if args.fetch_only:
        return
    if host_platform.system() != "Darwin" or not shutil.which("xcodebuild"):
        raise SystemExit("Building iOS XCFrameworks requires macOS and Xcode")
    toolchain = output("xcodebuild", "-version")
    identity = hashlib.sha256((PIN["sha256"] + sha256_file(Path(__file__)) + toolchain
                               + MINIMUM_IOS).encode()).hexdigest()[:16]
    build_cache = args.cache.resolve() / identity
    stage = build_cache / "framework-stage"
    if stage.exists():
        shutil.rmtree(stage)
    records = {}
    for platform in ("iphoneos", "iphonesimulator"):
        build, prefix, flags = build_slice(source, build_cache, platform, args.jobs)
        records[platform] = {"configure": flags, "config_sha256": sha256_file(build / "config.h"),
                             "make_config_sha256": sha256_file(build / "ffbuild/config.mak"),
                             "compiler_wrapper_sha256": sha256_file(build / "claw-cc"),
                             "sdk": output("xcrun", "--sdk", platform, "--show-sdk-version")}
        for name in LIBRARIES:
            make_framework(prefix, stage, platform, name)
    manifest = {
        "schema_version": 1,
        "source_repository": PIN["repository"], "source_url": PIN["url"], "source_revision": PIN["revision"],
        "source_sha256": PIN["sha256"], "script_sha256": sha256_file(Path(__file__)),
        "xcode": toolchain, "minimum_ios": MINIMUM_IOS, "slices": records,
        "binaries": {platform: {name: sha256_file(stage / platform / f"lib{name}.framework" / f"lib{name}")
                               for name in LIBRARIES} for platform in records},
        "binary_uuids": {platform: {name: binary_uuid(stage / platform / f"lib{name}.framework" / f"lib{name}")
                                   for name in LIBRARIES} for platform in records},
        "device_testing": "pending",
    }
    for platform, settings in records.items():
        for name in LIBRARIES:
            framework = stage / platform / f"lib{name}.framework"
            record = {key: manifest[key] for key in ("schema_version", "source_repository", "source_url",
                      "source_revision", "source_sha256", "script_sha256", "xcode", "minimum_ios", "device_testing")}
            record.update(library="lib" + name, platform=platform, build=settings,
                          binary_sha256=manifest["binaries"][platform][name],
                          binary_uuid=manifest["binary_uuids"][platform][name])
            (framework / PROVENANCE_FILE).write_text(json.dumps(record, indent=2) + "\n")
            for license_name in ("COPYING.GPLv2", "COPYING.GPLv3"):
                shutil.copy2(source / license_name, framework / f"FFmpeg-{license_name}")
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    for name in LIBRARIES:
        framework_name = "lib" + name
        artifact = destination / f"{framework_name}.xcframework"
        if artifact.exists():
            shutil.rmtree(artifact)
        run("xcodebuild", "-create-xcframework",
            "-framework", stage / "iphoneos" / f"{framework_name}.framework",
            "-framework", stage / "iphonesimulator" / f"{framework_name}.framework",
            "-output", artifact)
    (destination / "provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(source / "COPYING.GPLv3", destination / "COPYING.GPLv3")
    print(f"Staged seven source-built FFmpeg XCFrameworks in {destination}")
    if args.install_for_cloud:
        install_for_cloud(destination)
    else:
        print("The app still uses its existing frameworks until a device build is validated and switched over.")


if __name__ == "__main__":
    main()
