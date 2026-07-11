import Foundation

/// Formats version strings using the scheme `YYYY.MM.DD.HHHH`
/// where `HHHH` is the 24-hour hour (2 digits) concatenated with the minute (2 digits).
///
/// Example: 2026-07-09 14:23 UTC → `"2026.07.09.1423"`
enum VersionFormatter {
    /// Formats a `Date` into the version string `YYYY.MM.DD.HHHH`.
    /// - Parameter date: The date to format.
    /// - Parameter timeZone: The time zone to use (defaults to UTC).
    /// - Returns: The formatted version string.
    static func format(date: Date, timeZone: TimeZone = .utc) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        return String(format: "%04d.%02d.%02d.%02d%02d", year, month, day, hour, minute)
    }

    /// Convenience: formats the current date/time in UTC.
    static func formatNow(timeZone: TimeZone = .utc) -> String {
        format(date: Date(), timeZone: timeZone)
    }
}

extension TimeZone {
    /// UTC time zone.
    static var utc: TimeZone { TimeZone(identifier: "UTC")! }
}
