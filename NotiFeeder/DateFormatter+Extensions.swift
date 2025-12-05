import Foundation

// MARK: - DateFormatter Extension (Formatter Definitions)

extension DateFormatter {
    /// RFC 822 with four-digit year, e.g. "Tue, 25 Nov 2025 12:34:56 GMT"
    static let rfc822YYYY: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// RFC 822 with two-digit year, e.g. "Tue, 25 Nov 25 12:34:56 GMT"
    static let rfc822YY: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yy HH:mm:ss zzz"
        // Define 100-year window so that "25" is interpreted as 2025 (not 1925)
        if let pastDate = Calendar(identifier: .gregorian).date(byAdding: .year, value: -80, to: Date()) {
            formatter.twoDigitStartDate = pastDate
        }
        return formatter
    }()

    static let localized: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.locale = .current
        return formatter
    }()

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.locale = .current
        return formatter
    }()
}

// MARK: - ISO8601 helpers

private extension ISO8601DateFormatter {
    static let full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let internet: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let dateTimeNoZ: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return f
    }()
}

// MARK: - DateParser (Intelligente Parsing-Logik)

struct DateParser {
    private static func normalizeRFC822TwoDigitYear(_ input: String) -> String {
        // Match: Weekday, dd MMM yy HH:mm:ss ZZZ (captures the two-digit year as group 1)
        // We conservatively look for a space + two digits + space between month and time.
        // Example: "Tue, 25 Nov 25 12:34:56 GMT" -> "Tue, 25 Nov 2025 12:34:56 GMT"
        let pattern = "^(Mon|Tue|Wed|Thu|Fri|Sat|Sun),\\s\\d{2}\\s(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\\s(\\d{2})(\\s\\d{2}:\\d{2}:\\d{2}\\s[A-Za-z+\\-0-9:]+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return input
        }
        let range = NSRange(location: 0, length: (input as NSString).length)
        if let match = regex.firstMatch(in: input, options: [], range: range), match.numberOfRanges >= 5 {
            let yearRange = match.range(at: 3)
            if let swiftRange = Range(yearRange, in: input) {
                var output = input
                output.replaceSubrange(swiftRange, with: "20" + String(input[swiftRange]))
                return output
            }
        }
        return input
    }

    /// Parsed ein Datum aus verschiedenen, in Feeds üblichen Formaten.
    /// Unterstützt ISO8601 (mit/ohne Millisekunden, mit/ohne 'Z'), RFC822 mit yyyy und yy.
    static func parse(_ dateString: String?) -> Date {
        guard let s = dateString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return Date.distantPast
        }

        // 1) ISO8601 Varianten
        if let d = ISO8601DateFormatter.full.date(from: s) {
            return d
        }
        if let d = ISO8601DateFormatter.internet.date(from: s) {
            return d
        }
        if let d = ISO8601DateFormatter.dateTimeNoZ.date(from: s) {
            return d
        }

        // Normalize RFC822 with two-digit year to four-digit (prefix "20") before parsing
        let normalizedRFC822 = normalizeRFC822TwoDigitYear(s)

        // 2) RFC822 (first try normalized yyyy)
        if let d = DateFormatter.rfc822YYYY.date(from: normalizedRFC822) {
            return d
        }

        // 3) RFC822 with two-digit year as a safety net
        if let d = DateFormatter.rfc822YY.date(from: s) {
            return d
        }

        // 4) Fallback
        print("🔴 WARNUNG: Datumsparsen fehlgeschlagen für: \(s)")
        return Date.distantPast
    }
}
