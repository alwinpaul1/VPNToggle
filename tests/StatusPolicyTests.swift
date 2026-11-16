import Foundation

enum StatusPolicyTests {
    static let connectedStats = """
    Cisco Secure Client (version 5.1.21.2728) release.\r
    \r  >> state: Unknown
    \r  >> state: Connected
    \r  >> state: Connected
    \r  >> registered with local VPN subsystem.
    \rVPN> \r  >> notice: Connected to vpn-gate.b-tu.de.
    \rVPN>

    [ Connection Information ]

        Connection State:            Connected
        Tunnel Mode (IPv4):          Tunnel All Traffic
        Duration:                    00:09:29
        Session Disconnect:          None
        Management Connection State: Disconnected (user tunnel active)

    [ Address Information ]

        Client Address (IPv4):       141.43.0.10
        Client Address (IPv6):       Not Available
        Server Address:              141.43.0.1
    """

    static let disconnectedStats = """
      >> state: Unknown
      >> state: Disconnected
      >> notice: Ready to connect.

    [ Connection Information ]

        Connection State:            Disconnected
        Duration:                    00:00:00
        Management Connection State: Disconnected (user tunnel inactive)

    [ Address Information ]

        Client Address (IPv4):       Not Available
    """

    static func name(_ s: VPNState?) -> String? { s.map { "\($0)" } }

    static func run() {
        let check: (String, String?, String?) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        let flag: (String, Bool, Bool) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        let t0 = ConnectPolicyTests.t0

        let on = StatusPolicy.reading(fromStats: connectedStats)
        check("stats: connected state", name(on.state), "connected")
        check("stats: client address", on.ip, "141.43.0.10")
        check("stats: duration in seconds", on.seconds.map(String.init), "569")

        let off = StatusPolicy.reading(fromStats: disconnectedStats)
        check("stats: disconnected state", name(off.state), "disconnected")
        check("stats: no address when off", off.ip, nil)

        check("stats: management line does not decide the state",
              name(StatusPolicy.reading(fromStats: "    Management Connection State: Disconnected (user tunnel active)\n").state), nil)
        check("stats: banner used when the table is missing",
              name(StatusPolicy.reading(fromStats: "  >> state: Unknown\n  >> state: Connected\n").state), "connected")
        check("stats: other table state is busy",
              name(StatusPolicy.reading(fromStats: "    Connection State:            Reconnecting\n").state), "busy")
        check("stats: empty output gives no state", name(StatusPolicy.reading(fromStats: "").state), nil)
        check("stats: could-not-start text gives no state",
              name(StatusPolicy.reading(fromStats: "could not start /opt/cisco/secureclient/bin/vpn").state), nil)

        check("banner: last state line wins",
              name(StatusPolicy.state(fromBanner: "  >> state: Unknown\n  >> state: Disconnected\n")), "disconnected")
        check("banner: connecting is busy", name(StatusPolicy.state(fromBanner: "  >> state: Connecting\n")), "busy")
        check("banner: no state line", name(StatusPolicy.state(fromBanner: "VPN> \n")), nil)

        check("duration: plain", StatusPolicy.seconds(fromDuration: "00:12:05").map(String.init), "725")
        check("duration: with days", StatusPolicy.seconds(fromDuration: "1 day(s) 02:03:04").map(String.init), "93784")
        check("duration: malformed", StatusPolicy.seconds(fromDuration: "soon").map(String.init), nil)

        let tunnels: Set<String> = ["141.43.0.10"]
        flag("settled: connected with the tunnel address up",
             StatusPolicy.settled(state: .connected, tunnelIP: "141.43.0.10", tunnels: tunnels), true)
        flag("settled: connected but the address is gone",
             StatusPolicy.settled(state: .connected, tunnelIP: "141.43.0.10", tunnels: []), false)
        flag("settled: connected without a known address",
             StatusPolicy.settled(state: .connected, tunnelIP: nil, tunnels: tunnels), false)
        flag("settled: disconnected", StatusPolicy.settled(state: .disconnected, tunnelIP: nil, tunnels: []), true)
        flag("settled: busy", StatusPolicy.settled(state: .busy, tunnelIP: nil, tunnels: []), false)
        flag("settled: unknown", StatusPolicy.settled(state: .unknown, tunnelIP: nil, tunnels: []), false)

        flag("poll: slow when settled and watching",
             StatusPolicy.pollInterval(settled: true, watchingInterfaces: true) == 30, true)
        flag("poll: fast when unsettled",
             StatusPolicy.pollInterval(settled: false, watchingInterfaces: true) == 3, true)
        flag("poll: fast without interface events",
             StatusPolicy.pollInterval(settled: true, watchingInterfaces: false) == 3, true)

        flag("cli: two minutes while off and watching",
             StatusPolicy.cliInterval(state: .disconnected, watchingInterfaces: true) == 120, true)
        flag("cli: 15 s while off without events",
             StatusPolicy.cliInterval(state: .disconnected, watchingInterfaces: false) == 15, true)
        flag("cli: 5 s while the state is unclear",
             StatusPolicy.cliInterval(state: .busy, watchingInterfaces: true) == 5
                && StatusPolicy.cliInterval(state: .unknown, watchingInterfaces: true) == 5, true)

        let next = t0.addingTimeInterval(120)
        flag("cli not needed when nothing changed",
             StatusPolicy.needsCLI(force: false, tunnelsChanged: false, lostTunnel: false, now: t0, nextCheck: next), false)
        flag("cli needed when forced",
             StatusPolicy.needsCLI(force: true, tunnelsChanged: false, lostTunnel: false, now: t0, nextCheck: next), true)
        flag("cli needed when an address changed",
             StatusPolicy.needsCLI(force: false, tunnelsChanged: true, lostTunnel: false, now: t0, nextCheck: next), true)
        flag("cli needed when the tunnel address is gone",
             StatusPolicy.needsCLI(force: false, tunnelsChanged: false, lostTunnel: true, now: t0, nextCheck: next), true)
        flag("cli needed when the interval has passed",
             StatusPolicy.needsCLI(force: false, tunnelsChanged: false, lostTunnel: false, now: next, nextCheck: next), true)

        flag("hover: fast near the icon", StatusPolicy.hoverInterval(pointerDistance: 0) == 0.12, true)
        flag("hover: fast at the edge of near", StatusPolicy.hoverInterval(pointerDistance: 120) == 0.12, true)
        flag("hover: slow far away", StatusPolicy.hoverInterval(pointerDistance: 121) == 0.4, true)

        check("step: contacting", StatusPolicy.connectStep(forLine: "  >> contacting host (vpn-gate.b-tu.de) for login information..."),
              "Contacting the server")
        check("step: session", StatusPolicy.connectStep(forLine: "  >> notice: Establishing VPN session..."), "Starting the session")
        check("step: update checks",
              StatusPolicy.connectStep(forLine: "  >> notice: The Cisco Secure Client - Downloader is performing update checks..."),
              "Checking for Cisco updates")
        check("step: profile updates", StatusPolicy.connectStep(forLine: "  >> notice: Checking for profile updates..."),
              "Checking for Cisco updates")
        check("step: download with percent",
              StatusPolicy.connectStep(forLine: "  >> notice: Downloading Cisco Secure Client - Network Visibility 5.1.21.2728 - 72%"),
              "Updating Cisco Secure Client (72%)")
        check("step: download without percent",
              StatusPolicy.connectStep(forLine: "  >> notice: Downloading Cisco Secure Client - Network Visibility 5.1.21.2728"),
              "Updating Cisco Secure Client")
        check("step: initiating", StatusPolicy.connectStep(forLine: "  >> notice: Establishing VPN - Initiating connection..."),
              "Opening the tunnel")
        check("step: examining", StatusPolicy.connectStep(forLine: "  >> notice: Establishing VPN - Examining system..."),
              "Checking this computer")
        check("step: adapter", StatusPolicy.connectStep(forLine: "  >> notice: Establishing VPN - Activating VPN adapter..."),
              "Activating the VPN adapter")
        check("step: configuring", StatusPolicy.connectStep(forLine: "  >> notice: Establishing VPN - Configuring system..."),
              "Configuring the network")
        check("step: final establishing line keeps the last step",
              StatusPolicy.connectStep(forLine: "  >> notice: Establishing VPN..."), nil)
        check("step: state line is not a step", StatusPolicy.connectStep(forLine: "  >> state: Connecting"), nil)
        check("step: banner text is not a step",
              StatusPolicy.connectStep(forLine: "  >> Bitte geben Sie den zweiten Faktor ein (2FA Token)!"), nil)

        check("note: manual", StatusPolicy.reconnectNote(attempt: 2, of: 4, autoReconnect: false), "Reconnect when you are ready")
        check("note: before the first attempt", StatusPolicy.reconnectNote(attempt: 0, of: 4, autoReconnect: true),
              "Reconnecting automatically")
        check("note: attempt count", StatusPolicy.reconnectNote(attempt: 2, of: 4, autoReconnect: true),
              "Reconnecting automatically, attempt 2 of 4")
    }
}
