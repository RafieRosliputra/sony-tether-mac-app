import Foundation

/// App log. Every line goes to the on-screen log and to
/// `~/Library/Logs/sonyTether/sonyTether.log`.
final class Logger {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    struct Line {
        let date: Date
        let level: Level
        let message: String

        var text: String { "\(Fmt.time.string(from: date)) [\(level.rawValue)] \(message)" }
        var fileText: String { "\(stamp) [\(level.rawValue)] \(message)" }

        private var stamp: String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return f.string(from: date)
        }
    }

    static let shared = Logger()

    /// Called on the main thread for every new line.
    var onLine: ((Line) -> Void)?

    private let queue = DispatchQueue(label: "com.johorstudio.sonytether.log", qos: .utility)
    private(set) var lines: [Line] = []
    private var recent: [String: Date] = [:]
    private var suppressed: [String: Int] = [:]

    let fileURL: URL
    private let maxBytes = 5 * 1024 * 1024

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/sonyTether", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("sonyTether.log")
        rotateIfNeeded()
    }

    func log(_ level: Level, _ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let line = Line(date: Date(), level: level, message: message)
            // Suppress identical retry noise (e.g. the 2 s "no camera" poll).
            let key = "\(level.rawValue)|\(message)"
            let now = Date()
            if let last = self.recent[key], now.timeIntervalSince(last) < 15 {
                self.suppressed[key, default: 0] += 1
                return
            }
            if let n = self.suppressed.removeValue(forKey: key), n > 0 {
                let extra = Line(date: now, level: .debug, message: "\(n) previous identical line(s) suppressed")
                self.appendToFile(extra.fileText)
                DispatchQueue.main.async {
                    self.lines.append(extra)
                    self.onLine?(extra)
                }
            }
            if self.recent.count > 200 { self.recent.removeAll() }
            self.recent[key] = now
            self.appendToFile(line.fileText)
            DispatchQueue.main.async {
                self.lines.append(line)
                if self.lines.count > 5000 { self.lines.removeFirst(2000) }
                self.onLine?(line)
            }
        }
    }

    func info(_ m: String) { log(.info, m) }
    func warn(_ m: String) { log(.warn, m) }
    func error(_ m: String) { log(.error, m) }
    func debug(_ m: String) { log(.debug, m) }

    private func appendToFile(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes else {
            return
        }
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent("sonyTether.log.1")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: fileURL, to: backup)
    }
}
