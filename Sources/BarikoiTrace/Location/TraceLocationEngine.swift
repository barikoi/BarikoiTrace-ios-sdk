import CoreLocation

/// Wraps `CLLocationManager`. Mirrors `LocationEngine.kt`'s shape (continuous
/// updates + one-shot fetch), configured per the work plan's true-background
/// requirements: `allowsBackgroundLocationUpdates`, no automatic pausing, and
/// significant-location-change monitoring as the low-power / relaunch-trigger
/// fallback (see `TraceBackgroundCoordinator`).
public final class TraceLocationEngine: NSObject {
    private let manager = CLLocationManager()
    private weak var listener: LocationUpdateListener?
    private var oneShotContinuation: CheckedContinuation<CLLocation, Error>?

    public override init() {
        super.init()
        manager.delegate = self
    }

    // MARK: - Continuous updates

    public func startLocationUpdates(traceMode: TraceMode, listener: LocationUpdateListener) {
        self.listener = listener

        guard SystemSettingsManager.checkPermissions() else {
            listener.onFailure(.locationPermissionError())
            return
        }

        manager.desiredAccuracy = TraceLocationEngine.accuracy(for: traceMode.desiredAccuracy)
        manager.distanceFilter = traceMode.distanceFilter > 0
            ? CLLocationDistance(traceMode.distanceFilter)
            : kCLDistanceFilterNone

        // Required for the app to keep receiving updates once backgrounded —
        // only takes effect with Always authorization + the "location"
        // Background Mode enabled in the host app's capabilities.
        manager.allowsBackgroundLocationUpdates = SystemSettingsManager.hasAlwaysAuthorization()
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation

        manager.startUpdatingLocation()
    }

    public func stopLocationUpdates() {
        manager.stopUpdatingLocation()
        listener = nil
    }

    // MARK: - Significant-location-change (fallback wake source + relaunch-after-kill trigger)

    public func startMonitoringSignificantLocationChanges() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        manager.startMonitoringSignificantLocationChanges()
    }

    public func stopMonitoringSignificantLocationChanges() {
        manager.stopMonitoringSignificantLocationChanges()
    }

    // MARK: - One-shot fetch (mirrors LocationEngine.kt's getCurrentLocation())

    public func getCurrentLocation() async throws -> CLLocation {
        guard SystemSettingsManager.checkPermissions() else {
            throw TraceError.locationPermissionError()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.oneShotContinuation = continuation
            self.manager.requestLocation()
        }
    }

    // MARK: - Authorization

    public func requestAuthorization(always: Bool) {
        if always {
            manager.requestAlwaysAuthorization()
        } else {
            manager.requestWhenInUseAuthorization()
        }
    }

    private static func accuracy(for desired: TraceMode.DesiredAccuracy) -> CLLocationAccuracy {
        switch desired {
        case .high: return kCLLocationAccuracyBest
        case .medium: return kCLLocationAccuracyHundredMeters
        case .low: return kCLLocationAccuracyKilometer
        }
    }
}

extension TraceLocationEngine: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        if let continuation = oneShotContinuation {
            oneShotContinuation = nil
            continuation.resume(returning: location)
            return
        }

        listener?.onLocationReceived(location)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let continuation = oneShotContinuation {
            oneShotContinuation = nil
            continuation.resume(throwing: TraceError.locationNotFoundError())
            return
        }
        listener?.onFailure(.locationNotFoundError())
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        listener?.onProviderAvailabilityChanged(SystemSettingsManager.checkLocationSettings())
    }
}
