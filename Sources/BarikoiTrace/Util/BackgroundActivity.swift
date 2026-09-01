import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Tracks whether the process is currently backgrounded, without touching
/// `UIApplication.shared.applicationState` (main-thread-only) from the
/// CoreLocation callback thread.
///
/// This exists because several decisions in this SDK are only correct when
/// they know the answer. Android never has to ask — its foreground service
/// runs the same way whether the UI is visible or not — so the Kotlin source
/// has no counterpart to this file.
enum AppState {
    private static let lock = NSLock()
    private static var _isBackground = false
    private static var isObserving = false

    static var isBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isBackground
    }

    /// Idempotent; called from the SDK's entry points.
    static func startObserving() {
        lock.lock()
        guard !isObserving else {
            lock.unlock()
            return
        }
        isObserving = true
        lock.unlock()

        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in set(true) }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in set(false) }

        // Seed from the real state — the SDK can be initialized while already
        // backgrounded (a significant-location-change relaunch does exactly
        // that, and it is the case where getting this wrong matters most).
        DispatchQueue.main.async {
            set(UIApplication.shared.applicationState == .background)
        }
        #endif
    }

    private static func set(_ value: Bool) {
        lock.lock()
        _isBackground = value
        lock.unlock()
    }
}

/// Ref-counted `beginBackgroundTask` assertion.
///
/// The single most important piece of the iOS background story, and the one
/// with no Android analogue. When iOS wakes the app for a location fix, it
/// grants a very short window and then suspends the process — mid-socket-write
/// if that is where it happens to be. An MQTT publish needs a TCP connect and
/// a CONNACK round trip first, which is routinely longer than the window the
/// wake alone provides, so fixes were queued to SQLite and the drain that was
/// supposed to follow never ran. The next wake repeated it, and the queue only
/// emptied when some window happened to last long enough.
///
/// Taking an assertion around connect → publish → drain asks the OS for the
/// extra seconds needed to finish, which is what makes the burst-per-wake
/// pattern actually deliver rather than accumulate.
final class BackgroundActivity {
    static let shared = BackgroundActivity()

    private let lock = NSLock()
    private var depth = 0
    #if canImport(UIKit)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {}

    /// Runs `body` with the assertion held. Nested/concurrent calls share one
    /// assertion; it is released when the last one finishes.
    func withAssertion<T>(name: String, _ body: () async -> T) async -> T {
        let epoch = begin(name: name)
        defer { end(epoch: epoch) }
        return await body()
    }

    /// Bumped by `expire()`. A holder from before an expiration must not
    /// release the assertion a *later* holder established — its `end()` would
    /// otherwise cut that one short.
    private var epoch: UInt64 = 0

    @discardableResult
    private func begin(name: String) -> UInt64 {
        #if canImport(UIKit)
        lock.lock()
        depth += 1
        let currentEpoch = epoch
        let needsAssertion = depth == 1 && identifier == .invalid
        lock.unlock()
        guard needsAssertion else { return currentEpoch }

        // `beginBackgroundTask` is documented as safe to call from any thread.
        // The expiration handler must release the assertion or iOS terminates
        // the app.
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.expire()
        }
        lock.lock()
        // A concurrent `end()` may already have taken the depth back to zero.
        if depth > 0, identifier == .invalid {
            identifier = id
            lock.unlock()
        } else {
            lock.unlock()
            UIApplication.shared.endBackgroundTask(id)
        }
        return currentEpoch
        #else
        return 0
        #endif
    }

    private func end(epoch: UInt64) {
        #if canImport(UIKit)
        lock.lock()
        guard epoch == self.epoch else {
            // Expired since this holder began: the bookkeeping was already
            // reset and a newer assertion may be in force. Nothing to release.
            lock.unlock()
            return
        }
        depth = max(0, depth - 1)
        let id = depth == 0 ? identifier : .invalid
        if depth == 0 { identifier = .invalid }
        lock.unlock()

        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        #endif
    }

    /// The OS is out of patience. Release the assertion immediately — the work
    /// itself is not cancelled here; whatever it had already published stands,
    /// and anything it did not is still in the offline queue for the next wake.
    private func expire() {
        #if canImport(UIKit)
        lock.lock()
        let id = identifier
        identifier = .invalid
        depth = 0
        epoch &+= 1
        lock.unlock()

        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        #endif
    }
}
