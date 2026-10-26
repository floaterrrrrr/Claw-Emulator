// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <istream>
#include <string>
#include <string_view>
#include <vector>

namespace Cheats::AR {
struct Entry {
    std::string name, code, comments;
    bool enabled = false;
};
inline std::string_view Trim(std::string_view text) {
    const auto first = text.find_first_not_of(" \t\r\n");
    if (first == std::string_view::npos) return {};
    return text.substr(first, text.find_last_not_of(" \t\r\n") - first + 1);
}
inline bool CodeLine(std::string_view text) {
    if (text.size() != 17 || text[8] != ' ') return false;
    for (std::size_t i = 0; i < text.size(); ++i) {
        if (i == 8) continue;
        const char c = text[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
              (c >= 'A' && c <= 'F'))) return false;
    }
    return true;
}
// Citra '*' comments/enabled metadata and CTRPF folder/brace syntax share the
// existing Action Replay executor. Reject a malformed block as a whole.
inline std::vector<Entry> Parse(std::istream& input) {
    std::vector<Entry> result;
    Entry entry;
    bool invalid = false, brace = false, first = true;
    std::size_t bytes = 0;
    auto finish = [&] {
        if (!invalid && !brace && !entry.name.empty() && !entry.code.empty())
            result.push_back(std::move(entry));
        entry = {}; invalid = false; brace = false;
    };
    std::string line;
    while (std::getline(input, line)) {
        bytes += line.size() + 1;
        if (bytes > 1024 * 1024 || line.size() > 4096) return {};
        std::string_view text = line;
        if (first && text.starts_with("\xEF\xBB\xBF")) text.remove_prefix(3);
        first = false;
        text = Trim(text);
        if (!brace && text.starts_with('[') && text.ends_with(']')) {
            finish();
            auto name = Trim(text.substr(1, text.size() - 2));
            if (name == "--" || (name.starts_with("++") && name.ends_with("++"))) continue;
            entry.name = name;
        } else if (brace || text.starts_with('{')) {
            if (!brace) { text.remove_prefix(1); brace = true; }
            const auto end = text.find('}');
            if (end != std::string_view::npos) {
                if (!Trim(text.substr(end + 1)).empty()) invalid = true;
                text = text.substr(0, end); brace = false;
            }
            entry.comments += std::string(text) + '\n';
        } else if (text == "*citra_enabled") {
            entry.enabled = true;
        } else if (text.starts_with('*')) {
            entry.comments += std::string(text.substr(1)) + '\n';
        } else if (!text.empty()) {
            if (!CodeLine(text) || entry.name.empty()) invalid = true;
            else entry.code += std::string(text) + '\n';
        }
    }
    finish();
    return result;
}

} // namespace Cheats::AR
