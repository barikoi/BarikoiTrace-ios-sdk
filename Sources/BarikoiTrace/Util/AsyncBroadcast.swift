import Foundation

/// Fan-out helper so `BarikoiTrace.locationUpdates` behaves like Kotlin's
/// `SharedFlow` (multiple independent collectors), which `AsyncStream` alone
/// doesn't give you — each call to `stream()` gets its own continuation.
final class AsyncBroadcast<T> {
    private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]
    private let lock = NSLock()

    func stream() -> AsyncStream<T> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    func yield(_ value: T) {
        lock.lock()
        let all = Array(continuations.values)
        lock.unlock()
        for continuation in all {
            continuation.yield(value)
        }
    }
}
