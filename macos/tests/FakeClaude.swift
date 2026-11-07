// A stand-in for Claude.app in tests: records how it was started, then stays open as a
// regular app with one window until it is quit, like the real one.
import AppKit

let logPath = ProcessInfo.processInfo.environment["FAKE_CLAUDE_LOG_OVERRIDE"] ?? "/tmp/fake-claude.log"
let args = CommandLine.arguments.dropFirst().joined(separator: "|")
let peer = ProcessInfo.processInfo.environment["MY_PEER"] ?? ""
func record(_ line: String) {
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}
record("pid=\(getpid()) args=[\(args)] MY_PEER=[\(peer)]\n")

final class Delegate: NSObject, NSApplicationDelegate {
    // A claude:// link arrives as this Apple Event, as it does for Electron's open-url.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(getURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    @objc func getURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        record("pid=\(getpid()) url=[\(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue ?? "")]\n")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
let w = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 320, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
w.title = "Fake Claude"
w.makeKeyAndOrderFront(nil)
app.run()
