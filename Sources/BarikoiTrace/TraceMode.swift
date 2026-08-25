import Foundation

/// Tracking configuration. Mirrors `TraceMode.kt` field-for-field, including the
/// same builder floors and preset values, so a given `TraceMode` behaves the same
/// on Android and iOS.
public struct TraceMode: Equatable, Sendable {

    public enum DesiredAccuracy: String, Equatable, Sendable {
        case high = "HIGH"
        case medium = "MEDIUM"
        case low = "LOW"

        public static func fromString(_ value: String?) -> DesiredAccuracy {
            guard let value, let parsed = DesiredAccuracy(rawValue: value) else { return .high }
            return parsed
        }
    }

    public enum TrackingMode: Int, Equatable, Sendable {
        case passive = 0
        case reactive = 1
        case active = 2
        case custom = 3
    }

    public let desiredAccuracy: DesiredAccuracy
    /// Seconds between location requests when interval-based (0 = distance-based instead).
    public let updateInterval: Int
    /// Meters of movement required before a new fix is requested (0 = interval-based instead).
    public let distanceFilter: Int
    public let stopDuration: Int
    /// Meters — fixes with worse horizontal accuracy than this are rejected.
    public let accuracyFilter: Int
    public let trackingMode: TrackingMode
    public let offline: Bool
    public let debug: Bool
    public let pingSyncInterval: Int
    /// Daily tracking window — mirrors the Kotlin SDK's `java.time.LocalTime` fields.
    /// Defaults to the full day (00:00:00–23:59:59).
    public let startTime: DateComponents
    public let endTime: DateComponents

    public init(
        desiredAccuracy: DesiredAccuracy = .high,
        updateInterval: Int = 0,
        distanceFilter: Int = 0,
        stopDuration: Int = 0,
        accuracyFilter: Int = 100,
        trackingMode: TrackingMode = .custom,
        offline: Bool = true,
        debug: Bool = false,
        pingSyncInterval: Int = 0,
        startTime: DateComponents = TraceMode.dayStart,
        endTime: DateComponents = TraceMode.dayEnd
    ) {
        self.desiredAccuracy = desiredAccuracy
        self.updateInterval = updateInterval
        self.distanceFilter = distanceFilter
        self.stopDuration = stopDuration
        self.accuracyFilter = accuracyFilter
        self.trackingMode = trackingMode
        self.offline = offline
        self.debug = debug
        self.pingSyncInterval = pingSyncInterval
        self.startTime = startTime
        self.endTime = endTime
    }

    public static let dayStart = DateComponents(hour: 0, minute: 0, second: 0)
    public static let dayEnd = DateComponents(hour: 23, minute: 59, second: 59)

    // MARK: - Presets (numerically identical to TraceMode.kt's ACTIVE/PASSIVE/REACTIVE)

    public static let active = TraceMode(
        desiredAccuracy: .high, updateInterval: 5, distanceFilter: 0, stopDuration: 0,
        accuracyFilter: 50, trackingMode: .active, offline: true, debug: false, pingSyncInterval: 0
    )

    public static let passive = TraceMode(
        desiredAccuracy: .medium, updateInterval: 0, distanceFilter: 100, stopDuration: 0,
        accuracyFilter: 300, trackingMode: .passive, offline: true, debug: false, pingSyncInterval: 120
    )

    public static let reactive = TraceMode(
        desiredAccuracy: .high, updateInterval: 0, distanceFilter: 100, stopDuration: 0,
        accuracyFilter: 100, trackingMode: .reactive, offline: true, debug: false, pingSyncInterval: 30
    )

    // MARK: - Builder

    public final class Builder {
        private var desiredAccuracy: DesiredAccuracy = .high
        private var updateInterval = 0
        private var distanceFilter = 0
        private var stopDuration = 0
        private var accuracyFilter = 100
        private var offline = true
        private var debug = false
        private var pingSyncInterval = 0
        private var startTime = TraceMode.dayStart
        private var endTime = TraceMode.dayEnd

        public init() {}

        /// Floors at 5s — matches TraceMode.kt's Builder.
        @discardableResult
        public func setUpdateInterval(_ seconds: Int) -> Builder {
            updateInterval = max(seconds, 5)
            return self
        }

        /// Floors at 10m — matches TraceMode.kt's Builder.
        @discardableResult
        public func setDistanceFilter(_ meters: Int) -> Builder {
            distanceFilter = max(meters, 10)
            return self
        }

        @discardableResult
        public func setStopDuration(_ seconds: Int) -> Builder {
            stopDuration = seconds
            return self
        }

        /// Floors at 20m — matches TraceMode.kt's Builder.
        @discardableResult
        public func setAccuracyFilter(_ meters: Int) -> Builder {
            accuracyFilter = max(meters, 20)
            return self
        }

        @discardableResult
        public func setDesiredAccuracy(_ accuracy: DesiredAccuracy) -> Builder {
            desiredAccuracy = accuracy
            return self
        }

        @discardableResult
        public func setOfflineSync(_ enabled: Bool) -> Builder {
            offline = enabled
            return self
        }

        @discardableResult
        public func setDebugModeOn() -> Builder {
            debug = true
            return self
        }

        @discardableResult
        public func setPingSyncInterval(_ seconds: Int) -> Builder {
            pingSyncInterval = seconds
            return self
        }

        @discardableResult
        public func setStartTime(_ time: DateComponents) -> Builder {
            startTime = time
            return self
        }

        @discardableResult
        public func setEndTime(_ time: DateComponents) -> Builder {
            endTime = time
            return self
        }

        public func build() -> TraceMode {
            TraceMode(
                desiredAccuracy: desiredAccuracy,
                updateInterval: updateInterval,
                distanceFilter: distanceFilter,
                stopDuration: stopDuration,
                accuracyFilter: accuracyFilter,
                trackingMode: .custom,
                offline: offline,
                debug: debug,
                pingSyncInterval: pingSyncInterval,
                startTime: startTime,
                endTime: endTime
            )
        }
    }
}
