// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <functional>
#include <string>

namespace Claw {
struct FrameworkProbeAPI {
    std::function<void*(const char*)> open;
    std::function<void*(void*, const char*)> symbol;
    std::function<std::string()> error;
    std::function<std::string(void*)> image;
    std::function<void(void*)> close;
};

struct FrameworkProbeResult {
    enum class Status { Loaded, LoadFailed, MissingVersion, UnexpectedImage, VersionMismatch };
    Status status{Status::LoadFailed};
    std::string library, requested, expected, resolved, error;
    unsigned version{};
};

// Called during launch diagnostics, never during a frame. The native adapter
// uses dlopen(RTLD_NOW), dlsym and dladdr; tests inject each loader failure.
inline FrameworkProbeResult ProbeFramework(const std::string& name, unsigned expected_major,
                                           const std::string& framework_root,
                                           const FrameworkProbeAPI& api) {
    FrameworkProbeResult result;
    result.library = "lib" + name;
    const std::string relative = result.library + ".framework/" + result.library;
    result.requested = "@rpath/" + relative;
    result.expected = framework_root + "/" + relative;
    static_cast<void>(api.error());
    void* handle = api.open(result.requested.c_str());
    const std::string load_error = api.error(); // Capture before any other loader operation.
    if (!handle) {
        result.error = load_error.empty() ? "dlopen failed without an error message" : load_error;
        return result;
    }
    struct CloseHandle {
        void* handle;
        const FrameworkProbeAPI& api;
        ~CloseHandle() { api.close(handle); }
    } guard{handle, api};
    static_cast<void>(api.error());
    void* symbol = api.symbol(handle, (name + "_version").c_str());
    const std::string symbol_error = api.error();
    if (!symbol || !symbol_error.empty()) {
        result.status = FrameworkProbeResult::Status::MissingVersion;
        result.error = symbol_error.empty() ? "Missing " + name + "_version" : symbol_error;
        return result;
    }
    result.resolved = api.image(symbol);
    if (result.resolved != result.expected) {
        result.status = FrameworkProbeResult::Status::UnexpectedImage;
        result.error = "Version symbol did not resolve to the expected app-bundled framework";
        return result;
    }
    result.version = reinterpret_cast<unsigned (*)()>(symbol)();
    if ((result.version >> 16) != expected_major) {
        result.status = FrameworkProbeResult::Status::VersionMismatch;
        result.error = "Loaded major version differs from the compiled headers";
        return result;
    }
    result.status = FrameworkProbeResult::Status::Loaded;
    return result;
}

inline std::string DescribeFrameworkProbe(const FrameworkProbeResult& result) {
    return result.library + ": " +
        (result.status == FrameworkProbeResult::Status::Loaded ? "PASS" : "FAIL") +
        "\nRequested: " + result.requested + "\nExpected: " + result.expected +
        "\nResolved: " + result.resolved + "\nVersion: " + std::to_string(result.version >> 16) +
        "." + std::to_string((result.version >> 8) & 255) + "." + std::to_string(result.version & 255) +
        "\nError: " + result.error + "\n";
}
} // namespace Claw
