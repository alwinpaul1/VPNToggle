import Foundation

enum ConnectPolicy {
    static let idleLimit: TimeInterval = 90
    static let hardLimit: TimeInterval = 900
    static let updatingMessage = "Cisco Secure Client is updating itself. Connect again once the update finishes."

    static func timeoutReason(now: Date, started: Date, lastOutput: Date,
                              idleLimit: TimeInterval = idleLimit, hardLimit: TimeInterval = hardLimit) -> String? {
        if now.timeIntervalSince(started) >= hardLimit { return "Gave up after \(Int(hardLimit / 60)) minutes." }
        if now.timeIntervalSince(lastOutput) >= idleLimit { return "Cisco stopped responding for \(Int(idleLimit)) s." }
        return nil
    }

    static func serviceStopped(_ log: String) -> Bool {
        log.contains("VPN service was stopped")
    }

    static func failureMessage(log: String, host: String, timedOut: String?) -> String {
        let cliError = log.components(separatedBy: "\n").first { $0.contains(">> error:") }?
            .components(separatedBy: ">> error:").last?.trimmingCharacters(in: .whitespaces)
        if let cliError { return cliError }
        if serviceStopped(log) || log.contains("Performing any required updates") || log.contains("Downloading Cisco Secure Client") {
            return updatingMessage
        }
        return timedOut ?? "Could not connect to \(host)."
    }
}
