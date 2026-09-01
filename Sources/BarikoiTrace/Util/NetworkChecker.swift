import Foundation
import Network

/// Mirrors `NetworkChecker.kt`. Keeps one long-lived `NWPathMonitor` rather
/// than polling synchronously on each call.
///
/// Two corrections over the first version of this file, both visible only in
/// the first moments after launch — which is exactly when `initialize()` and
/// `setOrCreateUser()` run:
///   1. `_isAvailable` was seeded `true`, so a device with no connectivity
///      reported "online" until the monitor's first callback landed. It now
///      starts from the monitor's own `currentPath`, and callers can wait for
///      the first real update.
///   2. The flag was written on the monitor queue and read from arbitrary
///      threads with no synchronization — a data race. Both sides now go
///      through a lock.
public final class NetworkChecker {
    public static let shared = NetworkChecker()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.barikoi.trace.networkcheck")
    private let lock = NSLock()
    private var _isAvailable: Bool
    private var hasReceivedUpdate = false
    /// Left on the first path callback. A group rather than a semaphore
    /// because any number of callers may be waiting and all of them should be
    /// released — a semaphore's single `signal()` would free exactly one.
    private let firstUpdate = DispatchGroup()

    private init() {
        _isAvailable = monitor.currentPath.status == .satisfied
        firstUpdate.enter()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._isAvailable = path.status == .satisfied
            let isFirst = !self.hasReceivedUpdate
            self.hasReceivedUpdate = true
            self.lock.unlock()
            if isFirst { self.firstUpdate.leave() }
        }
        monitor.start(queue: queue)
    }

    public static func isNetworkAvailable() -> Bool {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared._isAvailable
    }

    /// Blocks up to `timeout` for the monitor's first real path update, then
    /// answers. For the handful of callers that run immediately after launch
    /// and would otherwise decide against a seed value —
    /// `TraceManager.setOrCreateUser` throwing a spurious `networkError()`, or
    /// worse, not throwing one when it should.
    public static func isNetworkAvailable(waitingUpTo timeout: TimeInterval) -> Bool {
        shared.lock.lock()
        let settled = shared.hasReceivedUpdate
        shared.lock.unlock()

        if !settled { _ = shared.firstUpdate.wait(timeout: .now() + timeout) }
        return isNetworkAvailable()
    }

    /// Convenience for `async` callers — same wait, without blocking a thread.
    public static func isNetworkAvailable(waitingUpTo timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: isNetworkAvailable(waitingUpTo: timeout))
            }
        }
    }
}
