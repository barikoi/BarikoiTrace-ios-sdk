import Foundation

/// Mirrors `DateTimeUtils.kt` — same format (`yyyy-MM-dd HH:mm:ss`, UTC),
/// used consistently on every MQTT payload path (live publish, offline
/// insert, offline flush) so there's no live-vs-offline format drift like
/// the Kotlin SDK currently has (see the work plan's Phase 0).
public enum DateTimeUtils {
    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static func dateTimeLocal(from date: Date) -> String {
        utcFormatter.string(from: date)
    }

    public static func currentTimeLocal() -> String {
        utcFormatter.string(from: Date())
    }
}
