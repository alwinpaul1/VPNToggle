import Foundation

enum VPNState { case connected, disconnected, busy, unknown }

struct StatusReading: Equatable {
    var state: VPNState?
    var ip: String?
    var seconds: Int?
}

enum StatusPolicy {
    static let settledPoll: TimeInterval = 30
    static let unsettledPoll: TimeInterval = 3
    static let hoverNearPoll: TimeInterval = 0.12
    static let hoverFarPoll: TimeInterval = 0.4
    static let hoverNearDistance: Double = 120

    static func state(fromBanner output: String) -> VPNState? {
        guard let line = output.components(separatedBy: "\n").last(where: { $0.contains("state:") }) else { return nil }
        return state(named: line.components(separatedBy: "state:").last ?? "")
    }

    static func state(named text: String) -> VPNState {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("Disconnected") { return .disconnected }
        if name.hasPrefix("Connected") { return .connected }
        return .busy
    }

    static func reading(fromStats output: String) -> StatusReading {
        var r = StatusReading()
        for raw in output.components(separatedBy: "\n") {
            let parts = raw.replacingOccurrences(of: "\r", with: "")
                .split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1] != "Not Available" else { continue }
            switch parts[0] {
            case "Connection State": r.state = state(named: parts[1])
            case "Client Address (IPv4)": r.ip = parts[1]
            case "Duration": r.seconds = seconds(fromDuration: parts[1])
            default: break
            }
        }
        if r.state == nil { r.state = state(fromBanner: output) }
        return r
    }

    static func seconds(fromDuration text: String) -> Int? {
        let hms = text.split(separator: " ").last?.split(separator: ":").compactMap { Int($0) } ?? []
        guard hms.count == 3 else { return nil }
        let days = text.contains("day") ? Int(text.split(separator: " ").first ?? "") ?? 0 : 0
        return ((days * 24 + hms[0]) * 60 + hms[1]) * 60 + hms[2]
    }

    static func settled(state: VPNState, tunnelIP: String?, tunnels: Set<String>) -> Bool {
        switch state {
        case .disconnected: return true
        case .connected: return tunnelIP.map(tunnels.contains) ?? false
        case .busy, .unknown: return false
        }
    }

    static func pollInterval(settled: Bool, watchingInterfaces: Bool) -> TimeInterval {
        settled && watchingInterfaces ? settledPoll : unsettledPoll
    }

    static func cliInterval(state: VPNState, watchingInterfaces: Bool) -> TimeInterval {
        switch state {
        case .disconnected: return watchingInterfaces ? 120 : 15
        case .connected: return 15
        case .busy, .unknown: return 5
        }
    }

    static func needsCLI(force: Bool, tunnelsChanged: Bool, lostTunnel: Bool, now: Date, nextCheck: Date) -> Bool {
        force || tunnelsChanged || lostTunnel || now >= nextCheck
    }

    static func hoverInterval(pointerDistance: Double) -> TimeInterval {
        pointerDistance <= hoverNearDistance ? hoverNearPoll : hoverFarPoll
    }

    static func connectStep(forLine line: String) -> String? {
        let low = line.lowercased()
        if low.contains("downloading") {
            let percent = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last
                .flatMap { $0.hasSuffix("%") ? String($0) : nil }
            return percent.map { "Updating Cisco Secure Client (\($0))" } ?? "Updating Cisco Secure Client"
        }
        if low.contains("update checks") || low.contains("checking for") || low.contains("required updates") {
            return "Checking for Cisco updates"
        }
        if low.contains("initiating connection") { return "Opening the tunnel" }
        if low.contains("examining system") { return "Checking this computer" }
        if low.contains("activating vpn adapter") { return "Activating the VPN adapter" }
        if low.contains("configuring system") { return "Configuring the network" }
        if low.contains("establishing vpn session") { return "Starting the session" }
        if low.contains("contacting") { return "Contacting the server" }
        return nil
    }

    static func reconnectNote(attempt: Int, of total: Int, autoReconnect: Bool) -> String {
        guard autoReconnect else { return "Reconnect when you are ready" }
        guard attempt > 0 else { return "Reconnecting automatically" }
        return "Reconnecting automatically, attempt \(attempt) of \(total)"
    }
}
