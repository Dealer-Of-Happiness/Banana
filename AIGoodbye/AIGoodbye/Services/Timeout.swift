//
//  Timeout.swift
//  AIGoodbye
//
//  Waiting for something that might never finish.
//
//  Deliberately not a task group. `withTaskGroup` waits for every child
//  before it returns, and `cancelAll()` only raises a flag - so racing a
//  framework call against a sleep inside a group hangs the group whenever
//  that call ignores cancellation. Which is the one case a timeout exists
//  for.
//
//  Here the slow work runs unstructured and is simply abandoned when the
//  clock wins. It keeps running in the background until it finishes or is
//  collected, but it no longer holds the caller - and in this app the caller
//  is a Stop button with a live microphone behind it.
//

import Foundation

enum Timeout {

    /// Run `work`, giving up after `seconds`.
    static func run(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        let gate = OneShotGate()
        let job = Task.detached(priority: .userInitiated) {
            await work()
            gate.fire()
        }
        let timer = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gate.fire()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.arm(continuation)
        }
        job.cancel()
        timer.cancel()
    }

    /// Wait for `task`, but never longer than `seconds`.
    static func join(_ task: Task<Void, Never>?, seconds: Double) async {
        guard let task else { return }
        await run(seconds: seconds) { await task.value }
    }
}

/// Resumes a continuation exactly once, whichever racer arrives first.
private nonisolated final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasFired = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if hasFired {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func fire() {
        lock.lock()
        guard !hasFired else { lock.unlock(); return }
        hasFired = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}
