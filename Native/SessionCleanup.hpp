// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstddef>
#include <filesystem>

namespace Claw {
// Call only after all core, audio, presentation and cache workers have stopped.
// Inspect direct children only; never follow symlinks or delete completed binary files.
std::size_t CleanupSessionArtifacts(const std::filesystem::path& sysdata,
                                    const std::filesystem::path& states) noexcept;
}
