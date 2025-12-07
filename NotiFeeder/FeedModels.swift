import Foundation
import UIKit

public struct FeedSource: Codable, Hashable, Identifiable {
    public var id: String { url }
    public var title: String
    public var url: String
    
    public var faviconURL: URL? {
        guard let url = URL(string: self.url), let host = url.host else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }

        static func faviconURL(for feedURL: URL) -> URL? {
            guard let host = feedURL.host else { return nil }
            return URL(string: "https://\(host)/favicon.ico")
        }

    public var cachedFaviconURL: URL? {
        let fileName = "favicon_\(url.hashValue).ico"
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return caches?.appendingPathComponent(fileName)
    }

    public static func cachedFaviconURL(for feed: FeedSource) -> URL? {
        guard let cachedURL = feed.cachedFaviconURL else {
            return nil
        }
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        return nil
    }

    public static func downloadAndCacheFavicon(for feed: FeedSource) async -> UIImage? {
        guard let faviconURL = feed.faviconURL else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: faviconURL)
            guard let image = UIImage(data: data) else {
                return nil
            }
            if let cachedURL = feed.cachedFaviconURL {
                try? data.write(to: cachedURL)
            }
            return image
        } catch {
            return nil
        }
    }

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public struct FeedEntry: Identifiable, Hashable, Codable {
    public var id: String { link }
    public var title: String
    public var shortTitle: String
    public var link: String
    public var content: String
    public var imageURL: String?
    public var author: String?
    public var sourceTitle: String?
    public var feedURL: String?
    public var pubDateString: String?
    public var isRead: Bool = false

    public init(title: String,
                shortTitle: String? = nil,
                link: String,
                content: String,
                imageURL: String? = nil,
                author: String? = nil,
                sourceTitle: String? = nil,
                feedURL: String? = nil,
                pubDateString: String? = nil,
                isRead: Bool = false) {
        self.title = title
        self.shortTitle = shortTitle ?? title
        self.link = link
        self.content = content
        self.imageURL = imageURL
        self.author = author
        self.sourceTitle = sourceTitle
        self.feedURL = feedURL
        self.pubDateString = pubDateString
        self.isRead = isRead
    }

	// --- Neue Hilfs-Properties und Funktionen ---

	// Liefert eine URL, falls imageURL ein gültiger String ist
	public var imageURLAsURL: URL? {
		guard let str = imageURL, let url = URL(string: str) else { return nil }
		return url
	}

	// Lokaler Cache-Pfad für das Entry-Bild (basierend auf link.hashValue)
	public var cachedImageFileURL: URL? {
		let fileName = "feedentry_image_\(link.hashValue)"
		let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
		return caches?.appendingPathComponent(fileName)
	}

	// Prüft ob ein gecachtes Bild existiert und gibt den URL zurück
	public static func cachedImageFileURL(for entry: FeedEntry) -> URL? {
		guard let cachedURL = entry.cachedImageFileURL else { return nil }
		if FileManager.default.fileExists(atPath: cachedURL.path) {
			return cachedURL
		}
		return nil
	}

	// Lädt Bild asynchron und speichert es im Cache (falls möglich)
	// Rückgabe: UIImage? oder nil bei Fehler
	public static func downloadAndCacheImage(for entry: FeedEntry) async -> UIImage? {
		guard let imgURL = entry.imageURLAsURL else { return nil }
		do {
			let (data, _) = try await URLSession.shared.data(from: imgURL)
			guard let image = UIImage(data: data) else { return nil }
			if let cachedURL = entry.cachedImageFileURL {
				// Versuche zu schreiben, Fehler ignorieren
				try? data.write(to: cachedURL)
			}
			return image
		} catch {
			return nil
		}
	}

	// Versucht pubDateString in ein Date zu parsen (unterstützt mehrere Formate)
	public var parsedPubDate: Date? {
		guard let s = pubDateString, !s.isEmpty else { return nil }

		// versuche RFC1123 / RFC822 Formate
		let rfcFormatter = DateFormatter()
		rfcFormatter.locale = Locale(identifier: "en_US_POSIX")
		rfcFormatter.timeZone = TimeZone(secondsFromGMT: 0)

		let formats = [
			"EEE, dd MMM yyyy HH:mm:ss zzz",
			"EEE, dd MMM yyyy HH:mm:ss Z",
			"dd MMM yyyy HH:mm:ss zzz",
			"yyyy-MM-dd'T'HH:mm:ssZ", // ISO8601-like
			"yyyy-MM-dd'T'HH:mm:ss.SSSZ"
		]

		for f in formats {
			rfcFormatter.dateFormat = f
			if let d = rfcFormatter.date(from: s) {
				return d
			}
		}

		// Fallback: ISO8601DateFormatter
		if #available(iOS 10.0, *) {
			let iso = ISO8601DateFormatter()
			if let d = iso.date(from: s) {
				return d
			}
		}

		return nil
	}

	// Formatiertes Datum für Anzeige (z.B. in Listen)
	public var formattedPubDate: String? {
		guard let date = parsedPubDate else { return nil }
		let df = DateFormatter()
		df.locale = Locale.current
		df.dateStyle = .medium
		df.timeStyle = .short
		return df.string(from: date)
	}

	// Nutzbarer Anzeige-Titel (shortTitle fällt zurück auf title)
	public var displayTitle: String {
		let t = shortTitle.trimmingCharacters(in: .whitespacesAndNewlines)
		return t.isEmpty ? title : t
	}
}
