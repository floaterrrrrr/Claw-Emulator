// SPDX-License-Identifier: GPL-3.0-or-later
#include "common/dynamic_library/dynamic_library.h"
#include <cassert>
#include <iostream>
#include <string>
#include <utility>

static std::string pending_error, returned_error, requested_path;
static bool succeed{}, silent_failure{};
static int requested_flags{};
constexpr int RTLD_NOW = 2, RTLD_LAZY = 1;
static void* FakeDlopen(const char* path, int flags) {
    requested_path = path; requested_flags = flags;
    if (!succeed && !silent_failure) pending_error = "dyld: exact missing dependency @rpath/libavutil.framework/libavutil";
    return succeed ? reinterpret_cast<void*>(1) : nullptr;
}
static char* FakeDlerror() {
    returned_error = std::exchange(pending_error, {});
    return returned_error.empty() ? nullptr : returned_error.data();
}
namespace Common {
DynamicLibrary::DynamicLibrary() = default;
DynamicLibrary::~DynamicLibrary() = default;
}

int main() {
    Common::DynamicLibrary library;
    pending_error = "stale lookup error";
    assert(!library.Load("@rpath/libavcodec.framework/libavcodec", true));
    assert(!library.IsLoaded() && requested_flags == RTLD_NOW);
    assert(requested_path == "@rpath/libavcodec.framework/libavcodec");
    assert(library.GetLoadError() == "dyld: exact missing dependency @rpath/libavutil.framework/libavutil");
    returned_error = "loader error buffer was overwritten";
    assert(library.GetLoadError() == "dyld: exact missing dependency @rpath/libavutil.framework/libavutil");
    succeed = true;
    assert(library.Load("@rpath/libavcodec.framework/libavcodec"));
    assert(library.IsLoaded() && library.GetLoadError().empty() && requested_flags == RTLD_LAZY);
    succeed = false; silent_failure = true;
    assert(!library.Load("missing", true));
    assert(library.GetLoadError() == "dlopen failed without an error message");
    std::cout << "PASS: production dlopen error snapshots, null-error fallback, stale-error clearing and binding flags\n";
}

// Select the POSIX body on every test host after standard headers are parsed.
// The production Load method is appended by test_framework_probe.py.
#undef _WIN32
#define dlopen FakeDlopen
#define dlerror FakeDlerror
