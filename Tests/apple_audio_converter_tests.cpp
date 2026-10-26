// SPDX-License-Identifier: GPL-3.0-or-later
// Executes the production Apple converter against the real macOS framework.
#include "audio_core/apple_pcm_converter.h"
#include "audio_core/audio_types.h"
#include "audio_core/mobile_audio_buffer.h"
#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
#include <memory>
#include <numbers>
#include <stdexcept>
#include <vector>

static double Frequency(const std::vector<s16>& measured, int channel) {
    std::size_t crossings = 0;
    for (std::size_t i = 2 + channel; i < measured.size(); i += 2)
        if (measured[i - 2] <= 0 && measured[i] > 0) ++crossings;
    return static_cast<double>(crossings) * 48000 / (measured.size() / 2);
}

static void CheckConversion(double speed, unsigned int native_rate = AudioCore::native_sample_rate,
                            std::size_t target = AudioCore::mobile_latency_frames) {
    const auto input_rate = static_cast<unsigned int>(native_rate * speed);
    std::size_t available = 0, sample_index = 0;
    bool failing = false;
    AudioCore::ApplePCMConverter converter([&](s16* destination, std::size_t requested) {
        if (failing) throw std::runtime_error("Test input failure");
        // Deliberately fragmented input tests repeated Supply calls and partial fills.
        const auto count = std::min<std::size_t>({requested, available, 257});
        for (std::size_t i = 0; i < count; ++i, ++sample_index) {
            destination[i * 2] = static_cast<s16>(12000 * std::sin(
                2 * std::numbers::pi * 1000 * sample_index / native_rate));
            destination[i * 2 + 1] = static_cast<s16>(9000 * std::sin(
                2 * std::numbers::pi * 1733 * sample_index / native_rate));
        }
        available -= count;
        return count;
    }, input_rate);
    auto queue = std::make_unique<AudioCore::MobilePCM16Buffer>(target);
    std::array<s16, 2048 + 2> converted{};
    std::array<s16, 480 * 2> playback{};
    std::vector<s16> measured;
    unsigned int underruns = 0;
    std::size_t total_output = 0;
    assert(converter.Convert({}) == 0);
    assert(converter.Convert({converted.data(), 1}) == 0);
    // Empty input is temporary starvation, never synthetic audio or EOF.
    assert(converter.Convert({converted.data() + 1, 1024 * 2}) == 0);
    for (unsigned int tick = 0; tick < 2000; ++tick) {
        const auto stallTicks = target <= 1024 ? 1u : target < AudioCore::mobile_latency_frames ? 2u : 8u;
        const bool stalled = tick >= 1200 && tick < 1200 + stallTicks;
        if (!stalled) available += (tick + 1) * input_rate / 100 - tick * input_rate / 100;
        for (int attempt = 0; attempt < 12; ++attempt) {
            const auto buffered = queue->BufferedFrames();
            if (buffered >= queue->TargetFrames()) break;
            const auto quantum = target < AudioCore::mobile_latency_frames ? 512u : 1024u;
            const auto requested = std::min<std::size_t>(quantum, queue->TargetFrames() - buffered);
            converted.front() = -23456;
            converted.back() = -23456;
            const auto count = converter.Convert({converted.data() + 1, requested * 2});
            assert(count <= requested);
            assert(converted.front() == -23456 && converted.back() == -23456);
            total_output += count;
            assert(queue->Push({converted.data() + 1, count * 2}) == count);
            if (count == 0) break;
        }
        const auto count = queue->Read(playback);
        if (tick >= 100 && count != 480) ++underruns;
        if (tick >= 1500) measured.insert(measured.end(), playback.begin(), playback.end());
    }
    // Fixed-rate conversion must neither repeatedly inject silence nor invent time.
    const auto expected = sample_index * 48000.0 / input_rate;
    assert(std::abs(static_cast<double>(total_output) - expected) < 512);
    assert(underruns == 0);
    const auto left = Frequency(measured, 0), right = Frequency(measured, 1);
    assert(std::abs(left - 1000 * speed) < 5);
    assert(std::abs(right - 1733 * speed) < 5);
    std::cout << "PASS: Apple " << input_rate << " -> 48000 Hz PCM16 interleaved stereo, "
              << left << "/" << right << " Hz tones, temporary-starvation recovery, "
              << "zero post-prime underruns with " << target << "-frame target and "
              << (target <= 1024 ? 10 : target < AudioCore::mobile_latency_frames ? 20 : 80) << " ms stall\n";

    // Resume after a longer drought by resetting the producer-owned converter.
    converter.Reset();
    failing = true;
    bool caught = false;
    try { converter.Convert({converted.data() + 1, 2048}); }
    catch (const std::runtime_error&) { caught = true; }
    assert(caught); // exceptions never escape through an Apple C callback
    failing = false;
    converter.Reset();
    available = 2048;
    assert(converter.Convert({converted.data() + 1, 2048}) > 0);
}

int main() {
    CheckConversion(1.0);
    CheckConversion(2.0);
    CheckConversion(1.0, 48000);
    CheckConversion(1.0, 32768, 2048); // mGBA native-rate low-latency output.
    CheckConversion(2.0, 32768, 2048);
    CheckConversion(1.0, 32768, 1024);
    CheckConversion(2.0, 32768, 1024);
    CheckConversion(1.0, 65536, 1024);
    CheckConversion(1.0, 262144, 1024);
    // Converter lifecycle remains safe when returning to normal playback.
    for (int i = 0; i < 8; ++i) {
        AudioCore::ApplePCMConverter converter([](s16* output, std::size_t count) {
            std::fill(output, output + count * 2, 0);
            return count;
        }, AudioCore::native_sample_rate * (i % 2 ? 2 : 1));
        std::array<s16, 2048> output{};
        assert(converter.Convert(output) == 1024);
        for (const auto sample : output) assert(sample == 0);
    }
}
