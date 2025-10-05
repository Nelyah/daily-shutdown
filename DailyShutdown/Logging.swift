import Foundation

/// Simple structured logger abstraction allowing alternate sinks (stdout, file, telemetry).
protocol Logger {
    func info(_ message: @autoclosure () -> String)
    func error(_ message: @autoclosure () -> String)
}

final class DefaultLogger: Logger {
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "logger.queue", qos: .utility)
    init() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        self.dateFormatter = df
    }
    /// Enqueue an asynchronous emission to stdout with timestamp & level.
    private func emit(level: String, _ message: String) {
        queue.async { [dateFormatter] in
            let ts = dateFormatter.string(from: Date())
            fputs("[\(ts)] [\(level)] \(message)\n", stdout)
            fflush(stdout)
        }
    }
    func info(_ message: @autoclosure () -> String) { emit(level: "INFO", message()) }
    func error(_ message: @autoclosure () -> String) { emit(level: "ERROR", message()) }
}

// Global shared logger (simple for this small app)
let logger: Logger = DefaultLogger()

// Convenience free function
func log(_ message: String) {
    logger.info(message)
}
