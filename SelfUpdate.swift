import CryptoKit
import Foundation
import Security

final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    let source: UpdateSource
    let target: URL
    let limit: Int
    let done = DispatchSemaphore(value: 0)
    var failure: UpdateRefusal?
    var status = 0

    init(source: UpdateSource, target: URL, limit: Int) {
        self.source = source
        self.target = target
        self.limit = limit
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url?.absoluteString, UpdatePolicy.redirectAllowed(url, source: source) {
            completionHandler(request)
        } else {
            failure = .urlNotAllowed
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Int64(limit) {
            failure = .tooLarge
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return }
        try? FileManager.default.removeItem(at: target)
        do { try FileManager.default.moveItem(at: location, to: target) }
        catch { failure = .downloadFailed(error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil {
            if let error { failure = .downloadFailed(error.localizedDescription) }
            else if status != 200 { failure = .downloadFailed("The server answered with status \(status).") }
        }
        done.signal()
    }
}

enum SelfUpdate {
    static func download(_ address: String, to target: URL, source: UpdateSource, limit: Int) -> UpdateRefusal? {
        guard let url = URL(string: address) else { return .urlNotAllowed }
        let delegate = UpdateDownload(source: source, target: target, limit: limit)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(UpdatePolicy.userAgent, forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: request).resume()
        delegate.done.wait()
        session.finishTasksAndInvalidate()
        return delegate.failure
    }

    static func sha256Hex(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unpack(zip: URL, into folder: URL) -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let app = folder.appendingPathComponent("VPNToggle.app")
        var isFolder: ObjCBool = false
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path, isDirectory: &isFolder), isFolder.boolValue,
              (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return nil }
        return app
    }

    static func info(ofBundle url: URL) -> (identifier: String, version: String)? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        return (identifier, version)
    }

    static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    static func isAdHoc(_ code: SecStaticCode) -> Bool? {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? UInt32 else { return nil }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    static func signatureRefusal(candidate: URL, current: URL) -> UpdateRefusal? {
        guard let running = staticCode(current), let adHoc = isAdHoc(running) else { return .adHoc }
        if adHoc { return .adHoc }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(running, [], &requirement) == errSecSuccess, let requirement,
              let new = staticCode(candidate) else { return .signature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(new, flags, requirement) == errSecSuccess ? nil : .signature
    }

    static func contentRefusal(candidate: URL, current: URL, currentVersion: String, tag: String) -> UpdateRefusal? {
        guard let new = info(ofBundle: candidate), let old = info(ofBundle: current), new.identifier == old.identifier,
              UpdatePolicy.isNewer(new.version, than: currentVersion), UpdatePolicy.sameVersion(new.version, tag) else { return .wrongApp }
        return nil
    }

    static func stagingFolder(for bundle: URL) -> URL? {
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: bundle.path) else { return nil }
        return try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
    }

    static func swap(current: URL, with new: URL) -> UpdateRefusal? {
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: new, backupItemName: nil, options: [])
            return nil
        } catch {
            return .swapFailed(error.localizedDescription)
        }
    }

    static func run(current: URL, currentVersion: String, source: UpdateSource,
                    progress: (UpdateEvent) -> Void = { _ in }) -> UpdateRefusal? {
        guard let staging = stagingFolder(for: current) else { return .notWritable }
        defer { try? FileManager.default.removeItem(at: staging) }
        let json = staging.appendingPathComponent("release.json")
        if let failure = download(source.api, to: json, source: UpdateSource(
            api: source.api, downloadPrefix: source.api, redirectHosts: [], scheme: source.scheme), limit: 4 << 20) {
            if case .downloadFailed(let why) = failure { return .noRelease(why) }
            return failure
        }
        guard let data = try? Data(contentsOf: json) else { return .noRelease("GitHub's answer could not be read.") }
        let plan: UpdatePlan
        switch UpdatePolicy.plan(json: data, current: currentVersion, assetName: UpdatePolicy.macAsset, source: source) {
        case .failure(let refusal): return refusal
        case .success(let value): plan = value
        }
        progress(.planned)
        let zip = staging.appendingPathComponent(UpdatePolicy.macAsset)
        if let failure = download(plan.url, to: zip, source: source, limit: plan.size) { return failure }
        guard let actual = sha256Hex(ofFile: zip), UpdatePolicy.digestMatches(expected: plan.sha256, actualHex: actual) else {
            try? FileManager.default.removeItem(at: zip)
            return .digestMismatch
        }
        progress(.downloaded)
        let folder = staging.appendingPathComponent("unpacked")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let candidate = unpack(zip: zip, into: folder) else { return .unpackFailed }
        if let refusal = contentRefusal(candidate: candidate, current: current, currentVersion: currentVersion, tag: plan.tag) { return refusal }
        if let refusal = signatureRefusal(candidate: candidate, current: current) { return refusal }
        progress(.verified)
        if let refusal = swap(current: current, with: candidate) { return refusal }
        progress(.installed)
        return nil
    }

    static func relaunch(bundle: URL, afterExitOf pid: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n \"$2\"",
                       "sh", String(pid), bundle.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }
}
