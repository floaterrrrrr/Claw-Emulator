#!/usr/bin/env python3
"""Check bundled FFmpeg signatures and the production loader's iOS branches.

The fake dynamic-library adapter injects loader/symbol failures. It does not
execute iOS Mach-O files on the host or replace a device launch test.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LIBRARIES = ("avutil", "avcodec", "avfilter", "avformat", "swresample")


def headers_at(directory, variant):
    for item in (ROOT / "ThirdParty/Dependencies/FFmpeg").glob("*.xcframework"):
        headers = item / variant / (item.stem + ".framework") / "Headers"
        target = directory / item.stem
        target.mkdir(parents=True, exist_ok=True)
        for header in headers.glob("*.h"):
            shutil.copy2(header, target / header.name)


FAKE_LIBRARY = r'''
#pragma once
#include <cassert>
#include <string>
#include <string_view>
#include <vector>
namespace TestLoader {
inline std::string missing_symbol, missing_library, wrong_version;
inline std::vector<std::string> paths, symbols;
inline unsigned utility() { return (60u + (wrong_version == "avutil")) << 16; }
inline unsigned codec() { return (62u + (wrong_version == "avcodec")) << 16; }
inline unsigned filter() { return (11u + (wrong_version == "avfilter")) << 16; }
inline unsigned format() { return (62u + (wrong_version == "avformat")) << 16; }
inline unsigned resample() { return (6u + (wrong_version == "swresample")) << 16; }
inline void other() {}
}
namespace Common {
class DynamicLibrary {
    bool loaded{};
public:
    bool Load(std::string_view path, bool resolve_now = false) {
        assert(resolve_now); // iOS must resolve transitive references eagerly.
        TestLoader::paths.emplace_back(path);
        loaded = TestLoader::missing_library.empty() ||
                 path.find(TestLoader::missing_library + ".framework/") == path.npos;
        return loaded;
    }
    bool IsLoaded() const { return loaded; }
    std::string_view GetLoadError() const { return "injected load failure"; }
    template <typename T> T GetSymbol(std::string_view name) const {
        assert(loaded);
        TestLoader::symbols.emplace_back(name);
        if (name == TestLoader::missing_symbol) return nullptr;
        if (name == "avutil_version") return reinterpret_cast<T>(&TestLoader::utility);
        if (name == "avcodec_version") return reinterpret_cast<T>(&TestLoader::codec);
        if (name == "avfilter_version") return reinterpret_cast<T>(&TestLoader::filter);
        if (name == "avformat_version") return reinterpret_cast<T>(&TestLoader::format);
        if (name == "swresample_version") return reinterpret_cast<T>(&TestLoader::resample);
        return reinterpret_cast<T>(&TestLoader::other);
    }
};
}
'''

HARNESS = r'''
#include "common/dynamic_library/dynamic_library.h"
#include "common/dynamic_library/ffmpeg.h"
int main(int argc, char** argv) {
    assert(argc == 3);
    const std::string mode = argv[1], value = argv[2];
    if (mode == "symbol") TestLoader::missing_symbol = value;
    if (mode == "library") TestLoader::missing_library = value;
    if (mode == "version") TestLoader::wrong_version = value;
    const bool loaded = DynamicLibrary::FFmpeg::LoadFFmpeg();
    assert(loaded == (mode == "success"));
    for (const auto& path : TestLoader::paths) {
        assert(path.starts_with("@rpath/lib") && path.find(".framework/lib") != path.npos);
        assert(path.find(".dylib") == path.npos);
    }
    if (loaded) {
        assert(TestLoader::paths.size() == 5);
        const auto count = TestLoader::paths.size();
        assert(DynamicLibrary::FFmpeg::LoadFFmpeg());
        assert(TestLoader::paths.size() == count); // No repeated dlopen per use/frame.
    } else {
        TestLoader::missing_symbol.clear();
        TestLoader::missing_library.clear();
        TestLoader::wrong_version.clear();
        assert(DynamicLibrary::FFmpeg::LoadFFmpeg()); // A failed attempt can be retried.
    }
}
'''


def main():
    cxx = os.environ.get("CXX", "c++")
    source = (ROOT / "ThirdParty/Cytrus/common/dynamic_library/ffmpeg.cpp").read_text()
    symbols = sorted({symbol for library, symbol in re.findall(r"LOAD_SYMBOL\((\w+),\s*(\w+)\)", source)
                      if library in LIBRARIES and symbol not in ("av_opt_child_class_next", "swr_alloc_set_opts")})
    with tempfile.TemporaryDirectory(prefix="claw-ffmpeg-loader-") as directory:
        work = Path(directory)
        for variant in ("ios-arm64", "ios-arm64-simulator"):
            headers = work / variant
            headers_at(headers, variant)
            probe = work / "signatures.cpp"
            probe.write_text('#include <type_traits>\nextern "C" {\n'
                '#include <libavutil/hwcontext.h>\n#include <libavfilter/buffersrc.h>\n'
                '#include <libavfilter/buffersink.h>\n}\n'
                '#include "common/dynamic_library/ffmpeg.h"\n' + "".join(
                    f'static_assert(std::is_same_v<DynamicLibrary::FFmpeg::{name}_func, '
                    f'decltype(&::{name})>, "{name} signature mismatch");\n' for name in symbols))
            subprocess.run([cxx, "-std=c++20", "-Wno-deprecated-declarations", "-fsyntax-only",
                            "-IThirdParty/Cytrus/include", "-I" + str(headers), str(probe)],
                           cwd=ROOT, check=True)
        fake = work / "fake"
        (fake / "common/dynamic_library").mkdir(parents=True)
        (fake / "common/logging").mkdir()
        (fake / "common/dynamic_library/dynamic_library.h").write_text(FAKE_LIBRARY)
        (fake / "common/logging/log.h").write_text(
            "#pragma once\n#define LOG_WARNING(...) ((void)0)\n#define LOG_INFO(...) ((void)0)\n")
        (fake / "TargetConditionals.h").write_text("#pragma once\n#define TARGET_OS_IPHONE 1\n")
        harness = work / "loader.cpp"
        harness.write_text(HARNESS)
        binary = work / ("loader.exe" if os.name == "nt" else "loader")
        subprocess.run([cxx, "-std=c++20", "-O2", "-D__APPLE__=1",
                        "-Wno-deprecated-declarations", "-I" + str(fake),
                        "-IThirdParty/Cytrus/include", "-I" + str(work / "ios-arm64"),
                        str(harness), "ThirdParty/Cytrus/common/dynamic_library/ffmpeg.cpp",
                        "-o", str(binary)], cwd=ROOT, check=True)
        cases = [("success", "all")]
        for library in LIBRARIES:
            cases += [("symbol", library + "_version"), ("library", "lib" + library),
                      ("version", library)]
        cases += [("symbol", "av_buffer_ref"), ("symbol", "avcodec_open2"),
                  ("symbol", "swr_convert")]
        for case in cases:
            completed = subprocess.run([str(binary), *case], cwd=ROOT, check=True,
                                       timeout=10, capture_output=True, text=True)
            mode, value = case
            if mode == "library":
                expected = f"Claw FFmpeg: dlopen(@rpath/{value}.framework/{value}) failed: injected load failure"
                assert expected in completed.stderr, completed.stderr
            elif mode == "symbol":
                assert f"Claw FFmpeg: missing symbol {value} " in completed.stderr, completed.stderr
            elif mode == "version":
                assert f"Claw FFmpeg: lib{value} major version " in completed.stderr, completed.stderr
            else:
                assert not completed.stderr, completed.stderr
    print(f"PASS: {len(symbols)} FFmpeg signatures in both slices; {len(cases)} iOS loader, missing-symbol, version, retry and caching cases")


if __name__ == "__main__":
    main()
