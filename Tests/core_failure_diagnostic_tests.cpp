// SPDX-License-Identifier: GPL-3.0-or-later
#include "common/logging/backend.h"
#include "common/logging/log.h"
#include <cassert>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

static std::string contents(const char* path) {
    std::ifstream file(path);
    return {std::istreambuf_iterator<char>(file), {}};
}

int main(int argc, char** argv) {
    assert(argc == 2);
    using namespace Common::Log;
    Initialize(argv[1]);
    const auto empty = contents(argv[1]);
    LOG_INFO(Core, "ordinary message");
    LOG_ERROR(Core, "ordinary error");
    assert(contents(argv[1]) == empty);
    const std::string secret = "private-game-name-and-console-key";
    LOG_CRITICAL(Core, "private content: {}", secret);
    auto text = contents(argv[1]);
    assert(text.find("Source:") != text.npos);
    assert(text.find(secret) == text.npos && text.find("private content") == text.npos);
    assert(text.find("Function: main") != text.npos);

    FmtLogMessageImpl(Class::Debug, Level::Critical,
        "/Volumes/private-build/ThirdParty/Cytrus/core/example.cpp", 123,
        "TestFatal", {}, {});
    FmtLogMessageImpl(Class::Debug, Level::Critical,
        "C:\\private-build\\ThirdParty\\Cytrus\\core\\example.cpp", 456,
        "TestWindowsFatal", {}, {});
    text = contents(argv[1]);
    assert(text.find("core/example.cpp:123") != text.npos);
    assert(text.find("core\\example.cpp:456") != text.npos);
    assert(text.find("private-build") == text.npos);

    std::vector<std::thread> workers;
    for (int i = 0; i < 8; ++i) workers.emplace_back([] {
        for (int j = 0; j < 50; ++j) LOG_CRITICAL(Core, "not retained");
    });
    for (auto& worker : workers) worker.join();
    text = contents(argv[1]);
    assert(std::count(text.begin(), text.end(), '\n') == 17);
    assert(text.size() < 8192);
    Initialize(argv[1]);
    assert(contents(argv[1]) == empty); // No stale record after a new launch.
    Initialize({});
    LOG_CRITICAL(Core, "unconfigured diagnostics must be harmless");
}
