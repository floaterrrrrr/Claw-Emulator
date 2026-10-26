// SPDX-License-Identifier: GPL-3.0-or-later
#include "SessionControls.hpp"
#include <exception>
#include "common/settings.h"
#include "core/core.h"
#include "core/savestate.h"
#include "core/hle/kernel/kernel.h"

namespace Claw {
void SessionControls::process(Core::System& system, bool paused) {
    const int multiplier = speedMultiplier.load();
    // Change wall-clock pacing; every guest CPU/DSP tick continues to execute.
    const double requested_limit = multiplier * 100.0;
    // A restored/reselected settings bank can replace the actual limit without
    // changing the menu selection. The cached selection alone is not evidence
    // that the core still has the requested pacing value.
    if (applied_speed_ != multiplier ||
        Settings::values.frame_limit.GetValue() != requested_limit) {
        Settings::values.frame_limit.SetValue(requested_limit);
        // Normal Apple conversion uses a fixed guest rate. Accelerated playback
        // tracks achieved speed on the separate audio producer.
        // Never alter DSP tick timing according to the renderer's wall clock.
        Settings::values.enable_realtime_audio.SetValue(false);
        // iOS chooses its supported low-latency mode once. Toggling speed
        // only changes guest-clock pacing, never stalls both screens to rebuild
        // the swapchain. Preserve audible 2x conversion; 4x deliberately mutes playback.
        Settings::values.use_vsync.SetValue(false);
        applied_speed_ = multiplier;
    }
    if (operation_) {
        if (operation_->current() == AsyncStateOperation::Phase::Ready) {
            if (system.Kernel().AreAsyncOperationsPending()) {
                if (paused || std::chrono::steady_clock::now() >= deadline_) {
                    operation_.reset(); processing_.reset();
                    states.complete(StateStatus::Failed, "Pending game operations prevented a safe snapshot. Resume and retry.");
                }
                return;
            }
            // The prepared worker waits for explicit ownership of the stopped
            // core. This handoff is required even when no cheats are installed.
            operation_->atBoundary();
        }
        if (operation_->current() != AsyncStateOperation::Phase::Done) return;
        const auto error = operation_->failure();
        const bool failed_restore = processing_->restore && !error.empty() && operation_->boundaryStarted();
        states.complete(error.empty() ? (processing_->restore ? StateStatus::Restored : StateStatus::Saved)
                                      : StateStatus::Failed, error);
        operation_.reset(); processing_.reset();
        // Deserialization can rebuild the core before detecting a bad archive.
        // Never resume a possibly partially restored system after that failure.
        if (failed_restore) throw std::runtime_error("The save state could not be safely restored: " + error);
        return;
    }
    if (!processing_) {
        processing_ = states.take();
        deadline_ = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    }
    if (!processing_) return;
    if (!system.IsPoweredOn()) {
        states.complete(StateStatus::Failed, "The game is no longer running.");
        processing_.reset(); return;
    }
    if (system.Kernel().AreAsyncOperationsPending()) {
        if (paused || std::chrono::steady_clock::now() >= deadline_) {
            states.complete(StateStatus::Failed, "Resume the game and try again after pending game operations finish.");
            processing_.reset();
        }
        return;
    }
    const auto request = *processing_;
    const auto path = system.StatePath(request.slot);
    const auto title = system.StateTitle();
    struct Payload { Core::StateSnapshot snapshot; std::string restored; };
    auto payload = std::make_shared<Payload>();
    operation_ = std::make_unique<AsyncStateOperation>(
        [payload, request, path, title] {
            if (request.restore) payload->restored = Core::ReadStateSnapshot(path, title);
        },
        [payload, request, &system] {
            if (request.restore) system.ApplyStateSnapshot(std::move(payload->restored));
            else payload->snapshot = system.CaptureStateSnapshot();
        },
        [payload, request, path] {
            if (!request.restore) Core::WriteStateSnapshot(std::move(payload->snapshot), path);
        }, wake);
}
} // namespace Claw
