// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

private final class AudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var startedValue = false
    private var callsValue = 0
    let release = DispatchSemaphore(value: 0)
    func enter() {
        lock.lock()
        startedValue = true
        callsValue += 1
        lock.unlock()
    }
    var started: Bool {
        lock.lock(); defer { lock.unlock() }
        return startedValue
    }
    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return callsValue
    }
}

@MainActor private final class AudioUIProbe {
    var callbacks = 0
    var errors: [String?] = []
    func complete(_ error: String?) {
        dispatchPrecondition(condition: .onQueue(.main))
        callbacks += 1
        errors.append(error)
    }
}

private enum FixtureFailure: Error { case audioUnavailable, activationTimedOut }

@main struct AudioActivationTests {
    @MainActor private static func until(_ condition: () -> Bool) async {
        let limit = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < limit, "Timed out waiting for audio fixture")
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private static func flush(_ worker: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor private static func successAndDeduplication() async {
        let worker = DispatchQueue(label: "test.audio.success")
        let request = AudioActivation(), ui = AudioUIProbe(), probe = AudioProbe()
        request.request(on: worker, activate: {
            dispatchPrecondition(condition: .onQueue(worker))
            dispatchPrecondition(condition: .notOnQueue(.main))
            probe.enter()
            if probe.release.wait(timeout: .now() + 5) != .success {
                throw FixtureFailure.activationTimedOut
            }
        }, completion: { ui.complete($0) })
        request.request(on: worker, activate: { probe.enter() }, completion: { ui.complete($0) })
        await until { probe.started }
        // This main-actor task still runs while the simulated audio call blocks.
        let responsive = await Task { @MainActor in true }.value
        precondition(responsive && ui.callbacks == 0 && probe.calls == 1)
        probe.release.signal()
        await flush(worker)
        precondition(ui.callbacks == 1 && ui.errors[0] == nil && probe.calls == 1)
        print("PASS: activation off main, UI remains responsive, main callback, duplicate request coalesced")
    }

    @MainActor private static func cancelPendingResume() async {
        let worker = DispatchQueue(label: "test.audio.cancel")
        let request = AudioActivation(), ui = AudioUIProbe(), probe = AudioProbe()
        request.request(on: worker, activate: {
            probe.enter()
            if probe.release.wait(timeout: .now() + 5) != .success {
                throw FixtureFailure.activationTimedOut
            }
        }, completion: { ui.complete($0) })
        await until { probe.started }
        request.cancel() // pause, interruption, error or teardown
        probe.release.signal()
        await flush(worker)
        precondition(ui.callbacks == 0)
        print("PASS: pause/stop cancellation suppresses late resume callbacks")
    }

    @MainActor private static func replacementRequest() async {
        let worker = DispatchQueue(label: "test.audio.replace")
        let request = AudioActivation(), ui = AudioUIProbe(), old = AudioProbe()
        request.request(on: worker, activate: {
            old.enter()
            if old.release.wait(timeout: .now() + 5) != .success {
                throw FixtureFailure.activationTimedOut
            }
            throw FixtureFailure.audioUnavailable
        }, completion: { ui.complete($0) })
        await until { old.started }
        request.cancel()
        request.request(on: worker, activate: {}, completion: { ui.complete($0) })
        old.release.signal()
        await flush(worker)
        precondition(ui.callbacks == 1 && ui.errors[0] == nil)
        print("PASS: stale activation failure cannot overwrite a newer resume")
    }

    @MainActor private static func failureAndRetry() async {
        let worker = DispatchQueue(label: "test.audio.retry")
        let request = AudioActivation(), ui = AudioUIProbe()
        request.request(on: worker, activate: { throw FixtureFailure.audioUnavailable },
                        completion: { ui.complete($0) })
        await flush(worker)
        precondition(ui.callbacks == 1 && ui.errors[0] != nil)
        request.request(on: worker, activate: {}, completion: { ui.complete($0) })
        await flush(worker)
        precondition(ui.callbacks == 2 && ui.errors[1] == nil)
        print("PASS: activation errors reach main and permit a retry")
    }

    @MainActor private static func cancelBeforeCallbackAndRelease() async {
        let worker = DispatchQueue(label: "test.audio.release")
        let ui = AudioUIProbe()
        var request: AudioActivation? = AudioActivation()
        weak var released = request
        request?.request(on: worker, activate: {}, completion: { ui.complete($0) })
        request?.cancel()
        request = nil
        await flush(worker)
        precondition(released == nil && ui.callbacks == 0)
        print("PASS: canceled activation does not retain its UI owner or deliver a stale callback")
    }

    @MainActor private static func releaseWhileActivationIsBlocked() async {
        let worker = DispatchQueue(label: "test.audio.blocked-release")
        let ui = AudioUIProbe(), probe = AudioProbe()
        var request: AudioActivation? = AudioActivation()
        weak var released = request
        request?.request(on: worker, activate: {
            probe.enter()
            if probe.release.wait(timeout: .now() + 5) != .success {
                throw FixtureFailure.activationTimedOut
            }
        }, completion: { ui.complete($0) })
        await until { probe.started }
        request?.cancel()
        request = nil
        let wasReleasedWhileBlocked = released == nil
        probe.release.signal()
        await flush(worker)
        precondition(wasReleasedWhileBlocked, "Blocked activation retained its coordinator")
        precondition(ui.callbacks == 0)
        print("PASS: coordinator releases while activation is still blocked")
    }

    static func main() async {
        await successAndDeduplication()
        await cancelPendingResume()
        await replacementRequest()
        await failureAndRetry()
        await cancelBeforeCallbackAndRelease()
        await releaseWhileActivationIsBlocked()
        print("Scope: real Swift dispatch/cancellation tests with simulated activation; no AVAudioSession or iOS runtime execution")
    }
}
