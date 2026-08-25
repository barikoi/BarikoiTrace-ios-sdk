import CoreLocation

/// Mirrors `LocationUpdateListener.kt` — kept as a protocol rather than a
/// closure so `TraceBackgroundCoordinator` can hold a weak reference to it.
public protocol LocationUpdateListener: AnyObject {
    func onLocationReceived(_ location: CLLocation)
    func onFailure(_ error: TraceError)
    func onProviderAvailabilityChanged(_ available: Bool)
}
