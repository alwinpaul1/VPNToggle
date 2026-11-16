import Foundation

@main
struct StatusBench {
    static let cli = "/opt/cisco/secureclient/bin/vpn"

    static func oneShot(_ argument: String) -> (seconds: TimeInterval, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = [argument]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let started = Date()
        do { try p.run() } catch { return (0, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (Date().timeIntervalSince(started), String(decoding: data, as: UTF8.self))
    }

    static func line(_ name: String, _ values: [TimeInterval]) {
        let sorted = values.sorted()
        let median = sorted.isEmpty ? TimeInterval.nan : sorted[sorted.count / 2]
        let padded = name.padding(toLength: 36, withPad: " ", startingAt: 0)
        print(String(format: "%@ median %.3f s  min %.3f  max %.3f", padded, median, sorted.first ?? .nan, sorted.last ?? .nan))
    }

    static func main() {
        let rounds = max(CommandLine.arguments.dropFirst().first.flatMap { Int($0) } ?? 5, 1)
        var stateTimes: [TimeInterval] = [], statsTimes: [TimeInterval] = []
        var earlyTimes: [TimeInterval] = [], fastTimes: [TimeInterval] = []
        var mismatches = 0, retries = 0, unusable = 0
        for round in 1...rounds {
            let state = oneShot("state")
            let stats = oneShot("stats")
            var early: (state: VPNState, at: TimeInterval)?
            let started = Date()
            let fast = StatusSession.read(cli: cli, onState: { s, t in early = (s, t) })
            let fastTime = Date().timeIntervalSince(started)
            let banner = StatusPolicy.state(fromBanner: state.output)
            let slow = StatusPolicy.reading(fromStats: stats.output)
            guard let banner, slow.state != nil else {
                mismatches += 1
                print("round \(round): the current path returned nothing")
                continue
            }
            stateTimes.append(state.seconds)
            statsTimes.append(stats.seconds)
            guard let fast, let early, StatusPolicy.sessionUsable(fast.reading) else {
                unusable += 1
                continue
            }
            earlyTimes.append(early.at)
            fastTimes.append(fastTime)
            retries += fast.requests - 1
            let connected = slow.state == .connected
            let drift = abs((fast.reading.seconds ?? -99) - (slow.seconds ?? -99))
            let agrees = fast.reading.state == slow.state && early.state == banner
                && (!connected || (fast.reading.ip == slow.ip && drift <= 3))
            if !agrees {
                mismatches += 1
                print("round \(round): readings differ; state \(fast.reading.state == slow.state), early state \(early.state == banner), address \(fast.reading.ip == slow.ip), duration drift \(drift) s")
            }
        }
        print("rounds: \(rounds)")
        line("vpn state (fallback of the fallback)", stateTimes)
        line("vpn stats (fallback path)", statsTimes)
        line("vpn -s session: state known", earlyTimes)
        line("vpn -s session: full reading", fastTimes)
        print("second stats request needed: \(retries)")
        print("rounds that would use the fallback: \(unusable)")
        print("mismatches: \(mismatches)")
        exit(mismatches == 0 ? 0 : 1)
    }
}
