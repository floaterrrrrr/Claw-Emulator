// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Activation can block while the system negotiates an audio route. The caller
// supplies the same serial worker used for load/stop; UI completions stay on main.
@MainActor final class AudioActivation {
    private var pending: UUID?

    func request(on queue: DispatchQueue, activate: @escaping @Sendable () throws -> Void,
                 completion: @escaping @MainActor @Sendable (String?) -> Void) {
        guard pending == nil else { return }
        let request = UUID()
        pending = request
        // Create the weak capture here so the worker has no implicit strong
        // capture of this coordinator around a nested weak-capture closure.
        let deliver: @MainActor @Sendable (String?) -> Void = { [weak self] message in
            guard let self, self.pending == request else { return }
            self.pending = nil
            completion(message)
        }
        queue.async {
            let message: String?
            do {
                try activate()
                message = nil
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { deliver(message) }
        }
    }

    // A late activation must not resume a game after pause, interruption or stop.
    func cancel() { pending = nil }
}
