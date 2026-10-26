// SPDX-License-Identifier: GPL-3.0-or-later
#include "common/core_build_config.h"
#include "common/web_util.h"
#include <cassert>
#include <iostream>

int main() {
    // A stored preference must never make a strict build select a JIT backend.
    assert(!Core::BuildConfig::AllowJit(false));
    assert(Core::BuildConfig::AllowJit(true) == !DISABLE_JIT);
    assert(Core::BuildConfig::UseFastInterpreter(true));
    assert(Core::BuildConfig::UseFastInterpreter(false) == bool(STRICT_INTERPRETER));

    // The guest HTTP service still has its linked parser with the host web utility excluded.
    const auto https = Common::SplitUrl("https://example.test/path?value=1");
    assert(https.is_https && https.host == "example.test" && https.port == 443);
    assert(https.path == "/path?value=1");
    const auto http = Common::SplitUrl("http://example.test");
    assert(!http.is_https && http.host == "example.test" && http.port == 80 && http.path == "/");
    const auto explicitPort = Common::SplitUrl("http://example.test:8080/file");
    assert(explicitPort.port == 8080 && explicitPort.host == "example.test");
    const auto invalidPort = Common::SplitUrl("https://example.test:invalid/file");
    assert(invalidPort.port == 443 && invalidPort.host == "example.test");
    std::cout << "PASS: backend policy (strict=" << STRICT_INTERPRETER
              << ", JIT disabled=" << DISABLE_JIT << ") and linked guest URL parser\n";
}
