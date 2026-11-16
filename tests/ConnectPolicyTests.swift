import Foundation

@main
struct ConnectPolicyTests {
    static var failures = 0
    static var passed = 0

    static func check(_ name: String, _ actual: String?, _ expected: String?) {
        if actual == expected { passed += 1; return }
        failures += 1
        print("FAIL \(name): expected \(expected ?? "nil"), got \(actual ?? "nil")")
    }

    static func check(_ name: String, _ actual: Bool, _ expected: Bool) {
        check(name, String(actual), String(expected))
    }

    static let t0 = Date(timeIntervalSince1970: 1_794_824_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static let upgradeLog = """
      >> state: Connecting
      >> notice: Establishing VPN session...
      >> notice: The Cisco Secure Client - Downloader is performing update checks...
      >> notice: Downloading Cisco Secure Client - Network Visibility 5.1.21.2728 - 72%
    """

    static func main() {
        check("fresh connect keeps waiting",
              ConnectPolicy.timeoutReason(now: at(0), started: t0, lastOutput: t0), nil)
        check("quiet for 89 s keeps waiting",
              ConnectPolicy.timeoutReason(now: at(89), started: t0, lastOutput: t0), nil)
        check("quiet for 90 s stops",
              ConnectPolicy.timeoutReason(now: at(90), started: t0, lastOutput: t0),
              "Cisco stopped responding for 90 s.")
        check("download still printing progress at 180 s keeps waiting",
              ConnectPolicy.timeoutReason(now: at(180), started: t0, lastOutput: at(179)), nil)
        check("download still printing progress at 600 s keeps waiting",
              ConnectPolicy.timeoutReason(now: at(600), started: t0, lastOutput: at(599)), nil)
        check("hard limit stops even while output continues",
              ConnectPolicy.timeoutReason(now: at(900), started: t0, lastOutput: at(899)),
              "Gave up after 15 minutes.")
        check("hard limit wins over idle",
              ConnectPolicy.timeoutReason(now: at(1000), started: t0, lastOutput: at(0)),
              "Gave up after 15 minutes.")
        check("custom limits apply",
              ConnectPolicy.timeoutReason(now: at(5), started: t0, lastOutput: t0, idleLimit: 5, hardLimit: 60),
              "Cisco stopped responding for 5 s.")

        check("service stopped detected",
              ConnectPolicy.serviceStopped("  >> notice: The VPN service was stopped\n"), true)
        check("normal log is not service stopped",
              ConnectPolicy.serviceStopped(upgradeLog), false)

        check("CLI error line wins",
              ConnectPolicy.failureMessage(log: upgradeLog + "  >> error: The requested authentication type is not supported\n",
                                           host: "vpn-gate.b-tu.de", timedOut: "Cisco stopped responding for 90 s."),
              "The requested authentication type is not supported")
        check("service stopped reports update",
              ConnectPolicy.failureMessage(log: "  >> notice: The VPN service was stopped\n", host: "h", timedOut: nil),
              ConnectPolicy.updatingMessage)
        check("download in progress reports update",
              ConnectPolicy.failureMessage(log: upgradeLog, host: "h", timedOut: "Gave up after 15 minutes."),
              ConnectPolicy.updatingMessage)
        check("install step reports update",
              ConnectPolicy.failureMessage(log: "  >> notice: Performing any required updates...\n", host: "h", timedOut: nil),
              ConnectPolicy.updatingMessage)
        check("timeout reason used when nothing else explains it",
              ConnectPolicy.failureMessage(log: "  >> state: Connecting\n", host: "h", timedOut: "Cisco stopped responding for 90 s."),
              "Cisco stopped responding for 90 s.")
        check("generic message when the CLI just exits",
              ConnectPolicy.failureMessage(log: "  >> state: Disconnected\n", host: "vpn-gate.b-tu.de", timedOut: nil),
              "Could not connect to vpn-gate.b-tu.de.")

        print("\(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
