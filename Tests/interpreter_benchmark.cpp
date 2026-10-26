// SPDX-License-Identifier: GPL-3.0-or-later
// Host mock dispatch benchmark. Uses the real BlockCache and decoded instruction
// types, but does NOT invoke ARM_FastInterp::Run or the ARM64 assembly handlers.
#include "core/arm/fastinterp/fastinterp_cache.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <memory>
#include <vector>
using namespace Core::FastInterp;

int main() {
    auto cache = std::make_unique<BlockCache>();
    constexpr unsigned blockCount = 64, blockSize = 32, samples = 240;
    constexpr unsigned mockOpsPerSample = 200000;
    for (unsigned b = 0; b < blockCount; ++b) {
        bool hit;
        auto* block = cache->LookupOrAllocate(0x100000 + b * 128, hit);
        block->inst_count = blockSize;
        block->end_pc = block->start_pc + blockSize * 4;
        for (unsigned i = 0; i < blockSize; ++i) {
            auto& op = block->instructions[i];
            op.opcode = i % 2 == 0 ? Opcode::Add : Opcode::Eor;
            op.rd = static_cast<u8>(i % 8);
            op.dp.rn = static_cast<u8>((i + 1) % 8);
            op.dp.imm = i * 17 + b;
        }
    }
    std::array<u32, 16> registers{};
    registers[0] = 1;
    std::vector<double> times;
    for (unsigned sample = 0; sample < samples + 10; ++sample) {
        auto start = std::chrono::steady_clock::now();
        for (unsigned b = 0; b < mockOpsPerSample / blockSize; ++b) {
            auto* block = cache->Lookup(0x100000 + (b % blockCount) * 128);
            if (!block) { std::cerr << "Unexpected cache miss\n"; return 1; }
            for (unsigned i = 0; i < block->inst_count; ++i) {
                const auto& op = block->instructions[i];
                switch (op.opcode) {
                case Opcode::Add: registers[op.rd] = registers[op.dp.rn] + op.dp.imm; break;
                case Opcode::Eor: registers[op.rd] = registers[op.dp.rn] ^ op.dp.imm; break;
                default: return 1;
                }
            }
        }
        const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        if (sample >= 10) times.push_back(ms);
    }
    std::sort(times.begin(), times.end());
#if defined(__aarch64__)
    constexpr auto arch = "arm64";
#elif defined(__x86_64__)
    constexpr auto arch = "x86_64";
#else
    constexpr auto arch = "other";
#endif
    std::cout << std::fixed << std::setprecision(6)
              << "{\n  \"kind\": \"host mock dispatch; real block cache\",\n"
              << "  \"host_architecture\": \"" << arch << "\",\n"
              << "  \"jit_used\": false,\n  \"full_arm64_interpreter_measured\": false,\n"
              << "  \"mock_operations_per_sample\": " << mockOpsPerSample << ",\n"
              << "  \"samples\": " << samples << ",\n"
              << "  \"median_ms\": " << times[times.size() / 2] << ",\n"
              << "  \"p95_ms\": " << times[times.size() * 95 / 100] << ",\n"
              << "  \"reference_60hz_budget_ms\": 16.666667,\n"
              << "  \"reference_30fps_budget_ms\": 33.333333,\n"
              << "  \"iphone_timing_target_status\": \"not evaluated\",\n"
              << "  \"checksum\": " << registers[0] << "\n}\n";
}
