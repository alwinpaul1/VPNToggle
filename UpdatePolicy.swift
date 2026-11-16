import Foundation

struct ReleaseInfo: Equatable {
    let tag: String
    let page: String
}

enum UpdatePolicy {
    static let latestReleaseAPI = "https://api.github.com/repos/alwinpaul1/VPNToggle/releases/latest"
    static let releasesPage = "https://github.com/alwinpaul1/VPNToggle/releases/latest"
    static let trustedPagePrefix = "https://github.com/alwinpaul1/VPNToggle/releases/"
    static let userAgent = "VPNToggle"
    static let checkInterval: TimeInterval = 86_400

    static func segments(_ version: String) -> [Int]? {
        var text = Substring(version.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = text.first, first == "v" || first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers.isEmpty ? nil : numbers
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let a = segments(latest), let b = segments(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func sameVersion(_ a: String, _ b: String) -> Bool {
        guard segments(a) != nil, segments(b) != nil else { return false }
        return !isNewer(a, than: b) && !isNewer(b, than: a)
    }

    static func displayVersion(_ tag: String) -> String {
        guard let numbers = segments(tag) else { return tag }
        return numbers.map(String.init).joined(separator: ".")
    }

    static func shouldCheck(now: Date, lastCheck: Date?, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    static func showsBanner(latest: String?, current: String, dismissed: String?) -> Bool {
        guard let latest, isNewer(latest, than: current) else { return false }
        if let dismissed, sameVersion(dismissed, latest) { return false }
        return true
    }

    static func page(_ candidate: String?) -> String {
        guard let candidate, candidate.hasPrefix(trustedPagePrefix),
              !candidate.contains(where: { $0.isWhitespace }) else { return releasesPage }
        return candidate
    }

    static func release(fromJSON data: Data) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, segments(tag) != nil else { return nil }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }
        return ReleaseInfo(tag: tag, page: page(object["html_url"] as? String))
    }
}
