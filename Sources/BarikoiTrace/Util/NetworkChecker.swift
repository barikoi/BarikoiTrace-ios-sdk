import Network

/// Mirrors `NetworkChecker.kt`. Keeps one long-lived `NWPathMonitor` rather
/// than polling synchronously on each call.
public final class NetworkChecker {
    public static let shared = NetworkChecker()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.barikoi.trace.networkcheck")
    private var _isAvailable = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?._isAvailable = path.status == .satisfied
        }
        monitor.start(queue: queue)
    }

    public static func isNetworkAvailable() -> Bool { shared._isAvailable }
}
