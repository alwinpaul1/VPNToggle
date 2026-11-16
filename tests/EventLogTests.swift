import Foundation

enum EventLogTests {
    static func run() {
        let check: (String, String?, String?) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        let flag: (String, Bool, Bool) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        let path = NSTemporaryDirectory() + "vpntoggle-test-\(UUID().uuidString).log"

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone.current
        let noon = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12, minute: 5, second: 9))!
        check("log: line format", EventLog.line("app started", at: noon), "2026-11-16 12:05:09  app started\n")

        flag("log: first line creates the file", EventLog.append("first", to: path), true)
        flag("log: second line appends", EventLog.append("second", to: path), true)
        let two = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check("log: both lines kept in order",
              two.split(separator: "\n").map { String($0.dropFirst(21)) }.joined(separator: ","), "first,second")
        try? FileManager.default.removeItem(atPath: path)

        let writers = 8, each = 50
        DispatchQueue.concurrentPerform(iterations: writers) { w in
            for i in 0..<each { EventLog.append("writer \(w) line \(i)", to: path) }
        }
        let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
        check("log: no line lost when threads write a new file at once", String(lines.count), String(writers * each))
        check("log: every concurrent line is whole", String(Set(lines.map { String($0.dropFirst(21)) }).count), String(writers * each))
        flag("log: a path that cannot be opened reports failure", EventLog.append("x", to: "/nonexistent-dir/x.log"), false)
        try? FileManager.default.removeItem(atPath: path)
    }
}
