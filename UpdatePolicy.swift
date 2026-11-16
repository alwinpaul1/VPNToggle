import Foundation

struct ReleaseInfo: Equatable {
    let tag: String
    let page: String
}

struct ReleaseAsset: Equatable {
    let name: String
    let url: String
    let digest: String?
    let size: Int
}

struct UpdateSource: Equatable {
    let api: String
    let downloadPrefix: String
    let redirectHosts: [String]
    let scheme: String
}

struct UpdatePlan: Equatable {
    let tag: String
    let url: String
    let sha256: String
    let size: Int
}

enum UpdateRefusal: Error, Equatable {
    case noRelease(String)
    case notNewer
    case noAsset
    case urlNotAllowed
    case missingDigest
    case tooLarge
    case downloadFailed(String)
    case digestMismatch
    case unpackFailed
    case wrongApp
    case signature
    case adHoc
    case notWritable
    case swapFailed(String)
}

enum UpdatePhase: Equatable {
    case idle, checking, downloading, verifying, installing, relaunching
    case failed(UpdateRefusal)
}

enum UpdateEvent: Equatable {
    case start, planned, downloaded, verified, installed, reset
    case refused(UpdateRefusal)
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

    static let macAsset = "VPNToggle-macOS.zip"
    static let windowsAsset = "VPNToggle.exe"
    static let maxAssetBytes = 300 * 1024 * 1024
    static let testAPIVariable = "VPNTOGGLE_UPDATE_TEST_API"
    static let testFlag = "--self-update-test"
    static let production = UpdateSource(
        api: latestReleaseAPI,
        downloadPrefix: "https://github.com/alwinpaul1/VPNToggle/releases/download/",
        redirectHosts: ["objects.githubusercontent.com", "release-assets.githubusercontent.com"],
        scheme: "https")

    static func source(testAPI: String?) -> UpdateSource {
        guard let testAPI, let parts = URLComponents(string: testAPI), parts.scheme == "http",
              let host = parts.host, host == "127.0.0.1" || host == "localhost", let port = parts.port,
              parts.user == nil, parts.password == nil else { return production }
        return UpdateSource(api: testAPI, downloadPrefix: "http://\(host):\(port)/", redirectHosts: [], scheme: "http")
    }

    static func cleanURL(_ text: String, scheme: String) -> URLComponents? {
        guard !text.contains(where: { $0.isWhitespace || $0 == "\\" }), !text.contains("@"),
              let parts = URLComponents(string: text), parts.scheme == scheme, parts.user == nil, parts.password == nil,
              let host = parts.host, !host.isEmpty else { return nil }
        let path = parts.percentEncodedPath.lowercased()
        if path.contains("..") || path.contains("%2e") || path.contains("%2f") || path.contains("%5c") { return nil }
        return parts
    }

    static func downloadAllowed(_ url: String, source: UpdateSource = production) -> Bool {
        guard cleanURL(url, scheme: source.scheme) != nil, url.hasPrefix(source.downloadPrefix) else { return false }
        return url.count > source.downloadPrefix.count
    }

    static func redirectAllowed(_ url: String, source: UpdateSource = production) -> Bool {
        if downloadAllowed(url, source: source) { return true }
        guard let parts = cleanURL(url, scheme: source.scheme), let host = parts.host else { return false }
        return source.redirectHosts.contains(host.lowercased())
    }

    static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = String(digest.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return hex.lowercased()
    }

    static func digestMatches(expected: String, actualHex: String) -> Bool {
        expected.count == 64 && expected.lowercased() == actualHex.lowercased()
    }

    static func assets(fromJSON data: Data) -> [ReleaseAsset] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["assets"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let name = item["name"] as? String, let url = item["browser_download_url"] as? String else { return nil }
            return ReleaseAsset(name: name, url: url, digest: item["digest"] as? String, size: item["size"] as? Int ?? 0)
        }
    }

    static func plan(json data: Data, current: String, assetName: String, source: UpdateSource = production) -> Result<UpdatePlan, UpdateRefusal> {
        guard let release = release(fromJSON: data) else { return .failure(.noRelease("GitHub's answer could not be read.")) }
        guard isNewer(release.tag, than: current) else { return .failure(.notNewer) }
        let matches = assets(fromJSON: data).filter { $0.name == assetName }
        guard matches.count == 1, let asset = matches.first else { return .failure(.noAsset) }
        guard downloadAllowed(asset.url, source: source) else { return .failure(.urlNotAllowed) }
        guard let hash = sha256(fromDigest: asset.digest) else { return .failure(.missingDigest) }
        guard asset.size > 0, asset.size <= maxAssetBytes else { return .failure(.tooLarge) }
        return .success(UpdatePlan(tag: release.tag, url: asset.url, sha256: hash, size: asset.size))
    }

    static func next(_ phase: UpdatePhase, _ event: UpdateEvent) -> UpdatePhase {
        switch (phase, event) {
        case (_, .reset): return .idle
        case (.relaunching, _): return .relaunching
        case (_, .refused(let reason)): return busy(phase) ? .failed(reason) : phase
        case (.idle, .start), (.failed, .start): return .checking
        case (.checking, .planned): return .downloading
        case (.downloading, .downloaded): return .verifying
        case (.verifying, .verified): return .installing
        case (.installing, .installed): return .relaunching
        default: return phase
        }
    }

    static func busy(_ phase: UpdatePhase) -> Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    static func buttonTitle(_ phase: UpdatePhase) -> String {
        switch phase {
        case .idle, .failed: return "Install update"
        case .checking, .downloading: return "Downloading…"
        case .verifying, .installing: return "Installing…"
        case .relaunching: return "Restarting…"
        }
    }

    static func message(_ refusal: UpdateRefusal) -> String {
        switch refusal {
        case .noRelease(let why): return "Could not read the latest release. \(why)"
        case .notNewer: return "This is already the latest version."
        case .noAsset: return "The latest release has no download for this computer."
        case .urlNotAllowed: return "The download link does not point to VPNToggle's releases on GitHub, so it was not used."
        case .missingDigest: return "The release lists no checksum for the download, so it was not used."
        case .tooLarge: return "The download has an unexpected size, so it was not used."
        case .downloadFailed(let why): return "The download did not finish. \(why)"
        case .digestMismatch: return "The downloaded file does not match the checksum of the release. It was deleted."
        case .unpackFailed: return "The downloaded file could not be unpacked."
        case .wrongApp: return "The download is not a newer VPNToggle."
        case .signature: return "The new version is not signed by the same developer as this copy, so it was not installed."
        case .adHoc: return "This copy of VPNToggle was built without a signing certificate, so it cannot check an update."
        case .notWritable: return "VPNToggle cannot write to the folder it is installed in."
        case .swapFailed(let why): return "The new version could not be put in place. \(why)"
        }
    }

    static let noticeTestFlag = "--update-notice-test"

    enum NoticePermission: Equatable { case allowed, undecided, denied }
    enum NoticeAction: Equatable { case post, askThenPost, skip }

    static func shouldNotify(latest: String?, current: String, dismissed: String?, notified: String?, manual: Bool) -> Bool {
        guard !manual, let latest, showsBanner(latest: latest, current: current, dismissed: dismissed) else { return false }
        if let notified, sameVersion(notified, latest) { return false }
        return true
    }

    static func noticeAction(_ permission: NoticePermission) -> NoticeAction {
        switch permission {
        case .allowed: return .post
        case .undecided: return .askThenPost
        case .denied: return .skip
        }
    }

    static func noticeTitle(_ tag: String) -> String {
        "VPNToggle \(displayVersion(tag)) is available"
    }

    static let noticeBody = "Click to install"
    static let noticeIdentifier = "update-available"

    static func opensCard(notificationIdentifier: String) -> Bool {
        notificationIdentifier == noticeIdentifier
    }
}
