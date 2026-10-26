// SPDX-License-Identifier: GPL-3.0-or-later
#include "common/core_build_config.h"
#if CLAW_DISABLE_LOGGING
#include "common/logging/backend.h"
#include "common/logging/log.h"
#include <cstdio>
#include <mutex>
#include <string>

// Keep ordinary logging disabled. A small, local-only record of critical source
// locations survives assertions; format strings and their arguments are never
// formatted or persisted (they may contain guest data or console credentials).
namespace Common::Log {
namespace {
std::mutex diagnostic_mutex;
std::string diagnostic_path;
unsigned diagnostic_count{};

std::string_view SourceLocation(const char* filename) {
    std::string_view source = filename ? filename : "unknown";
    for (const auto marker : {std::string_view{"ThirdParty/Cytrus/"},
                              std::string_view{"ThirdParty\\Cytrus\\"}}) {
        if (const auto offset = source.find(marker); offset != source.npos)
            return source.substr(offset + marker.size());
    }
    const auto slash = source.find_last_of("/\\");
    return slash == source.npos ? source : source.substr(slash + 1);
}
}
void Initialize(std::string_view path) {
    std::lock_guard lock(diagnostic_mutex);
    diagnostic_path = path;
    diagnostic_count = 0;
    if (diagnostic_path.empty()) return;
    if (auto* file = std::fopen(diagnostic_path.c_str(), "w")) {
        std::fputs("Critical core locations only; message content is omitted.\n", file);
        std::fclose(file);
    }
}
void Start() {}
void Stop() {}
void DisableLoggingInTests() {}
void SetGlobalFilter(const Filter&) {}
bool SetRegexFilter(const std::string&) { return true; }
void SetColorConsoleBackendEnabled(bool) {}
void FmtLogMessageImpl(Class log_class, Level level, const char* filename, unsigned int line,
                       const char* function, fmt::string_view, const fmt::format_args&) {
    if (level != Level::Critical) return;
    std::lock_guard lock(diagnostic_mutex);
    if (diagnostic_path.empty() || diagnostic_count >= 16) return;
    ++diagnostic_count;
    if (auto* file = std::fopen(diagnostic_path.c_str(), "a")) {
        const auto source = SourceLocation(filename);
        std::fprintf(file, "Class: %u Source: %.*s:%u Function: %.96s\n",
                     static_cast<unsigned>(log_class),
                     static_cast<int>(std::min(source.size(), std::size_t{200})), source.data(),
                     line, function ? function : "unknown");
        std::fclose(file);
    }
}
} // namespace Common::Log
#endif
