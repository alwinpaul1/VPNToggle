import Foundation

enum NVMPauseTests {
    static func run() {
        let check: (String, String?, String?) -> Void = { ConnectPolicyTests.check($0, $1, $2) }
        let flag: (String, Bool, Bool) -> Void = { ConnectPolicyTests.check($0, $1, $2) }

        flag("pause: nothing installed is off", NVMPause.status(plistInstalled: false, daemonLoaded: false) == .off, true)
        flag("pause: loaded daemon is active", NVMPause.status(plistInstalled: true, daemonLoaded: true) == .active, true)
        flag("pause: loaded daemon counts even without the file", NVMPause.status(plistInstalled: false, daemonLoaded: true) == .active, true)
        flag("pause: file without a loaded daemon is not running", NVMPause.status(plistInstalled: true, daemonLoaded: false) == .notRunning, true)
        flag("pause: off installs", NVMPause.installs(from: .off), true)
        flag("pause: active uninstalls", NVMPause.installs(from: .active), false)
        flag("pause: not running uninstalls", NVMPause.installs(from: .notRunning), false)
        check("pause: note when off", NVMPause.note(.off), NVMPause.summary)
        flag("pause: note says active", NVMPause.note(.active).hasPrefix("Running"), true)
        flag("pause: summary names the saving and the lost reports",
             NVMPause.summary.contains("CPU core") && NVMPause.summary.contains("stops usage reports"), true)

        check("pause: plain path quoted", NVMPause.shellQuoted("/a/b c"), "'/a/b c'")
        check("pause: apostrophe in a path quoted", NVMPause.shellQuoted("/Users/o'neil/x"), "'/Users/o'\\''neil/x'")
        check("pause: install script",
              NVMPause.appleScript(directory: "/Apps/VPN Toggle.app/Contents/Resources/nvm-pause", install: true),
              "do shell script \"/bin/sh '/Apps/VPN Toggle.app/Contents/Resources/nvm-pause/install.sh'\" with administrator privileges")
        check("pause: uninstall script",
              NVMPause.appleScript(directory: "/r", install: false),
              "do shell script \"/bin/sh '/r/uninstall.sh'\" with administrator privileges")
        check("pause: quotes and backslashes cannot end the AppleScript string",
              NVMPause.appleScript(directory: "/a\"b\\c", install: true),
              "do shell script \"/bin/sh '/a\\\"b\\\\c/install.sh'\" with administrator privileges")

        check("pause: success has no message", NVMPause.failure(exitCode: 0, output: "installed\n"), nil)
        check("pause: a cancelled prompt has no message",
              NVMPause.failure(exitCode: 1, output: "0:95: execution error: User canceled. (-128)\n"), nil)
        check("pause: an error keeps its last line",
              NVMPause.failure(exitCode: 1, output: "first\nexecution error: Bootstrap failed: 5\n"), "execution error: Bootstrap failed: 5")
        check("pause: an error without output", NVMPause.failure(exitCode: 1, output: ""), "The change did not complete.")

        let script = NVMPause.appleScript(directory: "/tmp/it's here/nvm-pause", install: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        let out = NSTemporaryDirectory() + "vpntoggle-test-\(UUID().uuidString).scpt"
        p.arguments = ["-e", script, "-o", out]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            flag("pause: the AppleScript compiles", p.terminationStatus == 0, true)
        }
        try? FileManager.default.removeItem(atPath: out)
    }
}
