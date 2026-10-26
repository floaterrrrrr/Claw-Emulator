// SPDX-License-Identifier: GPL-3.0-or-later
#include "audio_core/mobile_audio_buffer.h"
#include "audio_core/mobile_audio_volume.h"
#include "common/frame_pacer.h"
#include "audio_core/fast_forward_pcm.h"
#include "ClawCore.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

using namespace std::chrono_literals;

static void CheckQueue() {
    auto queue = std::make_unique<AudioCore::MobileAudioBuffer>();
    std::vector<float> input(AudioCore::mobile_latency_frames * 2, 0.5f);
    std::vector<float> output(8192 * 2 + 2, -77.0f);
    assert(queue->Push({input.data(), 1024 * 2}) == 1024);
    assert(queue->Read({output.data() + 1, 1024 * 2}) == 0); // waits for real priming
    assert(output.front() == -77.0f && output.back() == -77.0f);
    assert(queue->Push({input.data(), (AudioCore::mobile_latency_frames - 1024) * 2}) ==
           AudioCore::mobile_latency_frames - 1024);
    // A 96 ms producer stall fits within the 128 ms reservoir.
    assert(queue->Read({output.data() + 1, 4608 * 2}) == 4608);
    assert(output[1] > 0 && output[1] < 0.01f);
    assert(output[1 + 200 * 2] == 0.5f);
    assert(queue->BufferedFrames() == 1536);
    assert(queue->Read({output.data() + 1, 2048 * 2}) == 1536);
    assert(output[1 + 1536 * 2] < 0.5f); // fades instead of holding DC
    assert(output[1 + 1700 * 2] == 0.0f);
    assert(queue->Push(input) == AudioCore::mobile_latency_frames);
    assert(queue->Read({output.data() + 1, 1024 * 2}) == 1024); // re-prime
    queue->Mute();
    assert(queue->Read({output.data() + 1, 1024 * 2}) == 1024);
    assert(output[1] > 0 && output[1] < 0.01f);
    queue->ResetStopped();
    assert(queue->Read({output.data() + 1, 1024 * 2}) == 0);
    assert(queue->Push({}) == 0);
    std::vector<float> full(AudioCore::MobileAudioBuffer::capacity * 2, 0.25f);
    assert(queue->Push(full) == AudioCore::MobileAudioBuffer::capacity);
    assert(queue->Push(input) == 0); // never overwrites unread samples
    assert(queue->Read({output.data() + 1, 8192 * 2}) == 8192);
    assert(output.front() == -77.0f && output.back() == -77.0f);
}

template <typename Sample>
static void CheckConcurrentQueue() {
    auto queue = std::make_unique<AudioCore::MobileAudioBufferT<Sample>>();
    constexpr std::size_t frames = 262144;
    std::atomic_size_t produced{0};
    std::thread producer([&] {
        std::array<Sample, 256 * 2> input{};
        std::size_t index = 0;
        while (index < frames + AudioCore::mobile_latency_frames) {
            const auto count = std::min<std::size_t>(256, frames + AudioCore::mobile_latency_frames - index);
            for (std::size_t i = 0; i < count; ++i) {
                input[i * 2] = static_cast<Sample>((index + i) % 128);
                input[i * 2 + 1] = -input[i * 2];
            }
            const auto written = queue->Push({input.data(), count * 2});
            index += written;
            produced.store(index, std::memory_order_release);
            if (written == 0) std::this_thread::yield();
        }
    });
    std::array<Sample, 256 * 2> output{};
    std::size_t consumed = 0;
    while (consumed < frames) {
        if (produced.load(std::memory_order_acquire) - consumed < AudioCore::mobile_latency_frames) {
            std::this_thread::yield();
            continue;
        }
        const auto count = queue->Read(output);
        assert(count == 256);
        for (std::size_t i = 0; i < count; ++i) {
            assert(output[i * 2 + 1] == -output[i * 2]);
            if (consumed + i >= 96)
                assert(output[i * 2] == static_cast<Sample>((consumed + i) % 128));
        }
        consumed += count;
    }
    producer.join();
}

static void CheckPCM16Queue() {
    auto queue = std::make_unique<AudioCore::MobilePCM16Buffer>();
    std::vector<std::int16_t> input(AudioCore::mobile_latency_frames * 2);
    for (std::size_t i = 0; i < AudioCore::mobile_latency_frames; ++i) {
        input[i * 2] = 32767;
        input[i * 2 + 1] = -32768;
    }
    std::vector<std::int16_t> output(8192 * 2 + 2, 12345);
    assert(queue->Push(input) == AudioCore::mobile_latency_frames);
    assert(queue->Read({output.data() + 1, 4608 * 2}) == 4608);
    assert(output[1] > 0 && output[1] < 400);
    assert(output[1 + 200 * 2] == 32767 && output[2 + 200 * 2] == -32768);
    assert(queue->Read({output.data() + 1, 2048 * 2}) == 1536);
    assert(output[1 + 1600 * 2] < 32767 && output[1 + 1700 * 2] == 0);
    assert(output.front() == 12345 && output.back() == 12345);
    assert(queue->Push(input) == AudioCore::mobile_latency_frames);
    queue->Discard();
    assert(queue->BufferedFrames() == 0);
    assert(queue->Read({output.data() + 1, 1024 * 2}) == 0);
    assert(queue->Push(input) == AudioCore::mobile_latency_frames);
    assert(queue->Read({output.data() + 1, 1024 * 2}) == 1024);
    queue->ResetStopped();
    assert(queue->BufferedFrames() == 0);
}

static void CheckVolume() {
    assert(AudioCore::MobileVolumeGain(-1.f) == 0.f);
    assert(AudioCore::MobileVolumeGain(2.f) == 1.f);
    assert(AudioCore::MobileVolumeGain(NAN) == 0.f);
    assert(AudioCore::MobileVolumeGain(INFINITY) == 0.f);
    AudioCore::MobileAudioVolume volume;
    std::array<std::int16_t, 480 * 2 + 2> samples{};
    const auto fill = [&] {
        samples.front() = samples.back() = 12345;
        for (unsigned i = 1; i < samples.size() - 1; i += 2) {
            samples[i] = 24000; samples[i + 1] = -24000;
        }
    };
    fill();
    volume.Apply({samples.data() + 1, 480 * 2}, 1.f);
    assert(samples[1] == 24000 && samples[960] == -24000);
    fill();
    volume.Apply({samples.data() + 1, 480 * 2}, 0.f);
    for (unsigned frame = 0; frame < 480; ++frame) {
        const auto left = samples[1 + frame * 2];
        assert(samples[2 + frame * 2] == -left);
        if (frame > 0) assert(left <= samples[1 + (frame - 1) * 2]);
        if (frame >= 240) assert(left == 0);
    }
    assert(samples[1] > 23000); // no discontinuous step when muting
    fill();
    volume.Apply({samples.data() + 1, 480 * 2}, AudioCore::MobileVolumeGain(.5f));
    assert(samples[1] >= 0 && samples[1] < 100);
    assert(samples[1 + 240 * 2] == 3000);
    assert(samples.front() == 12345 && samples.back() == 12345);
    volume.ResetStopped(0.f);
    fill();
    volume.Apply({samples.data() + 1, 1}, 0.f);
    assert(samples[1] == 24000); // incomplete stereo frame never touches storage
}

static void CheckPacing() {
    Common::FramePacer pacer;
    const auto origin = Common::FramePacer::Clock::time_point{};
    assert(pacer.Deadline(0us, origin, 100) == origin);
    auto deadline = origin;
    for (int i = 1; i <= 1000; ++i) {
        deadline = pacer.Deadline(i * 16667us, deadline + 4ms, 100);
        assert(deadline == origin + i * 16667us); // no accumulated relative-sleep drift
    }
    const auto delayed = deadline + 100ms;
    assert(pacer.Deadline(1001 * 16667us, delayed, 100) == delayed);
    assert(pacer.Deadline(1002 * 16667us, delayed + 1ms, 100) == delayed + 16667us);
    const auto pause_end = delayed + 1s;
    assert(pacer.Deadline(1003 * 16667us, pause_end, 100) == pause_end);
    assert(pacer.Deadline(1004 * 16667us, pause_end, 200) == pause_end);
    const auto accelerated = pacer.Deadline(1005 * 16667us, pause_end + 1ms, 200);
    assert(accelerated == pause_end + 8333500ns);
    assert(pacer.Deadline(0us, pause_end + 2ms, 200) == pause_end + 2ms);
    assert(pacer.Deadline(16667us, pause_end + 3ms, 0) == pause_end + 3ms);
}

static void CheckThirtyHzGuestPacing() {
    // A 30fps game still advances at 100% speed. Presentation mode does not
    // impose another 30Hz wall-clock ceiling when the guest runs at 2x/4x.
    for (const auto speed : {100u, 200u, 400u}) {
        Common::FramePacer pacer;
        const auto start = Common::FramePacer::Clock::time_point{};
        auto deadline = pacer.Deadline(0us, start, speed);
        deadline = pacer.Deadline(33333us, start, speed);
        const auto interval = std::chrono::duration<double>(deadline - start).count();
        assert(std::abs(interval - 0.033333 * 100 / speed) < 0.000001);
    }
    // Both explicit fast-forward targets survive guest temporary limits.
    // Normal playback keeps the prior effective-limit behavior.
    assert(Common::MobileFrameLimit(100, 30) == 30);
    assert(Common::MobileFrameLimit(100, 100) == 100);
    assert(Common::MobileFrameLimit(100, 0) == 0);
    assert(Common::MobileFrameLimit(200, 200) == 200);
    assert(Common::MobileFrameLimit(200, 100) == 200);
    assert(Common::MobileFrameLimit(200, 0) == 200);
    for (const auto temporary : {0.0, 30.0, 100.0, 200.0, 1000.0}) {
        Common::FramePacer pacer;
        const auto start = Common::FramePacer::Clock::time_point{};
        const auto target = Common::MobileFrameLimit(400, temporary);
        assert(target == 400);
        assert(pacer.Deadline(0us, start, target) == start);
        assert(pacer.Deadline(33332us, start, target) == start + 8333us);
        // Returning to 1x rebases immediately, then restores normal cadence.
        const auto resume = start + 1s;
        assert(pacer.Deadline(66664us, resume, 100) == resume);
        assert(pacer.Deadline(99996us, resume, 100) == resume + 33332us);
    }
}

static void CheckAcceleratedAudioContinuity() {
    // Same PCM stream and pitch independent of producer block boundaries.
    const auto render = [](std::size_t block, double achieved) {
        AudioCore::FastForwardPCM converter;
        std::size_t source = 0;
        const auto input = [&](std::int16_t* output, std::size_t count) {
            for (std::size_t i = 0; i < count; ++i, ++source) {
                output[i * 2] = static_cast<std::int16_t>(source % 15000);
                output[i * 2 + 1] = -output[i * 2];
            }
            return count;
        };
        std::vector<std::int16_t> output(12000);
        std::size_t written = 0;
        while (written < output.size() / 2) {
            const auto n = std::min(block, output.size() / 2 - written);
            const auto made = converter.Convert(std::span(output).subspan(written * 2, n * 2), input,
                                                achieved, 48000, 48000);
            assert(made == n); written += made;
        }
        return output;
    };
    const auto twice = render(1024, 2);
    assert(twice == render(17, 2));
    const auto normal_achieved = render(1024, 1);
    for (unsigned i = 0; i < 6000; ++i) {
        assert(twice[i * 2] == static_cast<int>(i * 2) && twice[i * 2 + 1] == -static_cast<int>(i * 2));
        // A 2x selection on a 1x-limited core consumes at the achieved rate.
        assert(normal_achieved[i * 2] == static_cast<int>(i));
    }
    AudioCore::FastForwardPCM starved;
    unsigned available = 1;
    auto input = [&](std::int16_t* frame, std::size_t) -> std::size_t {
        if (!available) return 0;
        frame[0] = frame[1] = 1000; --available; return 1;
    };
    std::array<std::int16_t, 16> output{};
    assert(starved.Convert(output, input, 2) == 0); // incomplete pair is retained
    available = 1;
    assert(starved.Convert(output, input, 2) > 0);
    starved.Reset();
    assert(starved.Convert(output, input, 2) == 0); // no stale samples after a mode switch
    available = 100;
    assert(starved.Convert(output, input, 1.25) == output.size() / 2);
    for (auto sample : output) assert(sample == 1000);
    AudioCore::FastForwardPCM changing;
    std::int16_t source_position = 0, last_sample = -1;
    const auto ramp = [&](std::int16_t* pcm, std::size_t count) {
        for (std::size_t i = 0; i < count; ++i) {
            pcm[i * 2] = pcm[i * 2 + 1] = source_position++;
        }
        return count;
    };
    for (unsigned block = 0; block < 128; ++block) {
        const double measured = block < 32 || block >= 96 ? 2 : 1;
        assert(changing.Convert(output, ramp, measured, 48000, 48000) == output.size() / 2);
        for (std::size_t frame = 0; frame < output.size() / 2; ++frame) {
            const auto sample = output[frame * 2];
            assert(sample >= last_sample && sample - last_sample <= 2);
            assert(sample == output[frame * 2 + 1]);
            last_sample = sample;
        }
    }
}

int main() {
    CheckQueue();
    CheckConcurrentQueue<float>();
    CheckConcurrentQueue<std::int16_t>();
    CheckPCM16Queue();
    CheckPacing();
    CheckVolume();
    CheckThirtyHzGuestPacing();
    CheckAcceleratedAudioContinuity();
    for (int scale = 1; scale <= 4; ++scale) {
        assert(Claw3DSResolutionScale(scale) == scale);
        assert(Claw3DSPresentationScale(scale) == scale);
        const auto touch = Claw3DSMapTouch(100, 75, 100, 75,
                                       320 * Claw3DSPresentationScale(scale),
                                       240 * Claw3DSPresentationScale(scale));
        assert(touch.x == 320 * Claw3DSPresentationScale(scale) - 1);
        assert(touch.y == 240 * Claw3DSPresentationScale(scale) - 1);
    }
    assert(Claw3DSResolutionScale(-1) == 1 && Claw3DSResolutionScale(8) == 4);
    std::cout << "PASS: 128 ms audio priming, 96 ms stall headroom, bounded fades, re-prime, "
                 "262144 concurrent stereo frames, absolute pacing/fast-forward/pause, 1x-4x touch mapping, stereo volume/mute ramps\n";
}
