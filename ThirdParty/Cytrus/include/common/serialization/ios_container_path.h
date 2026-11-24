// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace FileUtil::StatePath {

inline constexpr std::string_view user_dir_token = "%CITRA_USER_DIR%";
inline constexpr std::string_view container_token = "%CITRA_IOS_DATA_CONTAINER%";

inline std::string_view IOSContainerRoot(std::string_view path) {
    constexpr std::string_view marker = "/Containers/Data/Application/";
    const auto marker_pos = path.find(marker);
    if (!path.starts_with('/') || marker_pos == std::string_view::npos) {
        return {};
    }

    const auto uuid_start = marker_pos + marker.size();
    const auto tail = path.substr(uuid_start);
    const auto uuid = tail.substr(0, tail.find('/'));
    if (uuid.size() != 36) {
        return {};
    }
    for (std::size_t i = 0; i < uuid.size(); ++i) {
        const auto valid = i == 8 || i == 13 || i == 18 || i == 23
                               ? std::string_view("-")
                               : std::string_view("0123456789ABCDEFabcdef");
        if (valid.find(uuid[i]) == std::string_view::npos) {
            return {};
        }
    }
    return path.substr(0, uuid_start + uuid.size());
}

inline std::string_view CanonicalIOSContainerRoot(std::string_view root) {
    if (root.starts_with("/private/var/")) {
        root.remove_prefix(std::string_view("/private").size());
    }
    return root;
}

inline bool IsContainerSuffix(std::string_view suffix) {
    if (suffix.find('\0') != std::string_view::npos ||
        suffix.find('\\') != std::string_view::npos) {
        return false;
    }
    while (!suffix.empty()) {
        const auto separator = suffix.find('/');
        if (suffix.substr(0, separator) == "..") {
            return false;
        }
        if (separator == std::string_view::npos) {
            break;
        }
        suffix.remove_prefix(separator + 1);
    }
    return true;
}

// These tokens stay inside the existing serialized string field. Files under
// EmulationData use the same root marker as older builds.
inline std::optional<std::string> EncodeIOSPath(std::string_view path, std::string_view user_dir) {
    const auto source = IOSContainerRoot(path);
    const auto current = IOSContainerRoot(user_dir);
    if (source.empty() || CanonicalIOSContainerRoot(source) != CanonicalIOSContainerRoot(current)) {
        return std::nullopt;
    }
    const auto suffix = path.substr(source.size());
    if (!IsContainerSuffix(suffix)) {
        return std::nullopt;
    }
    const auto user_suffix = user_dir.substr(current.size());
    if (user_suffix.ends_with('/') && suffix.starts_with(user_suffix)) {
        return std::string(user_dir_token).append(suffix.substr(user_suffix.size()));
    }
    return std::string(container_token).append(suffix);
}

inline std::optional<std::string> DecodeIOSPath(std::string_view path, std::string_view user_dir) {
    const auto current = IOSContainerRoot(user_dir);
    if (current.empty()) {
        return std::nullopt;
    }

    if (path.starts_with(user_dir_token)) {
        return std::string(user_dir).append(path.substr(user_dir_token.size()));
    }

    const auto prefix = path.starts_with(container_token) ? container_token : IOSContainerRoot(path);
    if (prefix.empty()) {
        return std::nullopt;
    }
    const auto suffix = path.substr(prefix.size());
    if ((!suffix.empty() && !suffix.starts_with('/')) || !IsContainerSuffix(suffix)) {
        return std::nullopt;
    }
    return std::string(current).append(suffix);
}

} // namespace FileUtil::StatePath
