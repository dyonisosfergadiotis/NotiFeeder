import Foundation
import OSLog

enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "de.dyonisos.NotiFeeder"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let parsing = Logger(subsystem: subsystem, category: "parsing")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
