import Foundation

enum StatusSession {
    static func read(cli: String, timeout: TimeInterval = StatusPolicy.sessionTimeout,
                     onStart: (Process) -> Void = { _ in },
                     onState: (VPNState, TimeInterval) -> Void = { _, _ in }) -> (reading: StatusReading, requests: Int)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-s"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        signal(SIGPIPE, SIG_IGN)
        let started = Date()
        do { try p.run() } catch { return nil }
        onStart(p)
        let stdin = input.fileHandleForWriting
        func send() { _ = StatusPolicy.sessionRequest.withCString { write(stdin.fileDescriptor, $0, strlen($0)) } }
        send()
        let lock = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard p.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        var text = ""
        var announced = false, open = true
        var sent = 1
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
            if !announced, let state = StatusPolicy.registeredState(inSession: text) {
                announced = true
                onState(state, Date().timeIntervalSince(started))
            }
            guard open else { continue }
            switch StatusPolicy.sessionStep(output: text, sent: sent) {
            case .wait: break
            case .askAgain: sent += 1; send()
            case .done: open = false; try? stdin.close()
            }
        }
        if open { try? stdin.close() }
        p.waitUntilExit()
        watchdog.cancel()
        lock.lock(); let late = timedOut; lock.unlock()
        if late || p.terminationReason == .uncaughtSignal { return nil }
        return (StatusPolicy.reading(fromSession: text), sent)
    }
}
