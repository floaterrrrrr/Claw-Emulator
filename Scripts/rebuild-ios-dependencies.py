#!/usr/bin/env python3
"""Build pinned libraries for iOS 17 instead of using newer-OS release binaries."""
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
from pathlib import Path
from apple_deployment import verify_ios_deployment
from verified_download import fetch_verified

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build-dependencies"
ARTIFACTS = ROOT / "ThirdParty/SharedDependencies/Artifacts"
MANIFEST = ROOT / "Distribution/dependency-sources.json"
MINIMUM = "17.0"
SOURCES = CACHE / "sources"
JOBS = os.environ.get("CLAW_BUILD_JOBS", "6")
PROJECTS = {
    "enet": (["enet"], []),
    "faad2": (["faad"], ["-DFAAD_BUNDLED_MODE=ON"]),
    "fmt": (["fmt"], ["-DFMT_TEST=OFF", "-DFMT_DOC=OFF", "-DFMT_INSTALL=OFF"]),
    "glslang": (["glslang", "MachineIndependent", "SPIRV"], [
        "-DENABLE_OPT=OFF", "-DENABLE_GLSLANG_BINARIES=OFF", "-DGLSLANG_TESTS=OFF",
        "-DBUILD_EXTERNAL=OFF", "-DENABLE_HLSL=OFF", "-DENABLE_PCH=OFF"]),
    "sirit": (["sirit"], ["-DSIRIT_TESTS=OFF"]),
    "teakra": (["teakra"], ["-DTEAKRA_BUILD_TOOLS=OFF", "-DTEAKRA_BUILD_UNIT_TESTS=OFF",
                           "-DTEAKRA_WARNINGS_AS_ERRORS=OFF"]),
}
LIBRARIES = {
    "lib_enet": ("enet", "enet"), "lib_faad2": ("faad2", "faad"),
    "lib_fmt": ("fmt", "fmt"), "lib_glslang": ("glslang", "glslang"),
    "lib_machineindependent": ("glslang", "MachineIndependent"),
    "lib_spirv": ("glslang", "SPIRV"), "lib_sirit": ("sirit", "sirit"),
    "lib_teakra": ("teakra", "teakra"),
}


def run(*args):
    subprocess.run([str(a) for a in args], check=True, cwd=ROOT)


def fetch_sources(manifest):
    SOURCES.mkdir(parents=True, exist_ok=True)
    for name, item in manifest.items():
        archive = CACHE / f"{name}.tar.gz"
        fetch_verified(item["url"], archive, item["sha256"])
        source = SOURCES / name
        revision = source / ".claw-revision"
        if revision.exists() and revision.read_text() == item["revision"]:
            continue
        # These are checksum-pinned vendor archives, extracted only into our cache.
        with tarfile.open(archive) as files:
            for member in files.getmembers():
                if member.name.startswith("/") or ".." in Path(member.name).parts:
                    raise RuntimeError(f"Unsafe archive path in {name}")
        if source.exists():
            shutil.rmtree(source)
        source.mkdir()
        run("tar", "-xzf", archive, "-C", source, "--strip-components=1")
        revision.write_text(item["revision"])
    submodule = SOURCES / "sirit/externals/SPIRV-Headers"
    if not (submodule / "CMakeLists.txt").is_file():
        submodule.parent.mkdir(parents=True, exist_ok=True)
        if submodule.is_dir() and not submodule.is_symlink():
            submodule.rmdir()  # Empty Git submodule directory from the source archive.
        submodule.symlink_to(SOURCES / "spirv-headers", target_is_directory=True)


def headers_only(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    for item in source.rglob("*"):
        if item.is_file() and item.suffix in {".h", ".hpp", ".hpp11", ".inl"}:
            target = destination / item.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, target)


def main():
    manifest = json.loads(MANIFEST.read_text())
    toolchain = subprocess.check_output(["xcodebuild", "-version"], text=True)
    # CMake caches absolute compiler/SDK paths. Never reuse that cache after a
    # workflow switches Xcode versions, even when library sources are unchanged.
    build_root = CACHE / "build" / hashlib.sha256(toolchain.encode()).hexdigest()[:12]
    identity = hashlib.sha256(MANIFEST.read_bytes() + Path(__file__).read_bytes()
                              + toolchain.encode()).hexdigest()
    stamp = ARTIFACTS / ".claw-build"
    if stamp.exists() and stamp.read_text() == identity and (ROOT / "App/Legal/DependencyLicenses.txt").exists() and all(
            (ARTIFACTS / f"{name}.xcframework/Info.plist").exists() for name in LIBRARIES):
        print("PASS: cached pinned iOS 17 dependency rebuilds", flush=True)
        for name in LIBRARIES:
            for binary in (ARTIFACTS / f"{name}.xcframework").glob("*/*.a"):
                verify_ios_deployment(binary, MINIMUM)
        return
    if not shutil.which("cmake"):
        raise SystemExit("CMake is required. Install cmake or add its bin directory to PATH.")
    fetch_sources(manifest)
    outputs = {}
    for platform in ["iphoneos", "iphonesimulator"]:
        for name, (targets, options) in PROJECTS.items():
            build = build_root / platform / name
            print(f"Building {name}: {platform}, arm64, iOS {MINIMUM}", flush=True)
            run("cmake", "-S", SOURCES / name, "-B", build, "-G", "Unix Makefiles",
                "-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={platform}",
                "-DCMAKE_OSX_ARCHITECTURES=arm64", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MINIMUM}",
                "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF",
                "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", *options)
            run("cmake", "--build", build, "--parallel", JOBS, "--target", *targets)
            for target in targets:
                matches = list(build.rglob(f"lib{target}.a"))
                if len(matches) != 1:
                    raise RuntimeError(f"Expected one lib{target}.a, found {matches}")
                verify_ios_deployment(matches[0], MINIMUM)
                outputs[(platform, name, target)] = matches[0]
    headers = ARTIFACTS / "Headers"
    if headers.exists():
        shutil.rmtree(headers)
    for name in ["enet", "fmt", "sirit", "teakra"]:
        headers_only(SOURCES / name / "include", headers / name)
    headers_only(build_root / "iphoneos/faad2/include", headers / "faad2")
    headers_only(SOURCES / "spirv-headers/include", headers / "spirv")
    headers_only(SOURCES / "spirv-headers/include", headers / "sirit")
    headers_only(SOURCES / "glslang/glslang", headers / "glslang/glslang")
    headers_only(SOURCES / "glslang/SPIRV", headers / "glslang/SPIRV")
    for item in (build_root / "iphoneos/glslang").rglob("build_info.h"):
        shutil.copy2(item, headers / "glslang/glslang/build_info.h")
    for name, (project, target) in LIBRARIES.items():
        artifact = ARTIFACTS / f"{name}.xcframework"
        if artifact.exists():
            shutil.rmtree(artifact)
        args = ["xcodebuild", "-create-xcframework"]
        for platform in ["iphoneos", "iphonesimulator"]:
            args += ["-library", outputs[(platform, project, target)]]
            # These compatibility libraries expose no additional headers. Repeating
            # glslang's headers makes SwiftPM produce conflicting copy commands.
            if name not in {"lib_machineindependent", "lib_spirv"}:
                args += ["-headers", headers / project]
        run(*args, "-output", artifact)
    notices = ["Claw — Dependency Licenses\n\nThese libraries are built from the pinned sources below for iOS 17.\n"]
    for name, item in manifest.items():
        notices.append(f"\n{name}\nhttps://github.com/{item['repository']}/tree/{item['revision']}\n")
        for source in sorted((SOURCES / name).iterdir()):
            if source.is_file() and source.name.lower().startswith(("license", "copying", "notice")):
                notices.append(source.name + "\n\n" + source.read_text(errors="replace") + "\n")
    (ROOT / "App/Legal/DependencyLicenses.txt").write_text("\n".join(notices))
    stamp.write_text(identity)
    print("PASS: rebuilt device and Apple Silicon Simulator XCFrameworks for iOS 17", flush=True)


if __name__ == "__main__":
    main()
