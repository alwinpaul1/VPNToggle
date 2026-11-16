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

        updateChecks()
        StatusPolicyTests.run()

        print("\(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    static func updateChecks() {
        check("minor ten beats minor nine", UpdatePolicy.isNewer("v1.10", than: "1.9"), true)
        check("minor nine does not beat minor ten", UpdatePolicy.isNewer("v1.9", than: "1.10"), false)
        check("next minor is newer", UpdatePolicy.isNewer("v1.6", than: "1.5"), true)
        check("same version is not newer", UpdatePolicy.isNewer("v1.5", than: "1.5"), false)
        check("trailing zero is the same version", UpdatePolicy.isNewer("v1.5.0", than: "1.5"), false)
        check("trailing zero on the running side is the same version", UpdatePolicy.isNewer("1.5", than: "v1.5.0"), false)
        check("patch release is newer", UpdatePolicy.isNewer("v1.5.1", than: "1.5"), true)
        check("older release is not newer", UpdatePolicy.isNewer("v1.4", than: "1.5"), false)
        check("major beats minor", UpdatePolicy.isNewer("v2.0", than: "1.99.99"), true)
        check("prefix on both sides", UpdatePolicy.isNewer("v1.6", than: "v1.5"), true)
        check("capital prefix", UpdatePolicy.isNewer("V1.6", than: "1.5"), true)
        check("no prefix at all", UpdatePolicy.isNewer("1.6", than: "1.5"), true)
        check("surrounding whitespace ignored", UpdatePolicy.isNewer(" v1.6\n", than: "1.5"), true)
        check("leading zeros compare as numbers", UpdatePolicy.isNewer("v1.06", than: "1.5"), true)
        check("empty tag is not newer", UpdatePolicy.isNewer("", than: "1.5"), false)
        check("prefix alone is not newer", UpdatePolicy.isNewer("v", than: "1.5"), false)
        check("word tag is not newer", UpdatePolicy.isNewer("latest", than: "1.5"), false)
        check("suffix tag is not newer", UpdatePolicy.isNewer("v1.6-beta", than: "1.5"), false)
        check("empty segment is not newer", UpdatePolicy.isNewer("v1..6", than: "1.5"), false)
        check("trailing dot is not newer", UpdatePolicy.isNewer("v1.6.", than: "1.5"), false)
        check("signed segment is not newer", UpdatePolicy.isNewer("v1.+6", than: "1.5"), false)
        check("double prefix is not newer", UpdatePolicy.isNewer("vv1.6", than: "1.5"), false)
        check("oversized segment is not newer", UpdatePolicy.isNewer("v99999999999999999999.0", than: "1.5"), false)
        check("unknown running version is never outdated", UpdatePolicy.isNewer("v1.6", than: ""), false)

        check("display strips the prefix", UpdatePolicy.displayVersion("v1.6"), "1.6")
        check("display keeps a malformed tag", UpdatePolicy.displayVersion("nightly"), "nightly")

        check("first check runs", UpdatePolicy.shouldCheck(now: at(0), lastCheck: nil), true)
        check("an hour later waits", UpdatePolicy.shouldCheck(now: at(3600), lastCheck: t0), false)
        check("just under a day waits", UpdatePolicy.shouldCheck(now: at(86_399), lastCheck: t0), false)
        check("a day later runs", UpdatePolicy.shouldCheck(now: at(86_400), lastCheck: t0), true)
        check("clock set back runs", UpdatePolicy.shouldCheck(now: at(-10), lastCheck: t0), true)

        check("banner for a newer release", UpdatePolicy.showsBanner(latest: "v1.6", current: "1.5", dismissed: nil), true)
        check("no banner when current", UpdatePolicy.showsBanner(latest: "v1.5", current: "1.5", dismissed: nil), false)
        check("no banner before any check", UpdatePolicy.showsBanner(latest: nil, current: "1.5", dismissed: nil), false)
        check("no banner for the dismissed release", UpdatePolicy.showsBanner(latest: "v1.6", current: "1.5", dismissed: "v1.6"), false)
        check("dismissal matches across spellings", UpdatePolicy.showsBanner(latest: "v1.6.0", current: "1.5", dismissed: "1.6"), false)
        check("banner returns for a later release", UpdatePolicy.showsBanner(latest: "v1.7", current: "1.5", dismissed: "v1.6"), true)
        check("no banner for a malformed tag", UpdatePolicy.showsBanner(latest: "nightly", current: "1.5", dismissed: nil), false)

        check("release page kept",
              UpdatePolicy.page("https://github.com/alwinpaul1/VPNToggle/releases/tag/v1.6"),
              "https://github.com/alwinpaul1/VPNToggle/releases/tag/v1.6")
        check("foreign page replaced", UpdatePolicy.page("https://example.com/VPNToggle/releases/tag/v1.6"), UpdatePolicy.releasesPage)
        check("lookalike host replaced",
              UpdatePolicy.page("https://github.com.example.com/alwinpaul1/VPNToggle/releases/tag/v1.6"), UpdatePolicy.releasesPage)
        check("other scheme replaced", UpdatePolicy.page("file:///Applications/Calculator.app"), UpdatePolicy.releasesPage)
        check("missing page replaced", UpdatePolicy.page(nil), UpdatePolicy.releasesPage)

        let parsed = UpdatePolicy.release(fromJSON: json(
            #"{"tag_name":"v1.6","html_url":"https://github.com/alwinpaul1/VPNToggle/releases/tag/v1.6","draft":false,"prerelease":false}"#))
        check("release tag parsed", parsed?.tag, "v1.6")
        check("release page parsed", parsed?.page, "https://github.com/alwinpaul1/VPNToggle/releases/tag/v1.6")
        check("release without page falls back", UpdatePolicy.release(fromJSON: json(#"{"tag_name":"v1.6"}"#))?.page, UpdatePolicy.releasesPage)
        check("prerelease ignored", UpdatePolicy.release(fromJSON: json(#"{"tag_name":"v1.6","prerelease":true}"#)) == nil, true)
        check("draft ignored", UpdatePolicy.release(fromJSON: json(#"{"tag_name":"v1.6","draft":true}"#)) == nil, true)
        check("malformed tag ignored", UpdatePolicy.release(fromJSON: json(#"{"tag_name":"nightly"}"#)) == nil, true)
        check("rate limit body ignored", UpdatePolicy.release(fromJSON: json(#"{"message":"API rate limit exceeded"}"#)) == nil, true)
        check("non JSON ignored", UpdatePolicy.release(fromJSON: json("<html>")) == nil, true)
        check("JSON array ignored", UpdatePolicy.release(fromJSON: json("[]")) == nil, true)
    }
}
