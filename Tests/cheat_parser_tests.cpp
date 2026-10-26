// SPDX-License-Identifier: GPL-3.0-or-later
#include "core/cheats/ar_format.h"
#include <cassert>
#include <iostream>
#include <sstream>

int main() {
    auto parse = [](std::string s) { std::istringstream in(s); return Cheats::AR::Parse(in); };
    const auto compatible = parse("\xEF\xBB\xBF[++Folder++]\r\n[Test]\r\n*citra_enabled\r\n*Note\r\n28a01234 00000000\r\n{Brace\r\ncomment}\r\n[--]\r\n");
    assert(compatible.size() == 1 && compatible[0].enabled);
    assert(compatible[0].comments == "Note\nBrace\ncomment\n");
    assert(parse("[Bad]\n28A01234 00000000\nnot a code\n[Good]\n28A01234 00000001\n").size() == 1);
    assert(parse("[Bad]\n28A01234 00000000\n{unfinished").empty());
    assert(parse("[Bad]\n28A01234 0000000G\n").empty());
    assert(parse(std::string(4097, 'x')).empty());
    std::cout << "PASS: generic Action Replay parser accepts known syntax and rejects malformed blocks\n";
}
