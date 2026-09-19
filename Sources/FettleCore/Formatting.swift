import Foundation

public enum Formatting {
    /// `ByteCountFormatter` isn't `Sendable` and isn't thread-safe, so each call
    /// gets its own. It is cheap next to the file I/O around it.
    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, value))
    }

    public static func bytes(_ value: Int) -> String { bytes(Int64(value)) }

    /// "3 days", "2 months" — coarse on purpose; Fettle never needs minutes.
    public static func age(days: Int) -> String {
        switch days {
        case ..<1: return "today"
        case 1: return "1 day"
        case 2..<30: return "\(days) days"
        case 30..<365:
            let months = max(1, days / 30)
            return months == 1 ? "1 month" : "\(months) months"
        default:
            let years = max(1, days / 365)
            return years == 1 ? "1 year" : "\(years) years"
        }
    }

    public static func count(_ value: Int, singular: String, plural: String? = nil) -> String {
        let word = value == 1 ? singular : (plural ?? singular + "s")
        return "\(value) \(word)"
    }
}
