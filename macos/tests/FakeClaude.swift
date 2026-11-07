// A stand-in for Claude.app in tests: records how it was started, then stays open as a
// regular app with one window until it is quit, like the real one.
import AppKit

let logPath = ProcessInfo.processInfo.environment["FAKE_CLAUDE_LOG_OVERRIDE"] ?? "/tmp/fake-claude.log"
let args = CommandLine.arguments.dropFirst().joined(separator: "|")
let peer = ProcessInfo.processInfo.environment["MY_PEER"] ?? ""
let line = "pid=\(getpid()) args=[\(args)] MY_PEER=[\(peer)]\n"
if let h = FileHandle(forWritingAtPath: logPath) {
    h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
} else {
    FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
}

final class Delegate: NSObject, NSApplicationDelegate {
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
