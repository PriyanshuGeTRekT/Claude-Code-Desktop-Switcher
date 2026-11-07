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
    static func openArguments(app: URL, profile: Profile, background: Bool = false) -> [String] {
        var a = ["-n", "-a", app.path]
        if background { a.insert("-g", at: 0) }   // -g: start it without bringing it to the front
        for (k, v) in env(profile.id) { a += ["--env", "\(k)=\(v)"] }
        var pass = profile.isDefault ? [] : ["--user-data-dir=\(profile.dataDir.path)"]
        pass += extraArgs(profile.id)
        if !pass.isEmpty { a += ["--args"] + pass }
        return a
    }

    /// Returns "focused" when the account was already open, "started" otherwise.
    @discardableResult
    static func start(_ profile: Profile, background: Bool = false) throws -> String {
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
        p.arguments = openArguments(app: app, profile: profile, background: background)
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
        for key in ["Labels", "Colors", "ChosenColors", "ProfileArgs", "ProfileEnv", "KeepRunning"] {
            try? Settings.setEntry(key, id: p.id, value: nil)
        }
        try? Watchdog.sync()
    }
}

// MARK: - Per-account settings shared with the Windows switcher

enum AccountSettings {
    /// "NAME=value" lines as typed in the Edit dialog. Blank lines and # comments are
    /// skipped; anything else without a valid name before the first = is reported back.
    static func parseEnv(_ text: String) -> (vars: [String: String], invalid: [String]) {
        var vars: [String: String] = [:]
        var invalid: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { invalid.append(line); continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { invalid.append(line); continue }
            vars[name] = String(line[line.index(after: eq)...])
        }
        return (vars, invalid)
    }

    static func envText(_ id: String) -> String {
        guard let m = Settings.map("ProfileEnv")[id] as? [String: Any] else { return "" }
        return m.keys.sorted().map { "\($0)=\(m[$0]!)" }.joined(separator: "\n")
    }

    /// The flags as one line, list items quoted when they hold spaces, so saving them back
    /// keeps each one a single argument.
    static func argsText(_ id: String) -> String {
        let v = Settings.map("ProfileArgs")[id]
        if let s = v as? String { return s }
        if let a = v as? [Any] {
            return a.map { "\($0)" }.map { $0.contains(" ") || $0.contains("\"") ? "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : $0 }.joined(separator: " ")
        }
        return ""
    }

    static func isKept(_ id: String) -> Bool { (Settings.map("KeepRunning")[id] as? Bool) == true }
}

// MARK: - Background agents (Open at Login, keep running)

enum Agents {
    /// A run with its own agents folder (the tests) also gets labels of its own, so it never
    /// unloads the agents of a real install on the same Mac.
    static let base = "io.github.priyanshugetrekt.claude-profile-switcher" +
        ((ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_LAUNCHAGENTS_DIR"] ?? "").isEmpty ? "" : ".test")
    static let watchdogLabel = base + ".watchdog"
    static let loginLabel = base + ".login"

    static var dir: URL {
        if let o = ProcessInfo.processInfo.environment["CLAUDE_SWITCHER_LAUNCHAGENTS_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static func plistURL(_ label: String) -> URL { dir.appendingPathComponent(label + ".plist") }
    static func isInstalled(_ label: String) -> Bool { FileManager.default.fileExists(atPath: plistURL(label).path) }
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func isLoaded(_ label: String) -> Bool { launchctl(["print", "gui/\(getuid())/\(label)"]) == 0 }

    /// A per-user launch agent: no admin rights, and launchd starts it again at login.
    /// Loaded at once only when `load` is set; Open at Login takes effect at the next login.
    static func install(_ label: String, arguments: [String], interval: Int?, load: Bool) throws {
        var dict: [String: Any] = ["Label": label, "ProgramArguments": [executable] + arguments,
                                   "RunAtLoad": true, "ProcessType": label == loginLabel ? "Interactive" : "Background"]
        if let i = interval { dict["StartInterval"] = i }
        // The tests keep everything in a folder of their own; an agent has to look there too.
        var env: [String: String] = [:]
        for k in ["CLAUDE_SWITCHER_SUPPORT_DIR", "CLAUDE_SWITCHER_APP", "CLAUDE_SWITCHER_LAUNCHAGENTS_DIR"] {
            if let v = ProcessInfo.processInfo.environment[k], !v.isEmpty { env[k] = v }
        }
        if !env.isEmpty { dict["EnvironmentVariables"] = env }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL(label), options: .atomic)
        guard load else { return }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])   // an older definition, if any
        let status = launchctl(["bootstrap", "gui/\(getuid())", plistURL(label).path])
        if status != 0 { throw SwitcherError("launchctl could not load \(label) (status \(status)). Its file is \(plistURL(label).path).") }
    }

    static func remove(_ label: String) {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL(label))
    }
}

// MARK: - Keeping accounts open

/*
    An account marked KeepRunning is reopened when something other than its user closed
    it: Claude updating itself, a logoff, a restart. A launch agent runs --watch every two
    minutes and at login. It acts only when the account's own main.log ends in a forced
    close, never after a quit by the user, and never twice within ten minutes. The markers
    were seen in the Windows build's logs (issue #9); "no recognisable line" means leave it,
    so a rename on Anthropic's side fails safe.
*/
enum Watchdog {
    static let userQuitMarkers = ["beforeQuit: handler fired", "willQuit: handler fired"]
    static let forcedMarkers = ["Windows session ending", "going down for update", "beforeQuitForUpdate", "[stealth-update]", "quitAndInstall"]
    static var home: URL { Loc.profileRoot.appendingPathComponent(".switcher", isDirectory: true) }
    static var logURL: URL { home.appendingPathComponent("watchdog.log") }
    static var stateURL: URL { home.appendingPathComponent("watchdog-state.json") }

    /// "forced", "user" or "unknown", from the newest line that carries a marker.
    static func exitKind(_ lines: [String]) -> String {
        for line in lines.reversed() {
            if userQuitMarkers.contains(where: { line.contains($0) }) { return "user" }
            if forcedMarkers.contains(where: { line.contains($0) }) { return "forced" }
        }
        return "unknown"
    }

    /// The account's own log: inside its folder, and for the original account also where
    /// Electron puts logs on macOS by default.
    static func logTail(_ p: Profile, lines: Int = 40) -> [String] {
        var candidates = [p.dataDir.appendingPathComponent("logs/main.log")]
        if p.isDefault {
            candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude/main.log"))
        }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        let newest = existing.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let url = newest, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(lines))
    }

    static func kept() -> Set<String> {
        Set(Settings.map("KeepRunning").compactMap { ($0.value as? Bool) == true ? $0.key : nil })
    }

    static func select(_ profiles: [Profile], kept: Set<String>, kinds: [String: String], last: [String: Date], now: Date, cooldown: TimeInterval = 600) -> [Profile] {
        profiles.filter { p in
            kept.contains(p.id) && p.pid == nil && kinds[p.id] == "forced" &&
                !(last[p.id].map { now.timeIntervalSince($0) < cooldown } ?? false)
        }
    }

    static func write(_ message: String) {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int), size > 100_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let h = FileHandle(forWritingAtPath: logURL.path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { try? Data(line.utf8).write(to: logURL) }
    }

    static func loadState() -> [String: Date] {
        guard let data = try? Data(contentsOf: stateURL), let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func saveState(_ state: [String: Date]) {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: state.mapValues { $0.timeIntervalSince1970 }) { try? data.write(to: stateURL) }
    }

    /// Claude.app was replaced in the last minute: it is still settling, and brings back the
    /// original account itself.
    static func claudeUpdating() -> Bool {
        guard let app = ClaudeApp.find(),
              let date = try? app.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return Date().timeIntervalSince(date) < 60
    }

    /// One pass. Returns the names reopened.
    @discardableResult
    static func runOnce() -> [String] {
        let keep = kept()
        if keep.isEmpty { return [] }
        if claudeUpdating() { write("Claude is updating; waiting."); return [] }
        let profiles = Profiles.list()
        var kinds: [String: String] = [:]
        for p in profiles where keep.contains(p.id) && p.pid == nil { kinds[p.id] = exitKind(logTail(p)) }
        var state = loadState()
        var done: [String] = []
        for p in select(profiles, kept: keep, kinds: kinds, last: state, now: Date()) {
            do {
                try Launcher.start(p, background: true)
                state[p.id] = Date()
                saveState(state)
                write("Reopened '\(p.name)': its log ended in a forced close.")
                done.append(p.name)
                Thread.sleep(forTimeInterval: 3)
            } catch {
                write("Could not reopen '\(p.name)': \(error.localizedDescription)")
            }
        }
        return done
    }

    /// The agent exists exactly while some account is kept.
    static func sync() throws {
        if kept().isEmpty { Agents.remove(Agents.watchdogLabel) }
        else { try Agents.install(Agents.watchdogLabel, arguments: ["--watch"], interval: 120, load: true) }
    }
}

// MARK: - Claude Code chats

struct Chat {
    let file: URL
    let account: String
    let org: String
    let title: String
    let folder: String
    let updated: Date
    var id: String { String(file.deletingPathExtension().lastPathComponent.dropFirst("local_".count)) }
}

/*
    The desktop app keeps one small JSON file per Claude Code chat, at
        <profile>/claude-code-sessions/<account id>/<organisation id>/local_<id>.json
    and the transcript itself outside the profile. Copying a chat to another account means
    placing that file in the other profile's store, under the account it is signed in to.
*/
enum Chats {
    static func root(_ p: Profile) -> URL { p.dataDir.appendingPathComponent("claude-code-sessions", isDirectory: true) }

    static func subdirs(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func first(_ obj: [String: Any]?, _ keys: [String]) -> String? {
        for k in keys { if let v = obj?[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v.trimmingCharacters(in: .whitespaces) } }
        return nil
    }

    static func list(_ p: Profile) -> [Chat] {
        var found: [String: Chat] = [:]
        for account in subdirs(root(p)) {
            for org in subdirs(account) {
                let files = ((try? FileManager.default.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
                for f in files {
                    let obj = (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let folderPath = first(obj, ["cwd", "workingDirectory", "projectPath", "folder", "path"]) ?? ""
                    let folder = folderPath.isEmpty ? "" : (folderPath.contains("/scratch-workspaces/") ? "(no folder)" : URL(fileURLWithPath: folderPath).lastPathComponent)
                    let updated = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let base = f.deletingPathExtension().lastPathComponent
                    let title = first(obj, ["title", "name", "summary", "customTitle", "displayName"]) ?? "Chat \(base.dropFirst(6).prefix(8))"
                    let chat = Chat(file: f, account: account.lastPathComponent, org: org.lastPathComponent, title: title, folder: folder, updated: updated)
                    // The same chat can sit under two accounts after an earlier copy. List it once.
                    if let seen = found[f.lastPathComponent], seen.updated >= updated { continue }
                    found[f.lastPathComponent] = chat
                }
            }
        }
        return found.values.sorted { $0.updated > $1.updated }
    }

    /// The organisation folder written to most recently: whoever is signed in now.
    static func store(_ p: Profile) -> URL? {
        subdirs(root(p)).flatMap { subdirs($0) }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// True when copied, false when the target already has it. Only whole JSON string values
    /// equal to the source account or organisation id are swapped for the target's, so paths
    /// that merely contain the same ids are left alone.
    @discardableResult
    static func copy(_ c: Chat, to store: URL) throws -> Bool {
        let dest = store.appendingPathComponent(c.file.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { return false }
        var text = try String(contentsOf: c.file, encoding: .utf8)
        let targetAccount = store.deletingLastPathComponent().lastPathComponent
        text = text.replacingOccurrences(of: "\"\(c.account)\"", with: "\"\(targetAccount)\"")
            .replacingOccurrences(of: "\"\(c.org)\"", with: "\"\(store.lastPathComponent)\"")
        try text.write(to: dest, atomically: true, encoding: .utf8)
        return true
    }

    static func noStoreMessage(_ p: Profile) -> String {
        "'\(p.name)' has not used Claude Code yet, so there is nowhere to put the chats. Open it, sign in, visit the Code tab once, then try again."
    }
}

// MARK: - Diagnostics and removal

enum Maintenance {
    static func redact(_ text: String) -> String {
        let user = NSUserName()
        return user.isEmpty ? text : text.replacingOccurrences(of: user, with: "<user>", options: .caseInsensitive)
    }

    static func doctor() -> String {
        var out: [String] = []
        out.append("Claude Profile Switcher \(switcherVersion) (macOS)")
        out.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let app = ClaudeApp.find() { out.append("Claude: \(ClaudeApp.version(of: app)) at \(app.path)") } else { out.append("Claude: NOT FOUND") }
        out.append("Switcher: \(Agents.executable)")
        out.append("Accounts folder: \(Loc.profileRoot.path)")
        out.append("Watchdog agent: \(Agents.isInstalled(Agents.watchdogLabel) ? (Agents.isLoaded(Agents.watchdogLabel) ? "installed, loaded" : "installed, not loaded") : "not installed")")
        out.append("Open at Login: \(Agents.isInstalled(Agents.loginLabel) ? "on" : "off")")
        out.append("")
        out.append("Accounts:")
        let kept = Watchdog.kept()
        for p in Profiles.list() {
            var notes: [String] = []
            if p.isDefault { notes.append("original") }
            if kept.contains(p.id) { notes.append("kept running") }
            let name = p.name == p.id ? p.name : "\(p.name) [\(p.id)]"
            out.append("  \(name.padding(toLength: max(24, name.count + 1), withPad: " ", startingAt: 0))\(p.pid.map { "pid \($0)" } ?? "not open")  \(p.dataDir.path)\(notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))")")
        }
        out.append("")
        out.append("Watchdog log, last lines:")
        let tail = (try? String(contentsOf: Watchdog.logURL, encoding: .utf8))?.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(5) ?? []
        out += tail.isEmpty ? ["  (none)"] : tail.map { "  \($0)" }
        return redact(out.joined(separator: "\n"))
    }

    /// Everything the switcher made outside the accounts. Accounts and settings stay unless
    /// removeProfiles asks for them to go. The app itself is dragged to the Bin by hand.
    static func uninstall(removeProfiles: Bool) -> [String] {
        var done: [String] = []
        // Nothing is kept running after this, so deleting accounts below cannot bring the
        // watchdog back.
        if !Watchdog.kept().isEmpty { try? Settings.set("KeepRunning", nil); done.append("stopped keeping accounts running") }
        for label in [Agents.watchdogLabel, Agents.loginLabel] where Agents.isInstalled(label) {
            Agents.remove(label)
            done.append("removed the launch agent \(label)")
        }
        if removeProfiles {
            for p in Profiles.list() where !p.isDefault {
                do { try Accounts.delete(p); done.append("deleted the account '\(p.name)' and its folder") }
                catch { done.append("kept '\(p.name)': \(error.localizedDescription)") }
            }
        }
        let home = Watchdog.home
        if FileManager.default.fileExists(atPath: home.path) { try? FileManager.default.removeItem(at: home); done.append("removed \(home.path)") }
        if removeProfiles {
            if FileManager.default.fileExists(atPath: Loc.settingsFile.path) { try? FileManager.default.removeItem(at: Loc.settingsFile); done.append("removed \(Loc.settingsFile.path)") }
            if ((try? FileManager.default.contentsOfDirectory(atPath: Loc.profileRoot.path)) ?? ["x"]).isEmpty {
                try? FileManager.default.removeItem(at: Loc.profileRoot); done.append("removed \(Loc.profileRoot.path)")
            }
        } else {
            done.append("kept your accounts and \(Loc.settingsFile.path); add --remove-profiles to delete them")
        }
        done.append("to finish, quit the switcher from the menu bar and drag it from Applications to the Bin")
        return done
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
        if AccountSettings.isKept(p.id) { detailText += "  ·  kept running" }
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
        let edit = NSMenuItem(title: "Edit...", action: #selector(editProfile(_:)), keyEquivalent: "")
        let restart = NSMenuItem(title: "Restart", action: #selector(restartProfile(_:)), keyEquivalent: "")
        let transfer = NSMenuItem(title: "Transfer Code Chats...", action: #selector(transferChats(_:)), keyEquivalent: "")
        let finder = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        let delete = NSMenuItem(title: "Delete...", action: #selector(deleteProfile(_:)), keyEquivalent: "")
        for item in [edit, restart, transfer, finder] { item.target = self; item.representedObject = p.id; m.addItem(item) }
        m.addItem(.separator())
        delete.target = self
        delete.representedObject = p.id
        if p.isDefault { delete.action = nil }
        m.addItem(delete)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// The Edit dialog's fields, built apart so --snapshot-edit can render the same view.
    final class EditForm {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 318))
        let name = NSTextField(frame: NSRect(x: 0, y: 274, width: 420, height: 24))
        let colours = NSSegmentedControl()
        let env = NSTextView(frame: NSRect(x: 0, y: 0, width: 404, height: 80))
        let flags = NSTextField(frame: NSRect(x: 0, y: 64, width: 420, height: 24))
        let keep = NSButton(checkboxWithTitle: "Keep running after Claude updates and restarts", target: nil, action: nil)

        init(_ p: Profile) {
            func label(_ text: String, _ y: CGFloat, small: Bool = false) {
                let l = NSTextField(labelWithString: text)
                l.frame = NSRect(x: 0, y: y, width: 420, height: 16)
                l.font = small ? .systemFont(ofSize: 11) : .systemFont(ofSize: 12, weight: .medium)
                if small { l.textColor = .secondaryLabelColor }
                view.addSubview(l)
            }
            label("Name", 300)
            name.stringValue = p.name
            view.addSubview(name)
            label("Badge colour", 252)
            colours.segmentCount = Palette.rgb.count
            colours.trackingMode = .selectOne
            for i in 0..<Palette.rgb.count {
                colours.setImage(Palette.badge(letter: "", fill: Palette.color(i), size: 14), forSegment: i)
                colours.setWidth(44, forSegment: i)
            }
            colours.frame = NSRect(x: 0, y: 222, width: 420, height: 26)
            colours.selectedSegment = p.isDefault ? -1 : Palette.index(for: p.id)
            colours.isEnabled = !p.isDefault
            view.addSubview(colours)
            label("Environment variables, one per line as NAME=value", 200)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 112, width: 420, height: 84))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            env.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            env.isRichText = false
            env.isAutomaticQuoteSubstitutionEnabled = false
            env.string = AccountSettings.envText(p.id)
            scroll.documentView = env
            view.addSubview(scroll)
            label("Extra launch flags", 92)
            flags.stringValue = AccountSettings.argsText(p.id)
            flags.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.addSubview(flags)
            label("Variables and flags reach Claude the next time this account starts.", 44, small: true)
            keep.frame = NSRect(x: 0, y: 14, width: 420, height: 22)
            keep.state = AccountSettings.isKept(p.id) ? .on : .off
            view.addSubview(keep)
            label("Reopened within two minutes when they close it. Quitting it yourself leaves it closed.", -2, small: true)
        }
    }

    func editAlert(_ p: Profile) -> (NSAlert, EditForm) {
        let a = NSAlert()
        a.messageText = "Edit '\(p.name)'"
        a.informativeText = "Its sign-in and data stay as they are."
        let form = EditForm(p)
        a.accessoryView = form.view
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = form.name
        return (a, form)
    }

    @objc func editProfile(_ sender: NSMenuItem) {
        guard let p = profile(from: sender) else { return }
        let (a, form) = editAlert(p)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // The name is the one field that can be refused, so it is checked before anything
        // is saved: a refused edit changes nothing.
        let newName = form.name.stringValue.trimmingCharacters(in: .whitespaces)
        let renaming = !newName.isEmpty && newName != p.name
        if renaming, let err = Profiles.validate(name: newName, except: p.id) {
            showError(SwitcherError(err + " Nothing was saved."), title: "Could not save")
            return
        }
        do {
            let parsed = AccountSettings.parseEnv(form.env.string)
            if !parsed.invalid.isEmpty {
                let w = NSAlert()
                w.messageText = "Some lines were left out"
                w.informativeText = "These are not NAME=value with a name made of letters, digits and _ (not starting with a digit):\n\n" + parsed.invalid.joined(separator: "\n")
                w.runModal()
            }
            let oldEnv = AccountSettings.envText(p.id)
            let oldArgs = AccountSettings.argsText(p.id)
            let newArgs = form.flags.stringValue.trimmingCharacters(in: .whitespaces)
            try Settings.setEntry("ProfileEnv", id: p.id, value: parsed.vars.isEmpty ? nil : parsed.vars)
            try Settings.setEntry("ProfileArgs", id: p.id, value: newArgs.isEmpty ? nil : newArgs)
            let launchChanged = AccountSettings.envText(p.id) != oldEnv || newArgs != oldArgs
            if !p.isDefault, form.colours.selectedSegment >= 0, form.colours.selectedSegment != Palette.index(for: p.id) {
                try Settings.setEntry("ChosenColors", id: p.id, value: form.colours.selectedSegment)
            }
            if (form.keep.state == .on) != AccountSettings.isKept(p.id) {
                try Settings.setEntry("KeepRunning", id: p.id, value: form.keep.state == .on ? true : nil)
                do { try Watchdog.sync() } catch { showError(error, title: "The choice is saved, but the watchdog could not be changed") }
            }
            if renaming { try Accounts.rename(p, to: newName) }
            refresh(force: true)
            report("Saved '\(renaming ? newName : p.name)'.")
            if launchChanged, p.pid != nil {
                let r = NSAlert()
                r.messageText = "Restart '\(renaming ? newName : p.name)' to apply?"
                r.informativeText = "It is open, and its new variables or flags apply when it starts again."
                r.addButton(withTitle: "Restart")
                r.addButton(withTitle: "Later")
                if r.runModal() == .alertFirstButtonReturn { restartProfile(sender) }
            }
        } catch { showError(error, title: "Could not save") }
    }

    @objc func transferChats(_ sender: NSMenuItem) {
        guard let source = profile(from: sender) else { return }
        let chats = Chats.list(source)
        let targets = Profiles.list(status: false).filter { $0.id != source.id }
        if chats.isEmpty { report("'\(source.name)' has no Claude Code chats to transfer."); return }
        if targets.isEmpty { report("Add a second account first, then transfer chats to it."); return }

        let a = NSAlert()
        a.messageText = "Copy Claude Code chats from '\(source.name)'"
        a.informativeText = "Each chat stays here too. Finish a chat in one account before continuing it in the other, since both continue the same history."
        let width: CGFloat = 440
        let rowsHeight = CGFloat(chats.count) * 22
        let list = FlippedView(frame: NSRect(x: 0, y: 0, width: width - 20, height: rowsHeight))
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var boxes: [NSButton] = []
        for (i, c) in chats.enumerated() {
            let detail = [c.folder, df.string(from: c.updated)].filter { !$0.isEmpty }.joined(separator: "  ·  ")
            let b = NSButton(checkboxWithTitle: "\(c.title)   \(detail)", target: nil, action: nil)
            b.frame = NSRect(x: 0, y: CGFloat(i) * 22, width: width - 20, height: 20)
            b.lineBreakMode = .byTruncatingTail
            list.addSubview(b)
            boxes.append(b)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 34, width: width, height: min(220, rowsHeight + 6)))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = list
        let to = NSPopUpButton(frame: NSRect(x: 60, y: 0, width: 220, height: 26))
        to.addItems(withTitles: targets.map { $0.name })
        let toLabel = NSTextField(labelWithString: "Copy to")
        toLabel.frame = NSRect(x: 0, y: 4, width: 56, height: 18)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: scroll.frame.maxY))
        for v in [scroll, toLabel, to] as [NSView] { container.addSubview(v) }
        a.accessoryView = container
        a.addButton(withTitle: "Copy Chats")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let picked = zip(chats, boxes).filter { $0.1.state == .on }.map { $0.0 }
        if picked.isEmpty { return }
        let target = targets[to.indexOfSelectedItem]
        guard let store = Chats.store(target) else { showError(SwitcherError(Chats.noStoreMessage(target)), title: "Not ready yet"); return }
        do {
            var copied = 0, skipped = 0
            for c in picked { if try Chats.copy(c, to: store) { copied += 1 } else { skipped += 1 } }
            var msg = "Copied \(copied) chat(s) to '\(target.name)'."
            if skipped > 0 { msg += " \(skipped) were already there." }
            if Profiles.resolve(target.id)?.pid != nil { msg += " Quit and reopen it to see them." }
            report(msg)
        } catch { showError(error, title: "Transfer failed") }
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
        let login = NSMenuItem(title: "Open at Login", action: #selector(menuLogin), keyEquivalent: "")
        login.target = self
        login.state = Agents.isInstalled(Agents.loginLabel) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quitApp = NSMenuItem(title: "Quit Claude Profile Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitApp)
    }

    @objc func menuOpen(_ sender: NSMenuItem) { accounts.openProfile(sender) }
    @objc func menuQuit(_ sender: NSMenuItem) { accounts.quitProfile(sender) }
    @objc func menuAdd() { accounts.addAccount() }
    @objc func menuShow() { accounts.show() }
    @objc func menuLogin() {
        if Agents.isInstalled(Agents.loginLabel) { Agents.remove(Agents.loginLabel) }
        else { try? Agents.install(Agents.loginLabel, arguments: [], interval: nil, load: false) }
    }
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
  --chats NAME                That account's Claude Code chats
  --transfer FROM TO [--all | --chat ID ...]
                              Copy Claude Code chats to another account
  --keep-running NAME         Reopen it when a Claude update, a logoff or a restart closes it
  --stop-keeping NAME         Stop doing that
  --watch                     One pass of that check (the launch agent runs it)
  --open-at-login on|off      Start the switcher when you log in
  --doctor                    What a bug report needs, user name redacted
  --uninstall [--remove-profiles]
                              Remove what the switcher made outside your accounts
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
    if args.contains("--doctor") { print(Maintenance.doctor()); return true }
    if args.contains("--uninstall") {
        for line in Maintenance.uninstall(removeProfiles: args.contains("--remove-profiles")) { print("- \(line)") }
        return true
    }
    if args.contains("--watch") {
        let reopened = Watchdog.runOnce()
        if !reopened.isEmpty { print("Reopened: \(reopened.joined(separator: ", "))") }
        return true
    }
    if let name = value(after: "--keep-running", in: args) {
        let p = try Profiles.resolveOrThrow(name)
        try Settings.setEntry("KeepRunning", id: p.id, value: true)
        try Watchdog.sync()
        print("'\(p.name)' is kept running: a Claude update, a logoff or a restart that closes it is undone within two minutes. Quitting it yourself leaves it closed.")
        return true
    }
    if let name = value(after: "--stop-keeping", in: args) {
        let p = try Profiles.resolveOrThrow(name)
        try Settings.setEntry("KeepRunning", id: p.id, value: nil)
        try Watchdog.sync()
        print("'\(p.name)' is no longer kept running." + (Watchdog.kept().isEmpty ? " The watchdog agent was removed." : ""))
        return true
    }
    if let mode = value(after: "--open-at-login", in: args) {
        if mode == "on" { try Agents.install(Agents.loginLabel, arguments: [], interval: nil, load: false); print("The switcher opens when you log in.") }
        else { Agents.remove(Agents.loginLabel); print("The switcher no longer opens at login.") }
        return true
    }
    if let name = value(after: "--chats", in: args) {
        let p = try Profiles.resolveOrThrow(name)
        let df = ISO8601DateFormatter()
        for c in Chats.list(p) { print("\(c.id)  \(df.string(from: c.updated))  \(c.folder.isEmpty ? "-" : c.folder)  \(c.title)") }
        return true
    }
    if let i = args.firstIndex(of: "--transfer") {
        guard i + 2 < args.count else { throw SwitcherError("Usage: --transfer FROM TO [--all | --chat ID ...]") }
        let source = try Profiles.resolveOrThrow(args[i + 1])
        let target = try Profiles.resolveOrThrow(args[i + 2])
        if source.id == target.id { throw SwitcherError("Pick two different accounts.") }
        let wanted = args.indices.filter { args[$0] == "--chat" && $0 + 1 < args.count }.map { args[$0 + 1] }
        let chats = Chats.list(source).filter { args.contains("--all") || wanted.contains($0.id) || wanted.contains($0.file.lastPathComponent) }
        if chats.isEmpty { throw SwitcherError("No chats picked. Use --all, or --chat with ids from --chats \"\(source.name)\".") }
        guard let store = Chats.store(target) else { throw SwitcherError(Chats.noStoreMessage(target)) }
        var copied = 0, skipped = 0
        for c in chats { if try Chats.copy(c, to: store) { copied += 1 } else { skipped += 1 } }
        print("Copied \(copied) chat(s) to '\(target.name)'." + (skipped > 0 ? " \(skipped) were already there." : ""))
        return true
    }
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
    if let path = value(after: "--snapshot-edit", in: args), let name = value(after: "--account", in: args) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let mode = value(after: "--appearance", in: args) { app.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua) }
        let p = try Profiles.resolveOrThrow(name)
        let w = AccountsWindow()
        let (alert, _) = w.editAlert(p)
        alert.layout()
        alert.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let frame = alert.window.contentView?.superview ?? alert.window.contentView,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw SwitcherError("Could not render the dialog.") }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        // The dialog's own backdrop is a blur that a cached drawing leaves out, so lay the
        // rendering over the window colour of the same appearance.
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SwitcherError("Could not render the dialog.") }
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        alert.window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { throw SwitcherError("Could not render the dialog.") }
        try png.write(to: URL(fileURLWithPath: path))
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
