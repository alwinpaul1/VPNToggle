import Foundation

enum EventLog {
    static let lock = NSLock()

    static func line(_ text: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(f.string(from: date))  \(text)\n"
    }

    @discardableResult
    static func append(_ text: String, to path: String, at date: Date = Date()) -> Bool {
        let bytes = Array(line(text, at: date).utf8)
        lock.lock()
        defer { lock.unlock() }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return write(fd, bytes, bytes.count) == bytes.count
    }
}
