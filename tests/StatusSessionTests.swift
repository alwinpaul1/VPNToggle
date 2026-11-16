import Foundation

enum StatusSessionTests {
    static let banner = """
    Overall: ok
    LaunchDaemon(com.cisco.secureclient.vpn.service.agent.plist) status: enabled
    Cisco Secure Client (version 5.1.21.2728) release.

    Copyright (c) 2004 - 2026, Cisco Systems, Inc. All rights reserved.


    """

    static let connectedSession = banner + """
      >> state: Unknown
    VPN>   >> state: Connected
    VPN>   >> state: Connected
    VPN>   >> registered with local VPN subsystem.
    VPN>   >> notice: Connected to vpn.example.org.
    VPN>\u{20}

    [ Connection Information ]

        Connection State:            Connected
        Tunnel Mode (IPv4):          Tunnel All Traffic
        Duration:                    1 day 02:03:04
        Management Connection State: Disconnected (user tunnel active)

    [ Address Information ]

        Client Address (IPv4):       10.20.30.40
        Client Address (IPv6):       Not Available
        Server Address:              192.0.2.1

    [ Secured Routes (IPv6) ]

        Network    Subnet

    """

    static let prompt = "VPN> \n"

    static let disconnectedSession = banner + """
      >> state: Unknown
    VPN>   >> state: Disconnected
    VPN>   >> state: Disconnected
    VPN>   >> notice: Ready to connect.
    VPN>   >> registered with local VPN subsystem.
    """

    static let duration = ((24 + 2) * 60 + 3) * 60 + 4

    static func name(_ s: VPNState?) -> String? { s.map { "\($0)" } }
    static func name(_ s: StatusPolicy.SessionStep) -> String? { "\(s)" }

    static func temporary(_ text: String, executable: Bool = false) -> String {
        let path = NSTemporaryDirectory() + "vpntoggle-test-\(UUID().uuidString)"
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        return path
    }

    static func run() {
        let check: (String, String?, String?) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        let flag: (String, Bool, Bool) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        let noDuration = connectedSession.replacingOccurrences(of: "1 day 02:03:04", with: "Not Available")
        let complete = connectedSession + prompt
        let incomplete = noDuration + prompt

        check("session: no state before the agent registers",
              name(StatusPolicy.registeredState(inSession: banner + "  >> state: Unknown\nVPN>   >> state: Connected\n")), nil)
        check("session: connected once registered", name(StatusPolicy.registeredState(inSession: connectedSession)), "connected")
        check("session: disconnected once registered", name(StatusPolicy.registeredState(inSession: disconnectedSession)), "disconnected")
        check("session: a state still changing reads as busy",
              name(StatusPolicy.registeredState(inSession: "  >> state: Reconnecting\n  >> registered with local VPN subsystem.\n")), "busy")
        check("session: only Unknown before registering reads as busy",
              name(StatusPolicy.registeredState(inSession: "  >> state: Unknown\n  >> registered with local VPN subsystem.\n")), "busy")
        check("session: a state line after the marker does not count",
              name(StatusPolicy.registeredState(inSession: "  >> registered with local VPN subsystem.\n  >> state: Connected\n")), nil)
        check("session: empty output", name(StatusPolicy.registeredState(inSession: "")), nil)

        let full = StatusPolicy.reading(fromSession: complete)
        check("session stats: state", name(full.state), "connected")
        check("session stats: address", full.ip, "10.20.30.40")
        check("session stats: duration", full.seconds.map(String.init), String(duration))
        check("session stats: carriage returns are tolerated",
              StatusPolicy.reading(fromSession: complete.replacingOccurrences(of: "\n", with: "\r\n")).ip, "10.20.30.40")
        check("session stats: a later duration replaces Not Available",
              StatusPolicy.reading(fromSession: incomplete + complete).seconds.map(String.init), String(duration))
        let off = StatusPolicy.reading(fromSession: disconnectedSession)
        check("session: disconnected is reported without a stats block", name(off.state), "disconnected")
        check("session: disconnected has no address", off.ip, nil)
        let stale = StatusPolicy.reading(fromSession: disconnectedSession + "\n    Client Address (IPv4):       10.20.30.40\n    Duration: 00:00:07\n")
        flag("session: a non-connected state drops address and duration", stale == StatusReading(state: .disconnected, ip: nil, seconds: nil), true)

        check("session: replies counted", String(StatusPolicy.sessionReplies(in: incomplete + complete)), "2")
        check("session: a reply without the prompt after it is not counted", String(StatusPolicy.sessionReplies(in: connectedSession)), "0")

        check("step: wait before registering", name(StatusPolicy.sessionStep(output: banner, sent: 1)), "wait")
        check("step: disconnected is done without waiting for stats", name(StatusPolicy.sessionStep(output: disconnectedSession, sent: 1)), "done")
        check("step: busy is done without waiting for stats",
              name(StatusPolicy.sessionStep(output: "  >> state: Reconnecting\n  >> registered with local VPN subsystem.\n", sent: 1)), "done")
        check("step: connected, reply not finished", name(StatusPolicy.sessionStep(output: connectedSession, sent: 1)), "wait")
        check("step: connected with a duration", name(StatusPolicy.sessionStep(output: complete, sent: 1)), "done")
        check("step: connected without a duration asks again", name(StatusPolicy.sessionStep(output: incomplete, sent: 1)), "askAgain")
        check("step: second request pending", name(StatusPolicy.sessionStep(output: incomplete, sent: 2)), "wait")
        check("step: second reply carries the duration", name(StatusPolicy.sessionStep(output: incomplete + complete, sent: 2)), "done")
        check("step: one retry only", name(StatusPolicy.sessionStep(output: incomplete + incomplete, sent: 2)), "done")

        flag("usable: nothing read", StatusPolicy.sessionUsable(nil), false)
        flag("usable: no state", StatusPolicy.sessionUsable(StatusReading()), false)
        flag("usable: unknown state", StatusPolicy.sessionUsable(StatusReading(state: .unknown)), false)
        flag("usable: disconnected", StatusPolicy.sessionUsable(StatusReading(state: .disconnected)), true)
        flag("usable: busy", StatusPolicy.sessionUsable(StatusReading(state: .busy)), true)
        flag("usable: connected with address and duration", StatusPolicy.sessionUsable(full), true)
        flag("usable: connected without a duration falls back", StatusPolicy.sessionUsable(StatusPolicy.reading(fromSession: incomplete)), false)
        flag("usable: connected without an address falls back",
             StatusPolicy.sessionUsable(StatusReading(state: .connected, ip: nil, seconds: 5)), false)
        flag("fast path allowed at first", StatusPolicy.sessionAllowed(failures: 0), true)
        flag("fast path allowed after one failure", StatusPolicy.sessionAllowed(failures: 1), true)
        flag("fast path off after two failures in a row", StatusPolicy.sessionAllowed(failures: 2), false)

        let good = temporary(complete), partial = temporary(incomplete), offText = temporary(disconnectedSession + "\n")
        let once = temporary("#!/bin/sh\n[ \"$1\" = \"-s\" ] || exit 9\nread command\n[ \"$command\" = \"stats\" ] || exit 8\ncat '\(good)'\nread rest\nexit 0\n", executable: true)
        var early: VPNState?, startedProcess = false
        let ran = StatusSession.read(cli: once, timeout: 5, onStart: { _ in startedProcess = true }, onState: { s, _ in early = s })
        check("runner: sends stats over -s and parses the reply", ran?.reading.ip, "10.20.30.40")
        check("runner: one request when the reply is complete", ran.map { String($0.requests) }, "1")
        check("runner: reports the state once registered", name(early), "connected")
        flag("runner: hands the process to the caller", startedProcess, true)

        let twice = temporary("#!/bin/sh\nread first\ncat '\(partial)'\nread second\n[ \"$second\" = \"stats\" ] || exit 7\ncat '\(good)'\nread rest\nexit 0\n", executable: true)
        let retried = StatusSession.read(cli: twice, timeout: 5)
        check("runner: asks again when the duration is missing", retried.map { String($0.requests) }, "2")
        check("runner: keeps the duration from the second reply", retried?.reading.seconds.map(String.init), String(duration))

        let never = temporary("#!/bin/sh\nread first\ncat '\(partial)'\nread second\ncat '\(partial)'\nread third && exit 6\nexit 0\n", executable: true)
        let short = StatusSession.read(cli: never, timeout: 5)
        check("runner: stops after one retry", short.map { String($0.requests) }, "2")
        flag("runner: a reading without a duration is not usable", StatusPolicy.sessionUsable(short?.reading), false)

        let down = temporary("#!/bin/sh\ncat '\(offText)'\nread first\nread second && exit 5\nexit 0\n", executable: true)
        let began = Date()
        let offRun = StatusSession.read(cli: down, timeout: 5)
        check("runner: disconnected is reported", name(offRun?.reading.state), "disconnected")
        flag("runner: disconnected does not wait for the timeout", Date().timeIntervalSince(began) < 3, true)

        let hanging = temporary("#!/bin/sh\nexec sleep 30\n", executable: true)
        let started = Date()
        flag("runner: a CLI that hangs gives no reading", StatusSession.read(cli: hanging, timeout: 0.5) == nil, true)
        flag("runner: a CLI that hangs is stopped at the timeout", Date().timeIntervalSince(started) < 3, true)
        flag("runner: a missing CLI gives no reading", StatusSession.read(cli: "/nonexistent/vpn") == nil, true)
        let silent = temporary("#!/bin/sh\nexit 0\n", executable: true)
        flag("runner: no output is not usable", StatusPolicy.sessionUsable(StatusSession.read(cli: silent)?.reading), false)

        for path in [good, partial, offText, once, twice, never, down, hanging, silent] { try? FileManager.default.removeItem(atPath: path) }
    }
}
