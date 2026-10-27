// Solo — only one thing plays at a time.
// When a new app starts playing, the previously playing app is paused.
// When the new app pauses, the app it interrupted is resumed.

import AppKit

// MARK: - Helper process (MediaRemote via /usr/bin/perl)

final class Helper {
    var onEvent: (([String: Any]) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopping = false

    private let resources = Bundle.main.resourceURL!

    func start() {
        stopping = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [
            resources.appendingPathComponent("launch.pl").path,
            resources.appendingPathComponent("SoloHelper.dylib").path,
        ]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                Log.shared.add("helper exited (\(proc.terminationStatus)), restarting")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
            }
        }
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
        } catch {
            Log.shared.add("helper failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopping = true
        try? input?.close()  // helper clears any override on EOF
        process?.waitUntilExit()
    }

    func send(_ line: String) {
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                onEvent?(obj)
            }
        }
    }
}

// MARK: - Controlling apps

enum Action {
    case play, pause
    var mediaRemoteCommand: Int { self == .play ? 0 : 1 }
    var appleScriptVerb: String { self == .play ? "play" : "pause" }
}

/// Apps with a reliable AppleScript play/pause that can be targeted while in the background.
let appleScriptApps: Set<String> = ["com.spotify.client", "com.apple.Music"]

func isRunning(_ bundle: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
}

func appName(_ bundle: String) -> String {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
       let name = app.localizedName {
        return name
    }
    return bundle
}

// MARK: - Log

final class Log {
    static let shared = Log()
    private(set) var lines: [String] = []
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Solo.log")
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ msg: String) {
        let line = "\(fmt.string(from: Date()))  \(msg)"
        lines.append(line)
        if lines.count > 12 { lines.removeFirst() }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }
}

// MARK: - Coordinator

final class Coordinator {
    let helper: Helper
    var enabled = true
    var experimentalTargeting = false
    var resumeDelay: TimeInterval = 1.0

    private(set) var current: (bundle: String, playing: Bool)?
    /// Apps Solo paused, most recent last.
    private(set) var pausedStack: [String] = []
    private var pendingResume: DispatchWorkItem?
    var onChange: (() -> Void)?

    init(helper: Helper) { self.helper = helper }

    func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "now":
            guard let bundle = event["bundle"] as? String else { return }
            let playing = (event["playing"] as? Int ?? 0) == 1
            if (event["quiet"] as? Int ?? 0) == 1 {
                current = (bundle, playing)
                Log.shared.add("after override: \(appName(bundle)) \(playing ? "▶︎" : "⏸")")
            } else {
                nowPlaying(bundle: bundle, playing: playing)
            }
        case "sendto":
            let b = event["bundle"] as? String ?? "?"
            let ok = event["elected"] as? Bool ?? false
            Log.shared.add("experimental → \(appName(b)): \(ok ? "override elected, command sent" : "override NOT elected, command skipped")")
            if let r = event["restored"] as? [String: Any], let rb = r["bundle"] as? String {
                Log.shared.add("experimental → handed back to \(appName(rb)): \((r["ok"] as? Bool ?? false) ? "ok" : "FAILED")")
            }
        case "log":
            Log.shared.add("helper: \(event["msg"] as? String ?? "")")
        default: break
        }
        onChange?()
    }

    private func nowPlaying(bundle: String, playing: Bool) {
        let prev = current
        current = (bundle, playing)
        Log.shared.add("now playing: \(appName(bundle)) \(playing ? "▶︎" : "⏸")")
        guard enabled else { return }

        if playing {
            pendingResume?.cancel()
            pendingResume = nil
            // The user resumed something Solo had paused: it no longer needs resuming.
            pausedStack.removeAll { $0 == bundle }
            if let prev, prev.bundle != bundle, prev.playing {
                if control(prev.bundle, .pause) {
                    pausedStack.removeAll { $0 == prev.bundle }
                    pausedStack.append(prev.bundle)
                }
            }
        } else {
            // Something that was playing stopped. It may still be the current app (paused),
            // or it may have left Now Playing entirely (e.g. a video ended), in which case
            // macOS falls back to another app — often the paused one Solo should resume.
            guard !pausedStack.isEmpty, let prev, prev.playing else { return }
            let stopped = prev.bundle
            // Debounce: seeking/buffering can briefly report "paused".
            pendingResume?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.resumePrevious(stopped: stopped) }
            pendingResume = work
            DispatchQueue.main.asyncAfter(deadline: .now() + resumeDelay, execute: work)
        }
    }

    private func resumePrevious(stopped: String) {
        guard let cur = current, !cur.playing else { return }
        while let next = pausedStack.popLast() {
            guard next != stopped, isRunning(next) else { continue }
            _ = control(next, .play)
            break
        }
        onChange?()
    }

    func forgetPaused() {
        pausedStack.removeAll()
        onChange?()
    }

    /// Returns true if a command was issued.
    private func control(_ bundle: String, _ action: Action) -> Bool {
        guard isRunning(bundle) else { return false }
        if appleScriptApps.contains(bundle) {
            let src = "tell application id \"\(bundle)\" to \(action.appleScriptVerb)"
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let err {
                Log.shared.add("AppleScript \(action.appleScriptVerb) \(appName(bundle)) failed: \(err[NSAppleScript.errorMessage] ?? err)")
                return false
            }
            Log.shared.add("\(action.appleScriptVerb) \(appName(bundle)) (AppleScript)")
            return true
        }
        if experimentalTargeting {
            Log.shared.add("\(action.appleScriptVerb) \(appName(bundle)) (experimental MediaRemote override)")
            helper.send("sendto \(bundle) \(action.mediaRemoteCommand)")
            return true
        }
        Log.shared.add("can't \(action.appleScriptVerb) \(appName(bundle)) — no AppleScript (enable experimental targeting)")
        return false
    }
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let helper = Helper()
    private lazy var coordinator = Coordinator(helper: helper)
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ note: Notification) {
        coordinator.enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        coordinator.experimentalTargeting = defaults.bool(forKey: "experimentalTargeting")

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        helper.onEvent = { [weak self] in self?.coordinator.handle($0) }
        coordinator.onChange = { [weak self] in self?.updateIcon() }
        helper.start()
        Log.shared.add("Solo started")
    }

    func applicationWillTerminate(_ note: Notification) {
        helper.stop()
    }

    private func updateIcon() {
        let name = coordinator.enabled ? "music.note" : "speaker.slash"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Solo")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let cur = coordinator.current {
            menu.addItem(disabled("Now playing: \(appName(cur.bundle)) \(cur.playing ? "▶︎" : "⏸")"))
        } else {
            menu.addItem(disabled("Now playing: —"))
        }
        let stack = coordinator.pausedStack.reversed().map(appName).joined(separator: ", ")
        menu.addItem(disabled("Paused by Solo: \(stack.isEmpty ? "—" : stack)"))
        menu.addItem(.separator())

        menu.addItem(toggle("Enabled", coordinator.enabled, #selector(toggleEnabled)))
        menu.addItem(toggle("Experimental: target any app (MediaRemote override)",
                            coordinator.experimentalTargeting, #selector(toggleExperimental)))
        menu.addItem(item("Forget paused apps", #selector(forget)))
        menu.addItem(item("Reset Now Playing override", #selector(resetOverride)))
        menu.addItem(.separator())

        let logMenu = NSMenu()
        for line in Log.shared.lines.reversed() { logMenu.addItem(disabled(line)) }
        logMenu.addItem(.separator())
        logMenu.addItem(item("Open full log", #selector(openLog)))
        let logItem = NSMenuItem(title: "Recent events", action: nil, keyEquivalent: "")
        logItem.submenu = logMenu
        menu.addItem(logItem)

        menu.addItem(.separator())
        menu.addItem(item("Quit Solo", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    @objc private func toggleEnabled() {
        coordinator.enabled.toggle()
        defaults.set(coordinator.enabled, forKey: "enabled")
        if !coordinator.enabled { coordinator.forgetPaused() }
        updateIcon()
    }

    @objc private func toggleExperimental() {
        coordinator.experimentalTargeting.toggle()
        defaults.set(coordinator.experimentalTargeting, forKey: "experimentalTargeting")
        Log.shared.add("experimental targeting \(coordinator.experimentalTargeting ? "on" : "off")")
    }

    @objc private func forget() { coordinator.forgetPaused() }

    @objc private func resetOverride() {
        Log.shared.add("resetting Now Playing override")
        helper.send("reset")
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Solo.log"))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
