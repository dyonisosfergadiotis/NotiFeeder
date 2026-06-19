import Foundation
import OSLog

// MARK: - DateFormatter Extension (Formatter Definitions)

nonisolated extension DateFormatter {
    private static let germanLocale = Locale(identifier: "de_DE")

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

    static let feedDateFallbacks: [DateFormatter] = {
        [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = true
            return formatter
        }
    }()

    static let localized: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = germanLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.locale = germanLocale
        return formatter
    }()

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.locale = germanLocale
        return formatter
    }()
}

// MARK: - ISO8601 helpers

nonisolated private extension ISO8601DateFormatter {
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

nonisolated struct DateParser {
    private static let parseCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 2048
        return cache
    }()

    private static let rfc822TwoDigitYearRegex: NSRegularExpression? = {
        let pattern = "^(Mon|Tue|Wed|Thu|Fri|Sat|Sun),\\s\\d{2}\\s(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\\s(\\d{2})(\\s\\d{2}:\\d{2}:\\d{2}\\s[A-Za-z+\\-0-9:]+)$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func normalizeRFC822TwoDigitYear(_ input: String) -> String {
        guard let regex = rfc822TwoDigitYearRegex else {
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

        let cacheKey = s as NSString
        if let cached = parseCache.object(forKey: cacheKey) {
            return cached as Date
        }

        let parsed: Date

        // 1) ISO8601 Varianten
        if let d = ISO8601DateFormatter.full.date(from: s) {
            parsed = d
            parseCache.setObject(parsed as NSDate, forKey: cacheKey)
            return parsed
        }
        if let d = ISO8601DateFormatter.internet.date(from: s) {
            parsed = d
            parseCache.setObject(parsed as NSDate, forKey: cacheKey)
            return parsed
        }
        if let d = ISO8601DateFormatter.dateTimeNoZ.date(from: s) {
            parsed = d
            parseCache.setObject(parsed as NSDate, forKey: cacheKey)
            return parsed
        }

        // Normalize RFC822 with two-digit year to four-digit (prefix "20") before parsing
        let normalizedRFC822 = normalizeRFC822TwoDigitYear(s)

        // 2) RFC822 (first try normalized yyyy)
        if let d = DateFormatter.rfc822YYYY.date(from: normalizedRFC822) {
            parsed = d
            parseCache.setObject(parsed as NSDate, forKey: cacheKey)
            return parsed
        }

        // 3) RFC822 with two-digit year as a safety net
        if let d = DateFormatter.rfc822YY.date(from: s) {
            parsed = d
            parseCache.setObject(parsed as NSDate, forKey: cacheKey)
            return parsed
        }

        // 4) Common relaxed feed variants (missing weekday/seconds or numeric timezone).
        for formatter in DateFormatter.feedDateFallbacks {
            if let d = formatter.date(from: s) {
                parsed = d
                parseCache.setObject(parsed as NSDate, forKey: cacheKey)
                return parsed
            }
        }

        // 5) Fallback
        AppLogger.parsing.warning("Date parsing failed for input: \(s, privacy: .public)")
        parsed = Date.distantPast
        parseCache.setObject(parsed as NSDate, forKey: cacheKey)
        return parsed
    }
}
