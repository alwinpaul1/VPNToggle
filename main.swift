import AVFoundation
import Cocoa
import CoreImage
import CryptoKit
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import Vision

// MARK: - Settings

let vpnCLI = ["/opt/cisco/secureclient/bin/vpn", "/opt/cisco/anyconnect/bin/vpn"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/cisco/secureclient/bin/vpn"
let ciscoGUIBundleIDs = ["com.cisco.secureclient.gui", "com.cisco.anyconnect.gui"]

enum Prefs {
    static let d = UserDefaults.standard
    // The CAS group signs in through a web page, which the CLI cannot do. The BTU-Account group takes
    // username + password, so it is the default here.
    static var host: String { d.string(forKey: "host") ?? "vpn-gate.b-tu.de" }
    static var group: String { d.string(forKey: "group") ?? "Anmeldung mit BTU-Account" }
    static var username: String { d.string(forKey: "username") ?? defaultUserFromCiscoPrefs() ?? "" }

    /// The CLI asks the server for the group last used (DefaultGroup in ~/.vpn/.anyconnect). If that is the
    /// CAS group, the server answers with a browser login and the CLI aborts before any group prompt, so
    /// point the preference at our group first.
    static func setCiscoDefaultGroup(_ group: String) {
        let path = NSHomeDirectory() + "/.vpn/.anyconnect"
        guard let xml = try? String(contentsOfFile: path, encoding: .utf8),
              let a = xml.range(of: "<DefaultGroup>"), let b = xml.range(of: "</DefaultGroup>"),
              xml[a.upperBound..<b.lowerBound] != group else { return }
        let escaped = group.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        try? xml.replacingCharacters(in: a.upperBound..<b.lowerBound, with: escaped)
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func defaultUserFromCiscoPrefs() -> String? {
        let path = NSHomeDirectory() + "/.vpn/.anyconnect"
        guard let xml = try? String(contentsOfFile: path, encoding: .utf8),
              let a = xml.range(of: "<DefaultUser>"), let b = xml.range(of: "</DefaultUser>") else { return nil }
        let u = String(xml[a.upperBound..<b.lowerBound])
        return u.isEmpty ? nil : u
    }
}

enum Keychain {
    static let service = "VPNToggle"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - TOTP (RFC 6238: HMAC-SHA1, 30 s step, 6 digits)

enum TOTP {
    /// Accepts a bare base32 secret or a full otpauth:// URI from the QR code.
    static func secretBytes(_ input: String) -> Data? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("otpauth-migration://") { return migrationSecret(s) }
        if s.lowercased().hasPrefix("otpauth://"),
           let q = URLComponents(string: s)?.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value {
            s = q
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for c in s.uppercased() where c != " " && c != "=" && c != "-" {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
        }
        return out.isEmpty ? nil : out
    }

    /// Google Authenticator's export QR: otpauth-migration://offline?data=<base64 protobuf MigrationPayload>.
    /// Picks the TOTP entry whose name or issuer mentions BTU, or the only TOTP entry if there is one.
    static func migrationSecret(_ uri: String) -> Data? {
        guard var b64 = URLComponents(string: uri)?.queryItems?.first(where: { $0.name == "data" })?.value else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let payload = Data(base64Encoded: b64) else { return nil }

        struct Entry { var secret = Data(), label = "", type: UInt64 = 2 }  // type 2 = TOTP (the default)
        var entries: [Entry] = []
        for (field, value) in protobufFields([UInt8](payload)) where field == 1 {
            guard case .bytes(let b) = value else { continue }
            var e = Entry()
            for (f, v) in protobufFields(b) {
                switch (f, v) {
                case (1, .bytes(let s)): e.secret = Data(s)
                case (2, .bytes(let s)), (3, .bytes(let s)): e.label += String(decoding: s, as: UTF8.self) + " "
                case (6, .varint(let t)): e.type = t
                default: break
                }
            }
            if e.type == 2 && !e.secret.isEmpty { entries.append(e) }
        }
        let btu = entries.filter { $0.label.lowercased().contains("btu") || $0.label.lowercased().contains("b-tu") }
        if btu.count == 1 { return btu[0].secret }
        return entries.count == 1 ? entries[0].secret : nil
    }

    enum PBValue { case varint(UInt64), bytes([UInt8]) }

    static func protobufFields(_ b: [UInt8]) -> [(Int, PBValue)] {
        var out: [(Int, PBValue)] = [], i = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count && shift < 64 {
                let x = b[i]; i += 1
                v |= UInt64(x & 0x7F) << shift
                if x & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count, let key = varint() {
            switch key & 7 {
            case 0: guard let v = varint() else { return out }; out.append((Int(key >> 3), .varint(v)))
            case 2:
                guard let n = varint(), i + Int(n) <= b.count else { return out }
                out.append((Int(key >> 3), .bytes(Array(b[i..<i + Int(n)])))); i += Int(n)
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }

    /// Reads the first QR code in an image file.
    static func qrText(from url: URL) -> String? {
        guard let img = CIImage(contentsOf: url),
              let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return det.features(in: img).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    static func code(secret: Data, at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
        let o = Int(mac[19] & 0x0F)
        let n = (UInt32(mac[o] & 0x7F) << 24) | (UInt32(mac[o + 1]) << 16) | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
        return String(format: "%06u", n % 1_000_000)
    }

    /// A code with at least 5 s of validity left, so it does not expire in transit.
    static func freshCode(secret: Data) -> String {
        let left = 30 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
        if left < 5 { Thread.sleep(forTimeInterval: left + 0.5) }
        return code(secret: secret)
    }
}

// MARK: - Cisco CLI

enum VPNState { case connected, disconnected, busy, unknown }

/// Runs `vpn <args>` and returns its combined output.
func runVPN(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: vpnCLI)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return "could not start \(vpnCLI): \(error)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// Client IP and connected time from `vpn stats`, e.g. ("141.43.0.10", "1h 05m").
func connectionInfo() -> (ip: String?, duration: String?) {
    var ip: String?, duration: String?
    for line in runVPN(["stats"]).components(separatedBy: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[1] != "Not Available" else { continue }
        if parts[0] == "Client Address (IPv4)" { ip = parts[1] }
        if parts[0] == "Duration" {
            // "00:12:05" or "1 day(s) 02:03:04" -> "12m", "1d 2h 03m"
            let hms = parts[1].split(separator: " ").last?.split(separator: ":").compactMap { Int($0) } ?? []
            let days = parts[1].contains("day") ? Int(parts[1].split(separator: " ").first ?? "") ?? 0 : 0
            if hms.count == 3 {
                let (h, m) = (hms[0], hms[1])
                duration = days > 0 ? "\(days)d \(h)h \(String(format: "%02d", m))m"
                    : h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(max(m, 1))m"
            }
        }
    }
    return (ip, duration)
}

func currentState() -> VPNState {
    let out = runVPN(["state"])
    guard let line = out.components(separatedBy: "\n").last(where: { $0.contains("state:") }) else { return .unknown }
    if line.contains("Disconnected") { return .disconnected }
    if line.contains("Connected") { return .connected }
    return .busy
}

/// Asks for a 2FA code on the main thread; called from the background connect job.
func askForCode() -> String? {
    DispatchQueue.main.sync {
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 34))
        f.placeholderString = "000000"
        f.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        f.alignment = .center
        let a = NSAlert()
        a.messageText = "2FA code"
        a.informativeText = "Enter the current code from your authenticator app."
        a.accessoryView = f
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue.trimmingCharacters(in: .whitespaces) : nil
    }
}

/// Connects with `vpn -s` on a pseudo-terminal, answering each prompt as it appears, so a prompt the
/// server skips never swallows the wrong answer. Secrets are scrubbed from the returned log.
/// `message` is a one-line reason on failure, nil when the user cancelled.
func connect(host: String, group: String, user: String, password: String, pin: String?, totpSecret: Data?) -> (ok: Bool, message: String?, log: String) {
    var master: Int32 = 0, slave: Int32 = 0
    guard openpty(&master, &slave, nil, nil, nil) == 0 else { return (false, "Could not open a terminal for the Cisco CLI.", "") }
    var t = termios()
    tcgetattr(slave, &t)
    t.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(slave, TCSANOW, &t)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: vpnCLI)
    p.arguments = ["-s"]
    let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    p.standardInput = slaveHandle
    p.standardOutput = slaveHandle
    p.standardError = slaveHandle
    do { try p.run() } catch { close(master); close(slave); return (false, "Could not start the Cisco CLI.", "\(error)") }
    close(slave)

    func send(_ s: String) { _ = (s + "\n").withCString { write(master, $0, strlen($0)) } }
    send("connect \(host)")

    var log = "", pending = ""
    var asked: [String: Int] = [:]
    var failure: String?, cancelled = false
    let deadline = Date().addingTimeInterval(180)
    var buf = [UInt8](repeating: 0, count: 4096)

    // Ends when the CLI exits (read returns EIO) or the deadline passes.
    readLoop: while Date() < deadline {
        var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 500) <= 0 { if !p.isRunning { break }; continue }
        let n = read(master, &buf, buf.count)
        if n <= 0 { break }
        let chunk = String(decoding: buf[0..<n], as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        log += chunk
        pending += chunk

        let tail = (pending.components(separatedBy: "\n").last ?? "").trimmingCharacters(in: .whitespaces)
        let low = tail.lowercased()
        var kind: String?, reply: String?
        if low.hasSuffix("[y/n]:") {
            // Accept the login banner only. Refuse anything else, e.g. an untrusted server certificate.
            kind = "yn"; reply = low.contains("accept?") ? "y" : "n"
        } else if low.hasPrefix("group:") {
            kind = "group"; reply = group
        } else if low.hasPrefix("username:") && !low.contains("password") {
            kind = "user"; reply = user
        } else if low.hasSuffix(":") && low.contains("pin") && !(pin ?? "").isEmpty {
            kind = "pin"; reply = pin
        } else if low.hasSuffix(":") && (low.hasPrefix("answer") || low.contains("second password") || low.contains("pin")
                    || low.contains("code") || low.contains("passcode") || low.contains("otp") || low.contains("token")) {
            // BTU asks "Answer:" for its 2FA token. Generate the code from a saved secret, else use a saved
            // PIN, else ask the user for the code.
            if let totpSecret { kind = "otp"; reply = TOTP.freshCode(secret: totpSecret) }
            else if let pin, !pin.isEmpty { kind = "pin"; reply = pin }
            else if let typed = askForCode(), !typed.isEmpty { kind = "otp"; reply = typed }
            else { cancelled = true; break readLoop }
        } else if low.hasSuffix("password:") {
            kind = "password"; reply = password
        }
        if let kind, let reply {
            asked[kind, default: 0] += 1
            if asked[kind]! > 2 { failure = "Login rejected. Check your password and 2FA code."; break }
            pending = ""
            send(reply)
        }
        if log.contains("state: Connected") { break }
        if log.contains("Login failed") { failure = "Login rejected. Check your password and 2FA code."; break }
    }

    if p.isRunning { send("exit"); usleep(300_000) }
    if p.isRunning { p.terminate() }
    close(master)

    // The CLI may echo answers ("password will echo"), so scrub secrets before the log is shown.
    for secret in [password, pin ?? ""] where secret.count >= 3 {
        log = log.replacingOccurrences(of: secret, with: "••••")
    }
    if cancelled { return (false, nil, log) }
    if let failure { return (false, failure, log) }
    if currentState() == .connected { return (true, nil, log) }
    // Prefer the CLI's own error line, e.g. ">> error: The requested authentication type is not supported".
    let cliError = log.components(separatedBy: "\n").first { $0.contains(">> error:") }?
        .components(separatedBy: ">> error:").last?.trimmingCharacters(in: .whitespaces)
    return (false, cliError ?? "Could not connect to \(host).", log)
}

// MARK: - Event log

/// Appends one timestamped line to ~/Library/Logs/VPNToggle.log, so a drop can be told apart from a click.
func logEvent(_ text: String) {
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/VPNToggle.log")
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = Data("\(f.string(from: Date()))  \(text)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line); try? h.close()
    } else {
        try? line.write(to: url)
    }
}

// MARK: - Notifications

enum Notify {
    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            logEvent("notifications \(granted ? "allowed" : "not allowed")")
        }
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A fixed identifier replaces the previous VPN banner instead of stacking them.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "vpn-state", content: content, trigger: nil))
    }
}

// MARK: - Floating panels under the menu bar

/// A borderless, non-activating panel that drops in just below the menu bar, centred on the icon.
/// NSPopover anchors upward on this macOS (over the menu bar), so this replaces it.
final class FloatingPanel: NSPanel {
    let host: NSView

    init(content: NSView, cornerRadius: CGFloat) {
        host = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false   // the window shadow is rectangular here and shows at the corners; the glass has its own rim
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Liquid Glass, as on the system's own menu bar panels; it follows light/dark by itself.
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        // A clear container as the window's content view, so the window itself draws nothing
        // outside the glass's rounded corners.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    func show(under icon: NSRect, makeKey: Bool) {
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) } ?? NSScreen.main!
        let x = min(max(icon.midX - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        let top = icon.minY - 6
        let target = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        if isVisible { setFrame(target, display: true); return }
        setFrame(target.offsetBy(dx: 0, dy: 6), display: false)
        contentView?.subviews.first?.frame = contentView?.bounds ?? .zero
        alphaValue = 0
        if makeKey { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.16
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            // Recompute the shadow from the drawn glass, so it follows the rounded corners.
            self?.invalidateShadow()
        }
    }

    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { self.orderOut(nil) })
    }
}

/// Shows the small status card while the pointer rests on the icon. The menu bar does not deliver
/// enter/exit events to status items on this macOS, so it polls the pointer instead.
final class HoverController {
    let panel: FloatingPanel
    var iconFrame: () -> NSRect?
    var blocked: () -> Bool = { false }
    var inside = false
    var suppressed = false   // after a click, stay hidden until the pointer leaves
    var pending: DispatchWorkItem?

    init(panel: FloatingPanel, iconFrame: @escaping () -> NSRect?) {
        self.panel = panel
        self.iconFrame = iconFrame
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        guard let f = iconFrame(), f.height > 0 else { return }
        let now = f.contains(NSEvent.mouseLocation)
        guard now != inside else { return }
        inside = now
        if now {
            pending?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.inside, !self.suppressed, !self.blocked(), let f = self.iconFrame() else { return }
                self.panel.show(under: f, makeKey: false)
            }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        } else {
            suppressed = false
            hide()
        }
    }

    func hide() {
        pending?.cancel()
        panel.dismiss()
    }
}

// MARK: - Menu bar app

/// "Read QR image…" in the credentials dialog: decodes a QR image straight into the 2FA field, so the
/// secret never passes through the clipboard.
final class QRPicker: NSObject {
    weak var target: NSTextField?

    let scanner = QRCameraScanner()

    func buttons(for field: NSTextField) -> NSView {
        target = field
        let row = NSStackView(views: [
            NSButton(title: "Read QR image…", target: self, action: #selector(pick)),
            NSButton(title: "Scan with camera…", target: self, action: #selector(scan)),
        ])
        row.spacing = 8
        return row
    }

    @objc func scan() {
        scanner.scan { [weak self] text in
            self?.target?.stringValue = text
            let a = NSAlert()
            a.messageText = "2FA secret read"
            a.informativeText = "Click Save to store it."
            a.runModal()
        }
    }

    @objc func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a screenshot or photo of the Google Authenticator export QR code"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let a = NSAlert()
        if let text = TOTP.qrText(from: url), TOTP.secretBytes(text) != nil {
            target?.stringValue = text
            a.messageText = "2FA secret read"
            a.informativeText = "Click Save to store it. You can now delete the image."
        } else {
            a.messageText = "No usable 2FA secret found"
            a.informativeText = "The image needs one readable QR code that contains the BTU entry. If the export holds several accounts, export only the BTU one."
        }
        a.runModal()
    }
}

/// Live camera QR scanner: hold the Google Authenticator export QR up to the camera. It stops at the
/// first QR code that holds a usable 2FA secret and ignores any other.
final class QRCameraScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, NSWindowDelegate {
    var session: AVCaptureSession?
    var window: NSPanel?
    let hint = NSTextField(labelWithString: "")
    let queue = DispatchQueue(label: "qr-camera")
    var onResult: ((String) -> Void)?
    var result: String?
    var lastScan = Date.distantPast

    func scan(onResult: @escaping (String) -> Void) {
        self.onResult = onResult
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            open()
        case .notDetermined:
            // The answer arrives off the main thread; the modal run loop below still services the main queue.
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { ok ? self.open() : self.denied() } }
        default:
            denied()
        }
    }

    func denied() {
        let a = NSAlert()
        a.messageText = "No camera access"
        a.informativeText = "Allow VPNToggle in System Settings → Privacy & Security → Camera, or use Read QR image… instead."
        a.runModal()
    }

    func open() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else {
            let a = NSAlert()
            a.messageText = "No camera found"
            a.informativeText = "Use Read QR image… with a screenshot of the QR code instead."
            a.runModal()
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        self.session = session
        result = nil

        // Camera preview, mirrored like a selfie view, with a viewfinder square.
        let preview = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 390))
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = preview.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        preview.layer?.addSublayer(layer)
        let finder = CAShapeLayer()
        let side: CGFloat = 230
        finder.path = CGPath(roundedRect: CGRect(x: (520 - side) / 2, y: (390 - side) / 2 + 10, width: side, height: side),
                             cornerWidth: 22, cornerHeight: 22, transform: nil)
        finder.fillColor = nil
        finder.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        finder.lineWidth = 3
        preview.layer?.addSublayer(finder)

        hint.stringValue = "Hold the Google Authenticator export QR code up to the camera"
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let bottom = NSStackView(views: [hint, cancel])
        bottom.orientation = .vertical
        bottom.spacing = 10
        bottom.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)

        let stack = NSStackView(views: [preview, bottom])
        stack.orientation = .vertical
        stack.spacing = 0
        preview.widthAnchor.constraint(equalToConstant: 520).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 390).isActive = true

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Scan QR code"
        panel.titlebarAppearsTransparent = true
        panel.contentView = stack
        panel.delegate = self
        panel.center()
        window = panel

        queue.async { session.startRunning() }
        NSApp.activate(ignoringOtherApps: true)
        // Modal, so it works on top of the credentials dialog (itself modal).
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        queue.async { session.stopRunning() }
        self.session = nil
        window = nil
        if let r = result { onResult?(r) }
    }

    @objc func cancel() { NSApp.stopModal() }
    func windowWillClose(_ notification: Notification) { NSApp.stopModal() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // About eight looks a second is plenty and keeps the CPU quiet.
        guard result == nil, Date().timeIntervalSince(lastScan) > 0.12,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = Date()
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        for code in request.results ?? [] {
            guard let text = code.payloadStringValue else { continue }
            if TOTP.secretBytes(text) != nil {
                result = text
                DispatchQueue.main.async { NSApp.stopModal() }
                return
            }
            DispatchQueue.main.async {
                self.hint.stringValue = "That QR code holds no usable 2FA secret. Show the export QR for the BTU account."
            }
        }
    }
}

// MARK: - Card UI

/// What the card shows; AppDelegate owns the logic and updates this.
final class VPNModel: ObservableObject {
    @Published var state: VPNState = .unknown
    @Published var activity: String?          // "Connecting…" etc. while a job runs
    @Published var ip: String?
    @Published var duration: String?
    @Published var dropped = false
    @Published var autoReconnect = true
    @Published var launchAtLogin = false
    @Published var autoTwoFactor = false
    var host: String { Prefs.host }

    var onToggle: () -> Void = {}
    var onCredentials: () -> Void = {}
    var onAutoReconnect: () -> Void = {}
    var onLaunchAtLogin: () -> Void = {}
    var onOpenLog: () -> Void = {}

    var connected: Bool { state == .connected && activity == nil }
    var tint: Color {
        if activity != nil { return Color(red: 0.20, green: 0.48, blue: 1.0) }
        if connected { return Color(red: 0.13, green: 0.74, blue: 0.42) }
        return dropped ? Color(red: 1.0, green: 0.58, blue: 0.10) : Color(nsColor: .systemGray)
    }
    var symbol: String {
        if connected { return "lock.shield.fill" }
        return dropped ? "exclamationmark.shield.fill" : "shield.slash.fill"
    }
    var title: String {
        if let a = activity { return a }
        switch state {
        case .connected: return "Connected"
        case .disconnected: return dropped ? "Connection dropped" : "Not connected"
        case .busy: return "Changing state…"
        case .unknown: return "Checking…"
        }
    }
    var subtitle: String {
        if activity != nil { return "Signing in to \(host)" }
        if connected { return "Your traffic goes through BTU" }
        if dropped { return autoReconnect ? "Reconnecting automatically…" : "Reconnect when you are ready" }
        return "Your traffic goes out directly"
    }
}

struct CardView: View {
    @ObservedObject var m: VPNModel
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            hero
            details
            actions
        }
        .padding(16)
        .frame(width: 304)
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("BTU VPN").font(.system(size: 13, weight: .semibold))
                Text(m.host).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Credentials…", systemImage: "key", action: m.onCredentials)
                Toggle("Launch at Login", systemImage: "power", isOn: Binding(get: { m.launchAtLogin }, set: { _ in m.onLaunchAtLogin() }))
                if let ip = m.ip, m.connected {
                    Button("Copy IP Address", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                    }
                }
                Button("Show Log", systemImage: "list.bullet.rectangle", action: m.onOpenLog)
                Divider()
                Button("Quit VPNToggle", systemImage: "xmark.circle") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// A Control Center style orb: tap it to toggle, like the Wi-Fi button.
    var hero: some View {
        VStack(spacing: 0) {
            Button(action: m.onToggle) {
                ZStack {
                    if m.activity != nil {
                        ProgressView().controlSize(.regular)
                    } else {
                        Image(systemName: m.symbol)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(m.state == .connected || m.dropped ? .white : .primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 84, height: 84)
                .glassEffect(m.connected || m.dropped ? .regular.tint(m.tint).interactive() : .regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(m.activity != nil)
            .background(
                Circle()
                    .fill(m.tint.opacity(m.connected ? 0.38 : 0))
                    .frame(width: 84, height: 84)
                    .blur(radius: 26)
                    .scaleEffect(glow && !reduceMotion ? 1.25 : 1.0)
                    .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: glow)
            )
            .onAppear { glow = true }
            .padding(.top, 22)

            Text(m.title)
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.3), value: m.title)
    }

    func row(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit().textSelection(.enabled)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    var details: some View {
        VStack(spacing: 0) {
            if m.connected {
                row("network", "IP address", m.ip ?? "—")
                row("clock", "Connected for", m.duration ?? "—")
            }
            row("key", "Two-factor", m.autoTwoFactor ? "Automatic" : "Asks for code")
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Auto-reconnect").foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { m.autoReconnect }, set: { _ in m.onAutoReconnect() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.top, 18)
    }

    var actions: some View {
        VStack(spacing: 8) {
            Button(action: m.onToggle) {
                Text(m.connected ? "Disconnect" : (m.dropped ? "Reconnect now" : "Connect"))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(m.connected ? Color(red: 0.92, green: 0.27, blue: 0.27) : .accentColor)
            .controlSize(.large)
            .disabled(m.activity != nil)
            .keyboardShortcut(.defaultAction)

        }
        .padding(.top, 16)
    }
}

/// The hover peek: a coloured dot, the state and one line of detail.
struct HoverView: View {
    @ObservedObject var m: VPNModel

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(m.tint).frame(width: 8, height: 8).shadow(color: m.tint.opacity(0.8), radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.connected ? "VPN connected" : m.title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
    }

    var detail: String {
        if m.connected { return [m.ip, m.duration.map { "for \($0)" }].compactMap { $0 }.joined(separator: " · ") }
        return m.activity != nil ? "Please wait" : (m.dropped ? m.subtitle : "Click for details")
    }
}

// MARK: - Launch at login (a LaunchAgent, so it works for this ad-hoc signed app)

enum LoginItem {
    static let path = NSHomeDirectory() + "/Library/LaunchAgents/com.alwinpaul.vpntoggle.plist"
    static var enabled: Bool { FileManager.default.fileExists(atPath: path) }

    static func set(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": "com.alwinpaul.vpntoggle",
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            (plist as NSDictionary).write(toFile: path, atomically: true)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let qrPicker = QRPicker()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let model = VPNModel()
    lazy var card = FloatingPanel(content: NSHostingView(rootView: CardView(m: model)), cornerRadius: 26)
    lazy var hover = HoverController(
        panel: FloatingPanel(content: NSHostingView(rootView: HoverView(m: model)), cornerRadius: 16),
        iconFrame: { [weak self] in self?.iconFrame })
    var clickMonitor: Any?

    /// The icon's rectangle on screen; empty until the menu bar has placed it.
    var iconFrame: NSRect? {
        guard let b = item.button, let w = b.window else { return nil }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }
    var state: VPNState = .unknown
    var info: (ip: String?, duration: String?) = (nil, nil)
    /// True from a successful connect until the user disconnects; a drop in between triggers a reconnect.
    var wantConnected = false
    var reconnectAttempts = 0
    var reconnectTimer: Timer?
    var autoReconnect: Bool { Prefs.d.object(forKey: "autoReconnect") as? Bool ?? true }
    var working = false
    var activity: String?
    let queue = DispatchQueue(label: "vpn")

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// vpntoggle://connect, vpntoggle://disconnect, vpntoggle://toggle (for Shortcuts, Raycast, the terminal).
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard !working, let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let action = URL(string: s)?.host else { return }
        if action == "debug" {
            let b = item.button
            logEvent("debug: button \(b != nil), window \(b?.window != nil), frame \(b?.window?.frame ?? .zero), visible \(item.isVisible)")
            return
        }
        if action == "show" {
            if let q = URL(string: s)?.query, q.hasPrefix("appearance=") {
                card.appearance = NSAppearance(named: q.hasSuffix("dark") ? .darkAqua : .aqua)
            }
            openCard()
            return
        }
        state = currentState()
        render()
        switch action {
        case "connect" where state != .connected, "disconnect" where state == .connected, "toggle": toggle()
        default: break
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        model.onToggle = { [weak self] in self?.toggle() }
        model.onCredentials = { [weak self] in self?.closeCard(); self?.editCredentials() }
        model.onAutoReconnect = { [weak self] in self?.toggleAutoReconnect() }
        model.onLaunchAtLogin = { [weak self] in
            LoginItem.set(!LoginItem.enabled)
            self?.model.launchAtLogin = LoginItem.enabled
        }
        model.onOpenLog = { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/VPNToggle.log")) }

        hover.blocked = { [weak self] in self?.card.isVisible ?? false }
        render()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        // Cisco drops the tunnel on sleep; check soon after wake so a reconnect starts quickly.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self?.refresh() }
        }
        logEvent("app started")
        Notify.setUp(delegate: self)
        if Keychain.get("password") == nil { editCredentials() }
    }

    // A click opens (or closes) the card.
    @objc func clicked() {
        hover.suppressed = true
        hover.hide()
        if card.isVisible { closeCard(); return }
        openCard()
    }

    func openCard() {
        guard let f = iconFrame else { return }
        model.launchAtLogin = LoginItem.enabled
        model.autoReconnect = autoReconnect
        model.autoTwoFactor = Keychain.get("totp") != nil
        refresh()
        hover.hide()
        card.show(under: f, makeKey: true)
        // Close on a click anywhere else, like a menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeCard()
        }
    }

    func closeCard() {
        card.dismiss()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // Show banners even though the app is (as a menu bar app) rarely frontmost.
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func toggleAutoReconnect() {
        Prefs.d.set(!autoReconnect, forKey: "autoReconnect")
        model.autoReconnect = autoReconnect
        logEvent("auto-reconnect \(autoReconnect ? "on" : "off")")
    }

    func refresh() {
        guard !working else { return }
        queue.async {
            let s = currentState()
            let info = s == .connected ? connectionInfo() : (nil, nil)
            DispatchQueue.main.async {
                guard !self.working else { return }
                if s != self.state && self.state != .unknown { logEvent("state \(self.state) -> \(s)") }
                if self.state == .connected && s == .disconnected && self.wantConnected {
                    Notify.post("VPN dropped", self.autoReconnect ? "Reconnecting to \(Prefs.host)…" : "Click the menu bar icon to reconnect.")
                }
                // A tunnel already up when the app starts (after a restart, or made by the Cisco GUI) is kept up too.
                if self.state == .unknown && s == .connected { self.wantConnected = true }
                self.state = s
                self.info = info
                self.render()
                if s == .disconnected && self.wantConnected && self.autoReconnect && self.reconnectTimer == nil {
                    self.scheduleReconnect()
                }
            }
        }
    }

    func render() {
        let dropped = wantConnected && state != .connected
        let (symbol, text): (String, String) = working ? ("ellipsis.circle", activity ?? "Working…") : {
            switch state {
            case .connected: return ("lock.shield.fill", "VPN: Connected")
            case .disconnected: return dropped ? ("exclamationmark.shield", "VPN: Dropped") : ("lock.open", "VPN: Disconnected")
            case .busy: return ("ellipsis.circle", "VPN: Changing state…")
            case .unknown: return ("questionmark.circle", "VPN: Unknown")
            }
        }()
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        img?.isTemplate = true  // follows the light/dark menu bar automatically
        item.button?.image = img

        model.state = state
        model.activity = working ? (activity ?? "Working…") : nil
        model.ip = info.ip
        model.duration = info.duration
        model.dropped = dropped
        model.autoReconnect = autoReconnect
    }

    func toggle() {
        guard !working else { return }
        if state == .connected { disconnect() } else { connectNow(auto: false) }
    }

    func disconnect() {
        logEvent("disconnect requested by user")
        wantConnected = false
        cancelReconnect()
        activity = "Disconnecting…"
        run({ (true, nil, runVPN(["disconnect"])) })
    }

    func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
    }

    /// Backs off 5 s, 30 s, 2 min, 5 min, then gives up and says so.
    func scheduleReconnect() {
        let delays: [TimeInterval] = [5, 30, 120, 300]
        guard reconnectAttempts < delays.count else {
            logEvent("auto-reconnect gave up after \(reconnectAttempts) attempts")
            wantConnected = false
            cancelReconnect()
            render()
            showError("The VPN dropped and \(delays.count) reconnect attempts failed.", title: "VPN disconnected")
            return
        }
        let delay = delays[reconnectAttempts]
        reconnectAttempts += 1
        logEvent("dropped; reconnect attempt \(reconnectAttempts) in \(Int(delay)) s")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.reconnectTimer = nil
            guard self.wantConnected, !self.working else { return }
            if currentState() == .connected { self.cancelReconnect(); self.refresh(); return }
            self.connectNow(auto: true)
        }
        render()
    }

    func connectNow(auto: Bool) {
        guard !working else { return }
        logEvent(auto ? "reconnecting (attempt \(reconnectAttempts))" : "connect requested by user")
        if !auto { cancelReconnect() }
        guard let password = Keychain.get("password"), !Prefs.username.isEmpty else { editCredentials(); return }
        let pin = Keychain.get("pin")
        let totp = Keychain.get("totp").flatMap(TOTP.secretBytes)
        let (host, group, user) = (Prefs.host, Prefs.group, Prefs.username)
        // The Cisco GUI blocks CLI connects ("Another AnyConnect application is running").
        for id in ciscoGUIBundleIDs {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
        }
        activity = auto ? "Reconnecting…" : "Connecting…"
        run {
            usleep(800_000)  // let the GUI quit first, or it rewrites the preference on exit
            Prefs.setCiscoDefaultGroup(group)
            let r = connect(host: host, group: group, user: user, password: password, pin: pin, totpSecret: totp)
            return (r.ok, r.message, r.log)
        } done: { ok, message in
            logEvent(ok ? "connected" : "connect failed: \(message ?? "cancelled")")
            if ok {
                self.wantConnected = true
                self.cancelReconnect()
                self.queue.async {
                    let ip = connectionInfo().ip
                    Notify.post(auto ? "VPN reconnected" : "VPN connected",
                                [Prefs.host, ip].compactMap { $0 }.joined(separator: " · "))
                }
            } else if !auto || message == nil || message!.hasPrefix("Login rejected") {
                // A manual failure, a cancel or a wrong password: retrying would not help.
                self.wantConnected = false
                self.cancelReconnect()
            } else {
                self.scheduleReconnect()
            }
        }
    }

    func run(_ job: @escaping () -> (ok: Bool, message: String?, log: String),
             done: ((Bool, String?) -> Void)? = nil) {
        working = true
        render()
        queue.async {
            let (ok, message, log) = job()
            let s = currentState()
            DispatchQueue.main.async {
                self.working = false
                self.state = s
                done?(ok, message)
                self.render()
                self.refresh()
                // Auto-reconnect failures stay quiet until it gives up.
                if !ok, let message, self.reconnectTimer == nil { self.showError(message, details: log) }
            }
        }
    }

    /// One line for the user; the full CLI log only goes to the clipboard on request.
    func showError(_ message: String, title: String = "VPN connection failed", details: String? = nil) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        if let details, !details.isEmpty { a.addButton(withTitle: "Copy Details") }
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn, let details {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details, forType: .string)
        }
    }

    @objc func editCredentials() {
        func field(_ value: String, secure: Bool, placeholder: String) -> NSTextField {
            let f = secure ? NSSecureTextField() : NSTextField()
            f.stringValue = value
            f.placeholderString = placeholder
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
            return f
        }
        let host = field(Prefs.host, secure: false, placeholder: "vpn-gate.b-tu.de")
        let group = field(Prefs.group, secure: false, placeholder: "Anmeldung mit BTU-Account")
        let user = field(Prefs.username, secure: false, placeholder: "username")
        let pass = field(Keychain.get("password") ?? "", secure: true, placeholder: "password")
        let pin = field(Keychain.get("pin") ?? "", secure: true, placeholder: "static PIN, if any")
        let totp = field(Keychain.get("totp") ?? "", secure: true, placeholder: "base32 secret or otpauth:// URI")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Server"), host],
            [NSTextField(labelWithString: "Group"), group],
            [NSTextField(labelWithString: "Username"), user],
            [NSTextField(labelWithString: "Password"), pass],
            [NSTextField(labelWithString: "PIN"), pin],
            [NSTextField(labelWithString: "2FA secret"), totp],
            [NSGridCell.emptyContentView, qrPicker.buttons(for: totp)],
        ])
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 400, height: 230)

        let a = NSAlert()
        a.messageText = "VPN Credentials"
        a.informativeText = "Secrets are stored in your macOS Keychain. Fill in the 2FA secret only if the login asks for a changing code; the app then generates that code itself."
        a.accessoryView = grid
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = pass
        guard a.runModal() == .alertFirstButtonReturn else { return }

        Prefs.d.set(host.stringValue.trimmingCharacters(in: .whitespaces), forKey: "host")
        Prefs.d.set(group.stringValue.trimmingCharacters(in: .whitespaces), forKey: "group")
        Prefs.d.set(user.stringValue.trimmingCharacters(in: .whitespaces), forKey: "username")
        Keychain.set("password", pass.stringValue)
        Keychain.set("pin", pin.stringValue)
        let secret = totp.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty && TOTP.secretBytes(secret) == nil {
            showError("It must be base32, an otpauth:// link or a Google Authenticator export. It was not saved.", title: "Invalid 2FA secret")
        } else {
            Keychain.set("totp", secret)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
