// SPDX-License-Identifier: GPL-3.0-or-later
#include "FrameworkProbe.hpp"
#include <cassert>
#include <iostream>
#include <utility>

using namespace Claw;
static unsigned version{}, version_calls{};
static unsigned GetVersion() { ++version_calls; return version; }

struct FakeLoader {
    unsigned closes{}, opens{}, lookups{};
    bool fail_load{}, fail_symbol{}, silent_failure{}, symbol_error{};
    std::string pending, resolved, requested, requested_symbol;
    const std::string exact_error = "dlopen(@rpath/libavcodec.framework/libavcodec, 2): Library not loaded: image not found";
    FrameworkProbeAPI api() {
        return {
            [&](const char* path) -> void* {
                ++opens; requested = path;
                if (fail_load) { if (!silent_failure) pending = exact_error; return nullptr; }
                return this;
            },
            [&](void* handle, const char* name) -> void* {
                assert(handle == this); ++lookups; requested_symbol = name;
                if (fail_symbol || symbol_error) pending = "dlsym: missing version symbol";
                return fail_symbol ? nullptr : reinterpret_cast<void*>(&GetVersion);
            },
            [&] { return std::exchange(pending, {}); },
            [&](void* symbol) { assert(symbol == reinterpret_cast<void*>(&GetVersion)); return resolved; },
            [&](void* handle) { assert(handle == this); ++closes; pending = "later close error"; },
        };
    }
};

int main() {
    const std::string root = "/signed/Claw.app/Frameworks";
    for (const auto* name : {"avutil", "avcodec", "avfilter", "avformat", "swresample", "avdevice", "swscale"}) {
        FakeLoader loader;
        loader.resolved = root + "/lib" + name + ".framework/lib" + name;
        version = (62 << 16) | (1 << 8) | 100; version_calls = 0;
        const auto result = ProbeFramework(name, 62, root, loader.api());
        assert(result.status == FrameworkProbeResult::Status::Loaded);
        assert(result.requested == "@rpath/lib" + std::string(name) + ".framework/lib" + name);
        assert(result.resolved == result.expected && result.version == version);
        assert(loader.requested_symbol == std::string(name) + "_version");
        assert(loader.closes == 1 && loader.lookups == 1 && version_calls == 1);
    }
    FakeLoader missing;
    missing.fail_load = true;
    missing.pending = "stale error must be cleared";
    auto result = ProbeFramework("avcodec", 62, root, missing.api());
    assert(result.status == FrameworkProbeResult::Status::LoadFailed);
    assert(result.error == missing.exact_error && missing.closes == 0 && missing.lookups == 0);
    assert(DescribeFrameworkProbe(result).find(missing.exact_error) != std::string::npos);
    missing.silent_failure = true;
    result = ProbeFramework("avcodec", 62, root, missing.api());
    assert(result.error == "dlopen failed without an error message");

    for (bool null_symbol : {false, true}) {
        FakeLoader loader;
        loader.fail_symbol = null_symbol; loader.symbol_error = !null_symbol;
        version_calls = 0;
        result = ProbeFramework("avcodec", 62, root, loader.api());
        assert(result.status == FrameworkProbeResult::Status::MissingVersion);
        assert(result.error == "dlsym: missing version symbol");
        assert(loader.closes == 1 && version_calls == 0);
    }
    for (const auto* wrong : {"", "/other/libavcodec.framework/libavcodec",
                              "/signed/Claw.app/Frameworks-copy/libavcodec.framework/libavcodec"}) {
        FakeLoader loader; loader.resolved = wrong; version_calls = 0;
        result = ProbeFramework("avcodec", 62, root, loader.api());
        assert(result.status == FrameworkProbeResult::Status::UnexpectedImage);
        assert(loader.closes == 1 && version_calls == 0);
    }
    FakeLoader mismatch; mismatch.resolved = root + "/libavcodec.framework/libavcodec";
    version = 63 << 16;
    result = ProbeFramework("avcodec", 62, root, mismatch.api());
    assert(result.status == FrameworkProbeResult::Status::VersionMismatch && mismatch.closes == 1);
    std::cout << "PASS: seven bundled-image paths, exact loader errors, missing symbols, wrong images/versions and balanced handles\n";
}
