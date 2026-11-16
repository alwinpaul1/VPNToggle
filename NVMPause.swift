import Foundation

enum NVMPause {
    static let label = "local.vpn-toggle"
    static let plistPath = "/Library/LaunchDaemons/local.vpn-toggle.plist"
    static let title = "Pause Cisco Network Visibility"
    static let summary = "Saves about one CPU core; Network Visibility stops reporting"

    enum Status: Equatable { case off, active, notRunning }

    static func status(plistInstalled: Bool, daemonLoaded: Bool) -> Status {
        if daemonLoaded { return .active }
        return plistInstalled ? .notRunning : .off
    }

    static func note(_ status: Status) -> String {
        switch status {
        case .off: return summary
        case .active: return "Active. " + summary
        case .notRunning: return "Installed but not running. Turn it off and on again"
        }
    }

    static func installs(from status: Status) -> Bool {
        status == .off
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScript(directory: String, install: Bool) -> String {
        let command = "/bin/sh " + shellQuoted(directory + (install ? "/install.sh" : "/uninstall.sh"))
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func failure(exitCode: Int32, output: String) -> String? {
        if exitCode == 0 { return nil }
        if output.contains("-128") { return nil }
        let line = output.split(separator: "\n").last.map(String.init) ?? ""
        return line.isEmpty ? "The change did not complete." : line
    }

    static func currentStatus() -> Status {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "system/" + label]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var loaded = false
        if (try? p.run()) != nil {
            p.waitUntilExit()
            loaded = p.terminationStatus == 0
        }
        return status(plistInstalled: FileManager.default.fileExists(atPath: plistPath), daemonLoaded: loaded)
    }

    static func change(install: Bool, directory: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript(directory: directory, install: install)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return "Could not ask for administrator rights." }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return failure(exitCode: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
