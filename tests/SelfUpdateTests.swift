import Foundation

enum SelfUpdateTests {
    static let base = "https://github.com/alwinpaul1/VPNToggle/releases/download/"
    static let goodDigest = "sha256:" + String(repeating: "ab", count: 32)

    static func release(tag: String = "v1.9", name: String = "VPNToggle-macOS.zip", url: String? = nil,
                        digest: String? = goodDigest, size: Int = 1000, extra: String = "") -> Data {
        let link = url ?? base + tag + "/" + name
        let digestField = digest.map { "\"digest\": \"\($0)\"," } ?? ""
        return Data("""
        {"tag_name": "\(tag)", "html_url": "https://github.com/alwinpaul1/VPNToggle/releases/tag/\(tag)",
         "assets": [{"name": "\(name)", \(digestField) "size": \(size), "browser_download_url": "\(link)"}\(extra)]}
        """.utf8)
    }

    static func refusal(_ result: Result<UpdatePlan, UpdateRefusal>) -> String? {
        if case .failure(let reason) = result { return "\(reason)" }
        return nil
    }

    static func shell(_ tool: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func makeBundle(in folder: URL, version: String, identifier: String = "com.example.vpntoggle-test", marker: String) -> URL {
        let app = folder.appendingPathComponent("VPNToggle.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try! FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try! FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("VPNToggle").path)
        try! marker.write(to: app.appendingPathComponent("Contents/Resources/marker.txt"), atomically: true, encoding: .utf8)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "VPNToggle",
                                    "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        return app
    }

    static func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
    }

    static func run() {
        let check: (String, String?, String?) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        let flag: (String, Bool, Bool) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        policy(check, flag)
        files(check, flag)
        endToEnd(check, flag)
    }

    static func policy(_ check: (String, String?, String?) -> Void, _ flag: (String, Bool, Bool) -> Void) {
        flag("url: release download allowed", UpdatePolicy.downloadAllowed(base + "v1.9/VPNToggle-macOS.zip"), true)
        flag("url: bare prefix refused", UpdatePolicy.downloadAllowed(base), false)
        flag("url: http refused", UpdatePolicy.downloadAllowed("http://github.com/alwinpaul1/VPNToggle/releases/download/v1.9/a.zip"), false)
        flag("url: another repository refused", UpdatePolicy.downloadAllowed("https://github.com/someone/VPNToggle/releases/download/v1.9/a.zip"), false)
        flag("url: look-alike host refused", UpdatePolicy.downloadAllowed("https://github.com.example.org/alwinpaul1/VPNToggle/releases/download/v1.9/a.zip"), false)
        flag("url: user info refused", UpdatePolicy.downloadAllowed("https://github.com@example.org/alwinpaul1/VPNToggle/releases/download/v1.9/a.zip"), false)
        flag("url: user info before the real host refused", UpdatePolicy.downloadAllowed("https://x@github.com/alwinpaul1/VPNToggle/releases/download/v1.9/a.zip"), false)
        flag("url: parent segments refused", UpdatePolicy.downloadAllowed(base + "v1.9/../../../../evil/a.zip"), false)
        flag("url: encoded parent segments refused", UpdatePolicy.downloadAllowed(base + "v1.9/%2e%2e/%2E%2E/a.zip"), false)
        flag("url: encoded slash refused", UpdatePolicy.downloadAllowed(base + "v1.9%2Fa.zip"), false)
        flag("url: whitespace refused", UpdatePolicy.downloadAllowed(base + "v1.9/a .zip"), false)
        flag("url: backslash refused", UpdatePolicy.downloadAllowed(base + "v1.9\\a.zip"), false)
        flag("url: release page is not a download", UpdatePolicy.downloadAllowed("https://github.com/alwinpaul1/VPNToggle/releases/tag/v1.9"), false)
        flag("url: empty refused", UpdatePolicy.downloadAllowed(""), false)

        flag("redirect: objects host allowed", UpdatePolicy.redirectAllowed("https://objects.githubusercontent.com/github-production-release-asset/1/2?sig=3"), true)
        flag("redirect: release-assets host allowed", UpdatePolicy.redirectAllowed("https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r"), true)
        flag("redirect: back to a release download allowed", UpdatePolicy.redirectAllowed(base + "v1.9/VPNToggle-macOS.zip"), true)
        flag("redirect: other host refused", UpdatePolicy.redirectAllowed("https://example.org/a.zip"), false)
        flag("redirect: http refused", UpdatePolicy.redirectAllowed("http://objects.githubusercontent.com/a"), false)
        flag("redirect: look-alike suffix refused", UpdatePolicy.redirectAllowed("https://objects.githubusercontent.com.example.org/a"), false)
        flag("redirect: subdomain of an allowed host refused", UpdatePolicy.redirectAllowed("https://x.objects.githubusercontent.com/a"), false)

        check("digest: plain", UpdatePolicy.sha256(fromDigest: goodDigest), String(repeating: "ab", count: 32))
        check("digest: upper case accepted and lowered", UpdatePolicy.sha256(fromDigest: "sha256:" + String(repeating: "AB", count: 32)), String(repeating: "ab", count: 32))
        check("digest: missing", UpdatePolicy.sha256(fromDigest: nil), nil)
        check("digest: empty", UpdatePolicy.sha256(fromDigest: ""), nil)
        check("digest: other algorithm", UpdatePolicy.sha256(fromDigest: "sha1:" + String(repeating: "ab", count: 20)), nil)
        check("digest: too short", UpdatePolicy.sha256(fromDigest: "sha256:abcd"), nil)
        check("digest: too long", UpdatePolicy.sha256(fromDigest: goodDigest + "ab"), nil)
        check("digest: not hex", UpdatePolicy.sha256(fromDigest: "sha256:" + String(repeating: "zz", count: 32)), nil)
        check("digest: no prefix", UpdatePolicy.sha256(fromDigest: String(repeating: "ab", count: 32)), nil)
        flag("digest: equal matches", UpdatePolicy.digestMatches(expected: String(repeating: "ab", count: 32), actualHex: String(repeating: "AB", count: 32)), true)
        flag("digest: one character off", UpdatePolicy.digestMatches(expected: String(repeating: "ab", count: 32), actualHex: String(repeating: "ab", count: 31) + "ac"), false)
        flag("digest: empty never matches", UpdatePolicy.digestMatches(expected: "", actualHex: ""), false)

        let good = UpdatePolicy.plan(json: release(), current: "1.8", assetName: UpdatePolicy.macAsset)
        flag("plan: newer release with digest accepted",
             good == .success(UpdatePlan(tag: "v1.9", url: base + "v1.9/VPNToggle-macOS.zip", sha256: String(repeating: "ab", count: 32), size: 1000)), true)
        check("plan: same version", refusal(UpdatePolicy.plan(json: release(tag: "v1.8"), current: "1.8", assetName: UpdatePolicy.macAsset)), "notNewer")
        check("plan: older release", refusal(UpdatePolicy.plan(json: release(tag: "v1.7"), current: "1.8", assetName: UpdatePolicy.macAsset)), "notNewer")
        check("plan: unknown running version", refusal(UpdatePolicy.plan(json: release(), current: "", assetName: UpdatePolicy.macAsset)), "notNewer")
        check("plan: other platform's asset only", refusal(UpdatePolicy.plan(json: release(name: "VPNToggle.exe"), current: "1.8", assetName: UpdatePolicy.macAsset)), "noAsset")
        check("plan: asset name must match exactly", refusal(UpdatePolicy.plan(json: release(name: "VPNToggle-macOS.zip.exe"), current: "1.8", assetName: UpdatePolicy.macAsset)), "noAsset")
        let twin = ", {\"name\": \"VPNToggle-macOS.zip\", \"digest\": \"\(goodDigest)\", \"size\": 5, \"browser_download_url\": \"\(base)v1.9/other.zip\"}"
        check("plan: two assets with the name", refusal(UpdatePolicy.plan(json: release(extra: twin), current: "1.8", assetName: UpdatePolicy.macAsset)), "noAsset")
        check("plan: download from another host", refusal(UpdatePolicy.plan(json: release(url: "https://example.org/VPNToggle-macOS.zip"), current: "1.8", assetName: UpdatePolicy.macAsset)), "urlNotAllowed")
        check("plan: no digest", refusal(UpdatePolicy.plan(json: release(digest: nil), current: "1.8", assetName: UpdatePolicy.macAsset)), "missingDigest")
        check("plan: malformed digest", refusal(UpdatePolicy.plan(json: release(digest: "sha256:123"), current: "1.8", assetName: UpdatePolicy.macAsset)), "missingDigest")
        check("plan: zero size", refusal(UpdatePolicy.plan(json: release(size: 0), current: "1.8", assetName: UpdatePolicy.macAsset)), "tooLarge")
        check("plan: oversized", refusal(UpdatePolicy.plan(json: release(size: UpdatePolicy.maxAssetBytes + 1), current: "1.8", assetName: UpdatePolicy.macAsset)), "tooLarge")
        flag("plan: unreadable answer", refusal(UpdatePolicy.plan(json: Data("<html>".utf8), current: "1.8", assetName: UpdatePolicy.macAsset))?.hasPrefix("noRelease") ?? false, true)
        let draft = Data(String(decoding: release(), as: UTF8.self).replacingOccurrences(of: "{\"tag_name\"", with: "{\"prerelease\": true, \"tag_name\"").utf8)
        flag("plan: prerelease", refusal(UpdatePolicy.plan(json: draft, current: "1.8", assetName: UpdatePolicy.macAsset))?.hasPrefix("noRelease") ?? false, true)

        flag("source: nothing set is production", UpdatePolicy.source(testAPI: nil) == UpdatePolicy.production, true)
        flag("source: loopback accepted", UpdatePolicy.source(testAPI: "http://127.0.0.1:8123/latest.json").downloadPrefix == "http://127.0.0.1:8123/", true)
        flag("source: remote host ignored", UpdatePolicy.source(testAPI: "http://example.org:8123/latest.json") == UpdatePolicy.production, true)
        flag("source: https remote ignored", UpdatePolicy.source(testAPI: "https://example.org/latest.json") == UpdatePolicy.production, true)
        flag("source: loopback without a port ignored", UpdatePolicy.source(testAPI: "http://127.0.0.1/latest.json") == UpdatePolicy.production, true)
        flag("source: loopback look-alike ignored", UpdatePolicy.source(testAPI: "http://127.0.0.1.example.org:80/latest.json") == UpdatePolicy.production, true)
        let local = UpdatePolicy.source(testAPI: "http://127.0.0.1:8123/latest.json")
        flag("source: test server's own file allowed", UpdatePolicy.downloadAllowed("http://127.0.0.1:8123/VPNToggle-macOS.zip", source: local), true)
        flag("source: another port refused", UpdatePolicy.downloadAllowed("http://127.0.0.1:9999/VPNToggle-macOS.zip", source: local), false)
        flag("source: port prefix look-alike refused", UpdatePolicy.downloadAllowed("http://127.0.0.1:81234/VPNToggle-macOS.zip", source: local), false)
        flag("source: GitHub refused while testing", UpdatePolicy.downloadAllowed(base + "v1.9/VPNToggle-macOS.zip", source: local), false)

        flag("flow: start", UpdatePolicy.next(.idle, .start) == .checking, true)
        flag("flow: planned", UpdatePolicy.next(.checking, .planned) == .downloading, true)
        flag("flow: downloaded", UpdatePolicy.next(.downloading, .downloaded) == .verifying, true)
        flag("flow: verified", UpdatePolicy.next(.verifying, .verified) == .installing, true)
        flag("flow: installed", UpdatePolicy.next(.installing, .installed) == .relaunching, true)
        flag("flow: a step out of order changes nothing", UpdatePolicy.next(.checking, .installed) == .checking, true)
        flag("flow: nothing installs from idle", UpdatePolicy.next(.idle, .installed) == .idle, true)
        flag("flow: a second click while busy changes nothing", UpdatePolicy.next(.downloading, .start) == .downloading, true)
        flag("flow: refusal while busy fails", UpdatePolicy.next(.downloading, .refused(.digestMismatch)) == .failed(.digestMismatch), true)
        flag("flow: refusal while idle changes nothing", UpdatePolicy.next(.idle, .refused(.digestMismatch)) == .idle, true)
        flag("flow: retry after a failure", UpdatePolicy.next(.failed(.digestMismatch), .start) == .checking, true)
        flag("flow: reset", UpdatePolicy.next(.failed(.signature), .reset) == .idle, true)
        flag("flow: restarting is final", UpdatePolicy.next(.relaunching, .refused(.signature)) == .relaunching, true)
        flag("flow: idle is not busy", UpdatePolicy.busy(.idle), false)
        flag("flow: failed is not busy", UpdatePolicy.busy(.failed(.signature)), false)
        flag("flow: downloading is busy", UpdatePolicy.busy(.downloading), true)
        check("button: idle", UpdatePolicy.buttonTitle(.idle), "Install update")
        check("button: downloading", UpdatePolicy.buttonTitle(.downloading), "Downloading…")
        check("button: installing", UpdatePolicy.buttonTitle(.installing), "Installing…")
        let reasons: [UpdateRefusal] = [.noRelease("x"), .notNewer, .noAsset, .urlNotAllowed, .missingDigest, .tooLarge, .downloadFailed("x"),
                                        .digestMismatch, .unpackFailed, .wrongApp, .signature, .adHoc, .notWritable, .swapFailed("x")]
        flag("messages: every refusal has its own sentence", Set(reasons.map(UpdatePolicy.message)).count == reasons.count, true)
        flag("messages: none is empty or shows a case name",
             reasons.allSatisfy { !UpdatePolicy.message($0).isEmpty && !UpdatePolicy.message($0).contains("Refusal") }, true)

        flag("pause helper: same script is current", NVMPause.helperOutdated(bundled: Data("a".utf8), installed: Data("a".utf8)), false)
        flag("pause helper: different script is outdated", NVMPause.helperOutdated(bundled: Data("a".utf8), installed: Data("b".utf8)), true)
        flag("pause helper: not installed is not outdated", NVMPause.helperOutdated(bundled: Data("a".utf8), installed: nil), false)
        flag("pause helper: note asks for a refresh", NVMPause.note(.active, helperOutdated: true).contains("refresh"), true)
        check("pause helper: no note when off", NVMPause.note(.off, helperOutdated: true), NVMPause.summary)
    }

    static func files(_ check: (String, String?, String?) -> Void, _ flag: (String, Bool, Bool) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vpntoggle-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let text = root.appendingPathComponent("abc.txt")
        try! Data("abc".utf8).write(to: text)
        check("hash: known vector", SelfUpdate.sha256Hex(ofFile: text), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        check("hash: missing file", SelfUpdate.sha256Hex(ofFile: root.appendingPathComponent("none")), nil)

        let oldFolder = root.appendingPathComponent("installed"), newFolder = root.appendingPathComponent("new")
        let old = makeBundle(in: oldFolder, version: "1.8", marker: "old")
        let new = makeBundle(in: newFolder, version: "1.9", marker: "new")
        check("bundle: version read", SelfUpdate.info(ofBundle: new)?.version, "1.9")
        check("bundle: no Info.plist", SelfUpdate.info(ofBundle: root)?.version, nil)

        check("content: newer bundle of the same app", SelfUpdate.contentRefusal(candidate: new, current: old, currentVersion: "1.8", tag: "v1.9").map { "\($0)" }, nil)
        check("content: bundle older than the tag says", SelfUpdate.contentRefusal(candidate: new, current: old, currentVersion: "1.8", tag: "v2.0").map { "\($0)" }, "wrongApp")
        check("content: not newer than the running one", SelfUpdate.contentRefusal(candidate: new, current: old, currentVersion: "1.9", tag: "v1.9").map { "\($0)" }, "wrongApp")
        let other = makeBundle(in: root.appendingPathComponent("other"), version: "1.9", identifier: "com.example.other", marker: "other")
        check("content: another app", SelfUpdate.contentRefusal(candidate: other, current: old, currentVersion: "1.8", tag: "v1.9").map { "\($0)" }, "wrongApp")

        check("signature: a bundle that is not validly signed is refused", SelfUpdate.signatureRefusal(candidate: new, current: old).map { "\($0)" }, "signature")
        check("signature: a folder that is no bundle cannot vouch", SelfUpdate.signatureRefusal(candidate: new, current: root.appendingPathComponent("absent.app")).map { "\($0)" }, "adHoc")
        if shell("/usr/bin/codesign", ["--force", "--sign", "-", old.path]) == 0, shell("/usr/bin/codesign", ["--force", "--sign", "-", new.path]) == 0 {
            flag("signature: ad hoc is detected", SelfUpdate.staticCode(old).flatMap(SelfUpdate.isAdHoc) == true, true)
            check("signature: ad hoc running copy cannot vouch", SelfUpdate.signatureRefusal(candidate: new, current: old).map { "\($0)" }, "adHoc")
        }

        let zip = root.appendingPathComponent("VPNToggle-macOS.zip")
        flag("zip: made", shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", new.path, zip.path]) == 0, true)
        let unpacked = root.appendingPathComponent("unpacked")
        try! FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        check("zip: app found after unpacking", SelfUpdate.unpack(zip: zip, into: unpacked).flatMap(marker), "new")
        let junk = root.appendingPathComponent("junk.zip")
        try! Data("not a zip".utf8).write(to: junk)
        let junkOut = root.appendingPathComponent("junk-out")
        try! FileManager.default.createDirectory(at: junkOut, withIntermediateDirectories: true)
        flag("zip: junk refused", SelfUpdate.unpack(zip: junk, into: junkOut) == nil, true)
        let noApp = root.appendingPathComponent("noapp.zip"), noAppOut = root.appendingPathComponent("noapp-out")
        _ = shell("/usr/bin/ditto", ["-c", "-k", text.path, noApp.path])
        try! FileManager.default.createDirectory(at: noAppOut, withIntermediateDirectories: true)
        flag("zip: archive without the app refused", SelfUpdate.unpack(zip: noApp, into: noAppOut) == nil, true)

        flag("staging: writable install folder gets one", SelfUpdate.stagingFolder(for: old) != nil, true)
        flag("staging: system folder gets none", SelfUpdate.stagingFolder(for: URL(fileURLWithPath: "/System/Applications/Calculator.app")) == nil, true)
        check("swap: no error", SelfUpdate.swap(current: old, with: unpacked.appendingPathComponent("VPNToggle.app")).map { "\($0)" }, nil)
        check("swap: new bundle is in the old place", marker(old), "new")
        check("swap: version in place", SelfUpdate.info(ofBundle: old)?.version, "1.9")
        flag("swap: a missing new bundle fails", SelfUpdate.swap(current: old, with: root.appendingPathComponent("gone.app")) != nil, true)
        check("swap: failed swap leaves the bundle", marker(old), "new")
    }

    static func endToEnd(_ check: (String, String?, String?) -> Void, _ flag: (String, Bool, Bool) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vpntoggle-test-\(UUID().uuidString)")
        let served = root.appendingPathComponent("served")
        try! FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = makeBundle(in: root.appendingPathComponent("installed"), version: "1.8", marker: "old")
        let new = makeBundle(in: root.appendingPathComponent("new"), version: "9.0", marker: "new")
        _ = shell("/usr/bin/codesign", ["--force", "--sign", "-", installed.path])
        _ = shell("/usr/bin/codesign", ["--force", "--sign", "-", new.path])
        let zip = served.appendingPathComponent("VPNToggle-macOS.zip")
        _ = shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", new.path, zip.path])
        guard let hash = SelfUpdate.sha256Hex(ofFile: zip),
              let size = (try? FileManager.default.attributesOfItem(atPath: zip.path))?[.size] as? Int else {
            flag("end to end: fixture built", false, true)
            return
        }

        let port = Int.random(in: 20000...60000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", served.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        server.standardInput = FileHandle.nullDevice
        guard (try? server.run()) != nil else {
            flag("end to end: local server started", false, true)
            return
        }
        defer { server.terminate() }
        let origin = "http://127.0.0.1:\(port)/"
        let source = UpdatePolicy.source(testAPI: origin + "latest.json")
        var up = false
        for _ in 0..<50 where !up {
            up = (try? Data(contentsOf: URL(string: origin + "VPNToggle-macOS.zip")!)) != nil
            if !up { usleep(100_000) }
        }
        flag("end to end: local server answers", up, true)
        guard up else { return }

        func attempt(_ name: String, json: Data?, expected: String, currentVersion: String = "1.8") {
            let file = served.appendingPathComponent("latest.json")
            try? FileManager.default.removeItem(at: file)
            if let json { try! json.write(to: file) }
            let result = SelfUpdate.run(current: installed, currentVersion: currentVersion, source: source)
            let text = result.map { "\($0)" } ?? "installed"
            flag("end to end: \(name) (\(text))", text.hasPrefix(expected), true)
            check("end to end: \(name) leaves the old app", marker(installed), "old")
        }
        let good = "sha256:" + hash
        attempt("no release file", json: nil, expected: "noRelease")
        attempt("bad digest", json: release(tag: "v9.0", url: origin + "VPNToggle-macOS.zip", digest: goodDigest, size: size), expected: "digestMismatch")
        attempt("missing digest", json: release(tag: "v9.0", url: origin + "VPNToggle-macOS.zip", digest: nil, size: size), expected: "missingDigest")
        attempt("disallowed host", json: release(tag: "v9.0", url: base + "v9.0/VPNToggle-macOS.zip", digest: good, size: size), expected: "urlNotAllowed")
        attempt("another local port", json: release(tag: "v9.0", url: "http://127.0.0.1:\(port + 1)/VPNToggle-macOS.zip", digest: good, size: size), expected: "urlNotAllowed")
        attempt("missing file", json: release(tag: "v9.0", url: origin + "absent.zip", digest: good, size: size), expected: "downloadFailed")
        attempt("larger than the release says", json: release(tag: "v9.0", url: origin + "VPNToggle-macOS.zip", digest: good, size: 10), expected: "tooLarge")
        attempt("not newer", json: release(tag: "v9.0", url: origin + "VPNToggle-macOS.zip", digest: good, size: size), expected: "notNewer", currentVersion: "9.0")
        attempt("tag and bundle disagree", json: release(tag: "v9.5", url: origin + "VPNToggle-macOS.zip", digest: good, size: size), expected: "wrongApp")
        attempt("valid download, ad hoc running copy", json: release(tag: "v9.0", url: origin + "VPNToggle-macOS.zip", digest: good, size: size), expected: "adHoc")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)) ?? []
        check("end to end: nothing left next to the app", leftovers.sorted().joined(separator: ","), "VPNToggle.app")
    }
}
