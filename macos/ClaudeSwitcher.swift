// Claude Profile Switcher for macOS: run several Claude desktop accounts side by side.
//
// The Claude desktop app is built on Electron, which honours --user-data-dir. Each
// profile is a folder of its own, so each is an independent login, and copies started
// against different folders run at the same time. This app is a menu bar item and a
// small window around that, plus a command line for scripts.
//
// One file, AppKit only, no dependencies. Build with macos/build.sh.

import AppKit
import Foundation

let switcherVersion = "2.3.0"
let defaultID = "Default"

struct SwitcherError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Where things live

enum Loc {
    /// ~/Library/Application Support, or a folder of the tests' choosing.
    static var support: URL {
        if let o = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_SUPPORT_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    /// Extra profiles, and the switcher's settings.json next to them.
    static var profileRoot: URL { support.appendingPathComponent("ClaudeProfiles", isDirectory: true) }
    static var settingsFile: URL { profileRoot.appendingPathComponent("settings.json") }
    /// Where Claude keeps the original account. Never touched.
    static var defaultData: URL { support.appendingPathComponent("Claude", isDirectory: true) }
    static func profileDir(_ id: String) -> URL { profileRoot.appendingPathComponent(id, isDirectory: true) }
}

// MARK: - settings.json (same keys as the Windows switcher)

enum Settings {
    static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: Loc.settingsFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    static func save(_ dict: [String: Any]) throws {
        try FileManager.default.createDirectory(at: Loc.profileRoot, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Loc.settingsFile, options: .atomic)
    }

    static func map(_ key: String) -> [String: Any] { load()[key] as? [String: Any] ?? [:] }

    static func set(_ key: String, _ value: Any?) throws {
        var all = load()
        if let value = value { all[key] = value } else { all.removeValue(forKey: key) }
        try save(all)
    }

    static func setEntry(_ key: String, id: String, value: Any?) throws {
        var all = load()
        var m = all[key] as? [String: Any] ?? [:]
        if let value = value { m[id] = value } else { m.removeValue(forKey: id) }
        all[key] = m
        try save(all)
    }
}

// MARK: - Finding Claude

enum ClaudeApp {
    static let bundleID = "com.anthropic.claudefordesktop"

    static func find() -> URL? {
        let fm = FileManager.default
        if let o = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_APP"], !o.isEmpty {
            return URL(fileURLWithPath: o)
        }
        if let saved = Settings.load()["ClaudePath"] as? String, fm.fileExists(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return u }
        for p in ["/Applications/Claude.app", NSHomeDirectory() + "/Applications/Claude.app"] where fm.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    static func require() throws -> URL {
        if let u = find() { return u }
        throw SwitcherError("Could not find Claude.app. Install the Claude desktop app, or point at it once with --claude-path /path/to/Claude.app.")
    }

    /// The main executable inside the bundle, which is what a running copy's command line starts with.
    static func executable(of app: URL) -> String {
        let name = (Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String) ?? "Claude"
        return app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(name).path
    }

    static func version(of app: URL) -> String {
        (Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }
}

// MARK: - Profiles

struct Profile {
    let id: String
    let name: String
    let dataDir: URL
    var pid: pid_t?
    var isDefault: Bool { id == defaultID }
}

enum Profiles {
    static func labels() -> [String: String] { Settings.map("Labels").compactMapValues { $0 as? String } }

    static func ids() -> [String] {
        var ids = [defaultID]
        let items = (try? FileManager.default.contentsOfDirectory(at: Loc.profileRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let dirs = items.filter { u in
            (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !u.lastPathComponent.hasPrefix(".")
        }.map { $0.lastPathComponent }
        ids += dirs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ids
    }

    static func dataDir(_ id: String) -> URL { id == defaultID ? Loc.defaultData : Loc.profileDir(id) }

    static func list(status: Bool = true) -> [Profile] {
        let labels = self.labels()
        let ids = self.ids()
        let running = status ? Processes.runningMap(profileIDs: ids) : [:]
        return ids.map { Profile(id: $0, name: labels[$0] ?? $0, dataDir: dataDir($0), pid: running[$0]) }
    }

    /// By folder id first, then by name, then by name ignoring case.
    static func resolve(_ name: String, status: Bool = true) -> Profile? {
        let all = list(status: status)
        return all.first { $0.id == name }
            ?? all.first { $0.name == name }
            ?? all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func resolveOrThrow(_ name: String) throws -> Profile {
        if let p = resolve(name) { return p }
        let known = list(status: false).map { $0.name }.joined(separator: ", ")
        throw SwitcherError("There is no Claude profile called '\(name)'. Profiles: \(known)")
    }

    static func validate(name raw: String, except: String?) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Name cannot be empty." }
        if name.count > 40 { return "Name is too long (40 characters max)." }
        if name.hasPrefix(".") || name.contains("/") || name.contains(":") { return "Name cannot start with a dot or contain / or :." }
        for p in list(status: false) where p.id != except {
            if p.id == name || p.name == name { return "A profile named '\(name)' already exists." }
        }
        if except == nil, FileManager.default.fileExists(atPath: Loc.profileDir(name).path) {
            return "'\(name)' is already taken in \(Loc.profileRoot.path)."
        }
        return nil
    }

    /// New accounts start out numbered after Default and can be renamed once signed in.
    static func nextAccountName() -> String {
        var n = 2
        while validate(name: "Account \(n)", except: nil) != nil { n += 1 }
        return "Account \(n)"
    }
}

// MARK: - Running copies

enum Processes {
    static func psLines() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,args="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Profile id to the pid of its main Claude process. Electron's helpers live under
    /// Contents/Frameworks and carry --type=, so they never match. ps does not quote
    /// arguments, and Application Support has a space in it, so each profile is found by
    /// its exact --user-data-dir= text followed by a space or the end of the line.
    static func runningMap(profileIDs: [String]) -> [String: pid_t] {
        guard let app = ClaudeApp.find() else { return [:] }
        // ps shows the path the kernel resolved, so /var/... appears as /private/var/...;
        // either spelling counts. realpath(3), because Foundation's resolvingSymlinksInPath
        // strips a leading /private again on purpose.
        let given = ClaudeApp.executable(of: app)
        var exes = [given]
        if let r = realpath(given, nil) { exes.append(String(cString: r)); free(r) }
        let flags = profileIDs.filter { $0 != defaultID }.map { ($0, "--user-data-dir=" + Loc.profileDir($0).path) }
        var map: [String: pid_t] = [:]
        for line in psLines() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let space = t.firstIndex(of: " "), let pid = pid_t(t[..<space]) else { continue }
            let args = String(t[t.index(after: space)...])
            guard exes.contains(where: { args == $0 || args.hasPrefix($0 + " ") }), !args.contains("--type=") else { continue }
            if let hit = flags.first(where: { args.contains($0.1 + " ") || args.hasSuffix($0.1) }) {
                if map[hit.0] == nil { map[hit.0] = pid }
            } else if !args.contains("--user-data-dir=") {
                if map[defaultID] == nil { map[defaultID] = pid }
            }
        }
        return map
    }

    static func alive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

// MARK: - Launching and quitting

enum Launcher {
    /// "--a 'b c' \"d e\"" to ["--a", "b c", "d e"].
    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        var any = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; any = true
            } else if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                if any || !cur.isEmpty { out.append(cur); cur = ""; any = false }
            } else {
                cur.append(ch); any = true
            }
        }
        if any || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// ProfileArgs: a string as typed, or a list of arguments.
    static func extraArgs(_ id: String) -> [String] {
        let v = Settings.map("ProfileArgs")[id]
        if let a = v as? [Any] { return a.map { "\($0)" } }
        if let s = v as? String { return splitArgs(s) }
        return []
    }

    /// ProfileEnv, with invalid names skipped.
    static func env(_ id: String) -> [(String, String)] {
        guard let m = Settings.map("ProfileEnv")[id] as? [String: Any] else { return [] }
        return m.keys.sorted().compactMap { k in
            guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, let v = m[k] else { return nil }
            return (k, "\(v)")
        }
    }

    /// Through `open`, so Launch Services starts Claude as an app of its own: it outlives
    /// a closed Terminal, and each account gets its own Dock icon. Always -n: without it,
    /// Launch Services only brings forward whichever copy of Claude is already running,
    /// which may be another account. Only an account found not running is started.
    static func openArguments(app: URL, profile: Profile) -> [String] {
        var a = ["-n", "-a", app.path]
        for (k, v) in env(profile.id) { a += ["--env", "\(k)=\(v)"] }
        var pass = profile.isDefault ? [] : ["--user-data-dir=\(profile.dataDir.path)"]
        pass += extraArgs(profile.id)
        if !pass.isEmpty { a += ["--args"] + pass }
        return a
    }

    /// Returns "focused" when the account was already open, "started" otherwise.
    @discardableResult
    static func start(_ profile: Profile) throws -> String {
        if let pid = profile.pid {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            return "focused"
        }
        let app = try ClaudeApp.require()
        if !profile.isDefault {
            try FileManager.default.createDirectory(at: profile.dataDir, withIntermediateDirectories: true)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = openArguments(app: app, profile: profile)
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SwitcherError("Could not open Claude for '\(profile.name)': \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return "started"
    }

    /// Quits one account's Claude: a normal quit first, then a forced one. Returns false
    /// when it was not open, and throws when it would not go.
    @discardableResult
    static func stop(_ profile: Profile, grace: TimeInterval = 6) throws -> Bool {
        guard let pid = profile.pid else { return false }
        if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() } else { kill(pid, SIGTERM) }
        if waitGone(pid, grace) { return true }
        if let app = NSRunningApplication(processIdentifier: pid) { app.forceTerminate() } else { kill(pid, SIGKILL) }
        if waitGone(pid, 4) { return true }
        throw SwitcherError("macOS would not let the switcher quit '\(profile.name)' (process \(pid)).")
    }

    static func waitGone(_ pid: pid_t, _ seconds: TimeInterval) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if !Processes.alive(pid) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return !Processes.alive(pid)
    }
}

// MARK: - Account operations

enum Accounts {
    static func add() throws -> Profile {
        let name = Profiles.nextAccountName()
        let dir = Loc.profileDir(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Profile(id: name, name: name, dataDir: dir, pid: nil)
        try Launcher.start(p)
        return p
    }

    /// Changes the label only. The folder is the profile's permanent id, because Electron
    /// keeps absolute paths inside its data.
    static func rename(_ p: Profile, to raw: String) throws {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let e = Profiles.validate(name: name, except: p.id) { throw SwitcherError(e) }
        try Settings.setEntry("Labels", id: p.id, value: name == p.id ? nil : name)
    }

    static func delete(_ p: Profile) throws {
        if p.isDefault { throw SwitcherError("The Default profile is your original Claude and cannot be deleted here.") }
        let dir = p.dataDir.standardizedFileURL
        // Never anything but a direct child of our own folder.
        guard dir.deletingLastPathComponent().standardizedFileURL.path == Loc.profileRoot.standardizedFileURL.path,
              !p.id.hasPrefix("."), !p.id.contains("/") else {
            throw SwitcherError("Refusing to delete \(dir.path).")
        }
        if p.pid != nil { try Launcher.stop(p) }
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        for key in ["Labels", "Colors", "ChosenColors", "ProfileArgs", "ProfileEnv"] {
            try? Settings.setEntry(key, id: p.id, value: nil)
        }
    }
}

// MARK: - Colours and badges

enum Palette {
    static let rgb: [(CGFloat, CGFloat, CGFloat)] = [
        (66, 133, 180), (76, 150, 96), (150, 96, 180), (190, 80, 110),
        (60, 150, 150), (90, 110, 200), (200, 150, 50), (80, 86, 100)]

    static func color(_ i: Int) -> NSColor {
        let c = rgb[i % rgb.count]
        return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
    }

    /// A colour picked by the user, else one assigned once, the least used, and kept.
    static func index(for id: String) -> Int {
        if let v = Settings.map("ChosenColors")[id] as? Int { return v % rgb.count }
        var assigned = Settings.map("Colors").compactMapValues { $0 as? Int }
        if let v = assigned[id] { return v % rgb.count }
        let alive = Set(Profiles.ids())
        var use = Array(repeating: 0, count: rgb.count)
        for (k, v) in assigned where alive.contains(k) { use[v % rgb.count] += 1 }
        let pick = use.indices.min { use[$0] < use[$1] } ?? 0
        assigned[id] = pick
        try? Settings.set("Colors", assigned)
        return pick
    }

    static func letter(_ name: String) -> String {
        if let c = name.first(where: { $0.isLetter || $0.isNumber }) { return String(c).uppercased() }
        return String(name.prefix(1)).uppercased()
    }

    static func badge(for p: Profile, size: CGFloat) -> NSImage {
        let fill = p.isDefault ? NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1) : color(index(for: p.id))
        return badge(letter: letter(p.name), fill: fill, size: size)
    }

    static func badge(letter: String, fill: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            fill.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            let font = NSFont.systemFont(ofSize: size * 0.48, weight: .semibold)
            let s = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: NSPoint(x: (r.width - sz.width) / 2, y: (r.height - sz.height) / 2))
            return true
        }
    }

    /// The app's own icon: two overlapping account badges on a dark tile.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let tile = r.insetBy(dx: size * 0.1, dy: size * 0.1)
            NSColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22).fill()
            let d = tile.width * 0.5
            let back = NSRect(x: tile.minX + tile.width * 0.14, y: tile.minY + tile.height * 0.30, width: d, height: d)
            let front = NSRect(x: tile.maxX - tile.width * 0.14 - d, y: tile.minY + tile.height * 0.20, width: d, height: d)
            color(0).setFill(); NSBezierPath(ovalIn: back).fill()
            NSColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 1).setFill()
            NSBezierPath(ovalIn: front.insetBy(dx: -tile.width * 0.035, dy: -tile.width * 0.035)).fill()
            color(1).setFill(); NSBezierPath(ovalIn: front).fill()
            return true
        }
    }

    static func png(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - The accounts window

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class AccountsWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let rows = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var signature = ""
    private var timer: Timer?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 430),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Claude Profile Switcher"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)
        window.delegate = self
        build()
        refresh(force: true)
        window.center()
    }

    private func build() {
        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "Claude accounts")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let sub = NSTextField(labelWithString: "Each account is a separate login, and several can be open at once.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rows)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = doc

        let add = NSButton(title: "Add Account", target: self, action: #selector(addAccount))
        add.bezelStyle = .rounded
        add.keyEquivalent = "n"
        add.keyEquivalentModifierMask = [.command]
        add.toolTip = "Opens Claude at a fresh sign-in screen for another account (Command-N)"
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        for v in [title, sub, scroll, add, statusLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -12),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            rows.topAnchor.constraint(equalTo: doc.topAnchor),
            rows.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            add.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            add.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            statusLabel.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: add.centerYAnchor),
        ])
    }

    func show() {
        refresh(force: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh(force: false) }
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    func refresh(force: Bool) {
        let profiles = Profiles.list()
        let sig = profiles.map { "\($0.id)|\($0.name)|\($0.pid.map { String($0) } ?? "")" }.joined(separator: ";")
        if !force && sig == signature { return }
        signature = sig
        for v in rows.arrangedSubviews { rows.removeArrangedSubview(v); v.removeFromSuperview() }
        for p in profiles {
            let row = makeRow(p)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let open = profiles.filter { $0.pid != nil }.count
        let claude = ClaudeApp.find().map { "Claude \(ClaudeApp.version(of: $0))" } ?? "Claude not found"
        statusLabel.stringValue = "\(profiles.count) accounts, \(open) open   |   \(claude)   |   Switcher \(switcherVersion)"
    }

    private func makeRow(_ p: Profile) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let badge = NSImageView(image: Palette.badge(for: p, size: 30))
        let name = NSTextField(labelWithString: p.name)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        var detailText = p.pid != nil ? "Open" : "Not open"
        if p.isDefault { detailText += "  ·  your original" } else if p.name != p.id { detailText += "  ·  folder: \(p.id)" }
        let detail = NSTextField(labelWithString: detailText)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = p.pid != nil ? .systemGreen : .secondaryLabelColor

        let open = NSButton(title: p.pid != nil ? "Switch to" : "Open", target: self, action: #selector(openProfile(_:)))
        open.bezelStyle = .rounded
        open.identifier = NSUserInterfaceItemIdentifier(p.id)
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitProfile(_:)))
        quit.bezelStyle = .rounded
        quit.isEnabled = p.pid != nil
        quit.identifier = NSUserInterfaceItemIdentifier(p.id)
        let more = NSButton(title: "More", target: self, action: #selector(moreMenu(_:)))
        more.bezelStyle = .rounded
        more.identifier = NSUserInterfaceItemIdentifier(p.id)
        if let img = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More") {
            more.image = img; more.imagePosition = .imageOnly
        }
        let line = NSBox()
        line.boxType = .separator

        for v in [badge, name, detail, open, quit, more, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 56),
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            name.bottomAnchor.constraint(equalTo: row.centerYAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: row.centerYAnchor, constant: 2),
            more.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            more.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            quit.trailingAnchor.constraint(equalTo: more.leadingAnchor, constant: -6),
            quit.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            open.trailingAnchor.constraint(equalTo: quit.leadingAnchor, constant: -6),
            open.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            open.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            name.trailingAnchor.constraint(lessThanOrEqualTo: open.leadingAnchor, constant: -10),
            line.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func profile(from sender: Any?) -> Profile? {
        guard let id = (sender as? NSView)?.identifier?.rawValue ?? (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        return Profiles.resolve(id)
    }

    private func report(_ text: String) { statusLabel.stringValue = text }

    private func showError(_ error: Error, title: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning
        a.runModal()
    }

    @objc func addAccount() {
        do {
            let p = try Accounts.add()
            refresh(force: true)
            report("Sign in to '\(p.name)' in the new Claude window, then rename it from More.")
        } catch { showError(error, title: "Could not add an account") }
    }

    @objc func openProfile(_ sender: Any?) {
        guard let p = profile(from: sender) else { return }
        do {
            let how = try Launcher.start(p)
            report(how == "focused" ? "Switched to '\(p.name)'." : "Opening '\(p.name)'...")
        } catch { showError(error, title: "Could not open") }
    }

    @objc func quitProfile(_ sender: Any?) {
        guard let p = profile(from: sender) else { return }
        do {
            try Launcher.stop(p)
            refresh(force: true)
            report("Quit '\(p.name)'.")
        } catch { showError(error, title: "Could not quit") }
    }

    @objc func moreMenu(_ sender: NSButton) {
        guard let p = profile(from: sender) else { return }
        let m = NSMenu()
        let rename = NSMenuItem(title: "Rename...", action: #selector(renameProfile(_:)), keyEquivalent: "")
        let restart = NSMenuItem(title: "Restart", action: #selector(restartProfile(_:)), keyEquivalent: "")
        let finder = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        let delete = NSMenuItem(title: "Delete...", action: #selector(deleteProfile(_:)), keyEquivalent: "")
        for item in [rename, restart, finder] { item.target = self; item.representedObject = p.id; m.addItem(item) }
        m.addItem(.separator())
        delete.target = self
        delete.representedObject = p.id
        if p.isDefault { delete.action = nil }
        m.addItem(delete)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func renameProfile(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        let a = NSAlert()
        a.messageText = "Rename '\(p.name)'"
        a.informativeText = "Only the name changes. Its sign-in and data stay as they are."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = p.name
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Accounts.rename(p, to: field.stringValue)
            refresh(force: true)
            report("Renamed '\(p.name)' to '\(field.stringValue.trimmingCharacters(in: .whitespaces))'.")
        } catch { showError(error, title: "Could not rename") }
    }

    @objc func restartProfile(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        do {
            try Launcher.stop(p)
            var fresh = p
            fresh.pid = nil
            try Launcher.start(fresh)
            refresh(force: true)
            report("Restarted '\(p.name)'.")
        } catch { showError(error, title: "Could not restart") }
    }

    @objc func showInFinder(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        if FileManager.default.fileExists(atPath: p.dataDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([p.dataDir])
        } else {
            report("'\(p.name)' has no folder yet. It is made the first time it opens.")
        }
    }

    @objc func deleteProfile(_ sender: NSMenuItem) {
        guard let p = profile(from: sender), !p.isDefault else { return }
        let a = NSAlert()
        a.messageText = "Delete '\(p.name)'?"
        a.informativeText = "Its folder and saved sign-in are removed, which signs that account out on this Mac." +
            (p.pid != nil ? " It is open now and will be quit first." : "") + " Your other accounts are untouched."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Accounts.delete(p)
            refresh(force: true)
            report("Deleted '\(p.name)'.")
        } catch { showError(error, title: "Could not delete") }
    }

    /// The window's own pixels, title bar included, as the README screenshots use.
    func snapshotPNG() -> Data? {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let frameView = window.contentView?.superview ?? window.contentView else { return nil }
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - The menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let showNotification = Notification.Name("io.github.priyanshugetrekt.claude-switcher.show")
    private var statusItem: NSStatusItem!
    private var accounts: AccountsWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Claude accounts") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "Claude"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        accounts = AccountsWindow()
        // A second copy of the app asks this one to show its window, then leaves.
        DistributedNotificationCenter.default().addObserver(forName: AppDelegate.showNotification, object: nil, queue: .main) { [weak self] _ in
            self?.accounts.show()
        }
        accounts.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        accounts.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = Profiles.list()
        for (i, p) in profiles.enumerated() {
            let item = NSMenuItem(title: p.name, action: #selector(menuOpen(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.target = self
            item.representedObject = p.id
            item.image = Palette.badge(for: p, size: 16)
            item.state = p.pid != nil ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Account", action: #selector(menuAdd), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)
        let open = profiles.filter { $0.pid != nil }
        if !open.isEmpty {
            let quitItem = NSMenuItem(title: "Quit Account", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for p in open {
                let q = NSMenuItem(title: p.name, action: #selector(menuQuit(_:)), keyEquivalent: "")
                q.target = self
                q.representedObject = p.id
                sub.addItem(q)
            }
            quitItem.submenu = sub
            menu.addItem(quitItem)
        }
        let show = NSMenuItem(title: "Show Accounts...", action: #selector(menuShow), keyEquivalent: "a")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let quitApp = NSMenuItem(title: "Quit Claude Profile Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitApp)
    }

    @objc func menuOpen(_ sender: NSMenuItem) { accounts.openProfile(sender) }
    @objc func menuQuit(_ sender: NSMenuItem) { accounts.quitProfile(sender) }
    @objc func menuAdd() { accounts.addAccount() }
    @objc func menuShow() { accounts.show() }
}

// MARK: - Command line

let usage = """
Claude Profile Switcher \(switcherVersion) for macOS

With no arguments it runs as a menu bar app. From a terminal:

  --list                      Accounts and which are open
  --launch NAME               Open an account, or bring it forward if it is open
  --quit NAME                 Quit that account's Claude
  --restart NAME              Quit it if open, then open it again
  --add-account               Make a new account and open Claude at its sign-in screen
  --rename NAME NEW-NAME      Rename (the folder and sign-in stay as they are)
  --delete NAME               Delete an account and its folder (signs it out here)
  --claude-path PATH          Use this Claude.app (remembered)
  --version                   Print the version
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func listText() -> String {
    Profiles.list().map { p in
        let name = p.name == p.id ? p.name : "\(p.name) [\(p.id)]"
        let state = p.pid.map { "open (pid \($0))" } ?? "not open"
        return name.padding(toLength: max(24, name.count + 1), withPad: " ", startingAt: 0) +
            state.padding(toLength: 22, withPad: " ", startingAt: 0) + p.dataDir.path
    }.joined(separator: "\n")
}

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Returns true when a command was handled; false means run the menu bar app.
func runCommandLine(_ args: [String]) throws -> Bool {
    if args.isEmpty { return false }
    if args.contains("--help") || args.contains("-h") { print(usage); return true }
    if args.contains("--version") { print(switcherVersion); return true }
    if let path = value(after: "--claude-path", in: args) {
        guard FileManager.default.fileExists(atPath: path) else { throw SwitcherError("--claude-path points at '\(path)', which does not exist.") }
        try Settings.set("ClaudePath", URL(fileURLWithPath: path).standardizedFileURL.path)
        if args.count == 2 { print("Using \(path)."); return true }
    }
    if args.contains("--list") { print(listText()); return true }
    if args.contains("--add-account") {
        let p = try Accounts.add()
        print("Added '\(p.name)'. Sign in with the other account in the Claude window that just opened.")
        return true
    }
    if let name = value(after: "--launch", in: args) {
        let p = try Profiles.resolveOrThrow(name)
        let how = try Launcher.start(p)
        print(how == "focused" ? "Switched to '\(p.name)'." : "Opened '\(p.name)'.")
        return true
    }
    if let name = value(after: "--quit", in: args) {
        let p = try Profiles.resolveOrThrow(name)
        print(try Launcher.stop(p) ? "Quit '\(p.name)'." : "'\(p.name)' was not open.")
        return true
    }
    if let name = value(after: "--restart", in: args) {
        var p = try Profiles.resolveOrThrow(name)
        let was = try Launcher.stop(p)
        p.pid = nil
        try Launcher.start(p)
        print(was ? "Restarted '\(p.name)'." : "'\(p.name)' was not open; opened it.")
        return true
    }
    if let i = args.firstIndex(of: "--rename") {
        guard i + 2 < args.count else { throw SwitcherError("Usage: --rename NAME NEW-NAME") }
        let p = try Profiles.resolveOrThrow(args[i + 1])
        try Accounts.rename(p, to: args[i + 2])
        print("Renamed '\(p.name)' to '\(args[i + 2])'.")
        return true
    }
    if let name = value(after: "--delete", in: args) {
        let p = try Profiles.resolveOrThrow(name)
        try Accounts.delete(p)
        print("Deleted '\(p.name)'.")
        return true
    }
    // Build and documentation helpers, not for everyday use.
    if let dir = value(after: "--render-icon", in: args) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                           ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
            guard let data = Palette.png(Palette.appIcon(size: CGFloat(px)), pixels: px) else { throw SwitcherError("Could not draw the icon.") }
            try data.write(to: url.appendingPathComponent("icon_\(name).png"))
        }
        return true
    }
    if let path = value(after: "--snapshot", in: args) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let mode = value(after: "--appearance", in: args) {
            app.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        let w = AccountsWindow()
        w.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let png = w.snapshotPNG() else { throw SwitcherError("Could not render the window.") }
        try png.write(to: URL(fileURLWithPath: path))
        return true
    }
    // Launch Services adds -psn_... on old systems when opened from the Finder.
    if args.allSatisfy({ $0.hasPrefix("-psn") || $0 == "-NSDocumentRevisionsDebugMode" || $0 == "YES" }) { return false }
    throw SwitcherError("Unknown arguments: \(args.joined(separator: " "))\n\n\(usage)")
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if try runCommandLine(arguments) { exit(0) }
} catch {
    fail(error.localizedDescription)
}

// One switcher at a time: a second copy asks the first to show its window, then leaves.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    DistributedNotificationCenter.default().postNotificationName(AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
