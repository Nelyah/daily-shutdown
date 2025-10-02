import Foundation

public protocol Logger {
    func info(_ message: @autoclosure () -> String)
    func error(_ message: @autoclosure () -> String)
}

public final class DefaultLogger: Logger {
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "logger.queue", qos: .utility)
    public init() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        self.dateFormatter = df
    }
    private func emit(level: String, _ message: String) {
        queue.async { [dateFormatter] in
            let ts = dateFormatter.string(from: Date())
            fputs("[\(ts)] [\(level)] \(message)\n", stdout)
            fflush(stdout)
        }
    }
    public func info(_ message: @autoclosure () -> String) { emit(level: "INFO", message()) }
    public func error(_ message: @autoclosure () -> String) { emit(level: "ERROR", message()) }
}

// Global shared logger (simple for this small app)
public let logger: Logger = DefaultLogger()

// Convenience free function
public func log(_ message: String) {
    logger.info(message)
}
