// SPDX-License-Identifier: GPL-3.0-or-later
// Link against the real SoundTouch library and audio_core/time_stretch.cpp.
#include "audio_core/audio_types.h"
#include "audio_core/time_stretch.h"
#include "audio_core/mobile_audio_buffer.h"
#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
#include <numbers>
#include <memory>
#include <vector>

static void CheckPitch(unsigned int rate, double speed = 1.0) {
    AudioCore::TimeStretcher stretcher;
    stretcher.SetOutputSampleRate(rate);
    std::array<s16, 2048> input{};
    std::array<s16, 2048> output{};
    std::vector<s16> measured;
    constexpr double frequency = 1000.0;
    for (unsigned int tick = 0; tick < 2000; ++tick) {
        const auto input_start = static_cast<unsigned int>(tick * AudioCore::native_sample_rate * speed / 100);
        const auto input_end = static_cast<unsigned int>((tick + 1) * AudioCore::native_sample_rate * speed / 100);
        const auto output_start = tick * rate / 100;
        const auto output_end = (tick + 1) * rate / 100;
        for (unsigned int i = input_start; i < input_end; ++i) {
            const auto sample = static_cast<s16>(12000 * std::sin(2 * std::numbers::pi * frequency * i /
                                                                 AudioCore::native_sample_rate));
            input[(i - input_start) * 2] = sample;
            input[(i - input_start) * 2 + 1] = sample;
        }
        output.front() = -23456;
        output.back() = -23456;
        const auto written = stretcher.Process(input.data(), input_end - input_start,
                                               output.data() + 1, output_end - output_start);
        assert(written <= output_end - output_start);
        assert(output.front() == -23456 && output.back() == -23456);
        for (std::size_t i = 0; i < written; ++i) {
            assert(output[1 + i * 2] == output[2 + i * 2]);
            if (tick >= 1700) measured.push_back(output[1 + i * 2]);
        }
    }
    assert(measured.size() > rate * 2.5);
    unsigned int crossings = 0;
    for (std::size_t i = 1; i < measured.size(); ++i)
        if (measured[i - 1] <= 0 && measured[i] > 0) ++crossings;
    const double actual = static_cast<double>(crossings) * rate / measured.size();
    assert(std::abs(actual - frequency) < 20);
    assert(stretcher.Process(nullptr, 0, nullptr, 0) == 0);
    std::cout << "PASS: 32728 -> " << rate << " Hz at " << speed << "x, stereo 1000 Hz tone measured " << actual
              << " Hz; callback bounds and zero-frame request\n";
}

static void CheckBufferedPitch(double speed) {
    AudioCore::TimeStretcher stretcher;
    stretcher.SetOutputSampleRate(48000);
    auto queue = std::make_unique<AudioCore::MobileAudioBuffer>();
    std::array<s16, 2048> input{};
    std::array<s16, 2048> output{};
    std::array<float, 2048> converted{};
    std::array<float, 960> playback{};
    std::vector<float> measured;
    unsigned int underruns = 0;
    constexpr double frequency = 1000.0;
    unsigned int sample_index = 0;
    for (unsigned int tick = 0; tick < 2500; ++tick) {
        // A short map-loading stall after priming: the output reservoir should cover it.
        const bool stalled = tick >= 1200 && tick < 1208;
        const auto count = stalled ? 0u :
            static_cast<unsigned int>((tick + 1) * AudioCore::native_sample_rate * speed / 100) -
            static_cast<unsigned int>(tick * AudioCore::native_sample_rate * speed / 100);
        for (unsigned int i = 0; i < count; ++i, ++sample_index) {
            const auto sample = static_cast<s16>(12000 * std::sin(
                2 * std::numbers::pi * frequency * sample_index / AudioCore::native_sample_rate));
            input[i * 2] = sample;
            input[i * 2 + 1] = sample;
        }
        bool fed = false;
        for (int attempt = 0; attempt < 12; ++attempt) {
            const auto queued = queue->BufferedFrames();
            if (queued >= AudioCore::mobile_latency_frames) break;
            const auto requested = std::min<std::size_t>(1024, AudioCore::mobile_latency_frames - queued);
            const auto written = stretcher.ProcessBuffered(fed ? nullptr : input.data(), fed ? 0 : count,
                                                           output.data(), requested, queued, fed ? 0 : 0.01);
            fed = true;
            if (written == 0) break;
            for (std::size_t i = 0; i < written * 2; ++i)
                converted[i] = static_cast<float>(output[i]) / 32768.0f;
            assert(queue->Push({converted.data(), written * 2}) == written);
        }
        const auto read = queue->Read(playback);
        if (tick >= 500 && read != 480) ++underruns;
        for (std::size_t i = 0; i < read; ++i) {
            assert(playback[i * 2] == playback[i * 2 + 1]);
            if (tick >= 2200) measured.push_back(playback[i * 2]);
        }
    }
    assert(measured.size() > 48000 * 2.5);
    unsigned int crossings = 0;
    for (std::size_t i = 1; i < measured.size(); ++i)
        if (measured[i - 1] <= 0 && measured[i] > 0) ++crossings;
    const double actual = static_cast<double>(crossings) * 48000 / measured.size();
    assert(std::abs(actual - frequency) < 20);
    assert(underruns == 0);
    std::cout << "PASS: buffered " << speed << "x stereo tone " << actual
              << " Hz, zero post-start underruns including 80 ms source stall\n";
}

int main() {
    CheckPitch(AudioCore::native_sample_rate);
    CheckPitch(48000);
    CheckPitch(48000, 2.0);
    CheckPitch(48000, 0.75);
    CheckBufferedPitch(1.0);
    CheckBufferedPitch(2.0);
    CheckBufferedPitch(0.75);
}
