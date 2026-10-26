// SPDX-License-Identifier: GPL-3.0-or-later
#include "SessionCleanup.hpp"
#include <string>
#include <system_error>

namespace Claw {
namespace {
std::size_t CleanupDirectory(const std::filesystem::path& root, bool state_directory) {
    namespace fs = std::filesystem;
    std::error_code error;
    if (!fs::is_directory(fs::symlink_status(root, error)) || error) return 0;
    std::size_t removed = 0;
    fs::directory_iterator it(root, fs::directory_options::skip_permission_denied, error), end;
    while (!error && it != end) {
        const auto path = it->path();
        const auto name = path.filename().string();
        const bool temporary = state_directory ? name.ends_with(".cst.tmp") :
            name.ends_with(".tmp") || name.ends_with(".lock") ||
            name.ends_with(".bin.partial") || name.ends_with(".cst.partial");
        const auto status = it->symlink_status(error);
        if (!error && temporary && fs::is_regular_file(status)) {
            if (fs::remove(path, error) && !error) ++removed;
        }
        // A single inaccessible entry must not abort cleanup of other entries.
        error.clear();
        it.increment(error);
    }
    return removed;
}
}

std::size_t CleanupSessionArtifacts(const std::filesystem::path& sysdata,
                                    const std::filesystem::path& states) noexcept {
    try {
        return CleanupDirectory(sysdata, false) + CleanupDirectory(states, true);
    } catch (...) {
        // Cleanup is best effort; shutdown must not throw through the C bridge.
        return 0;
    }
}
}
