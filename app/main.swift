// Solo — only one thing plays at a time.
// When a new app starts playing, the previously playing app is paused.
// When the new app pauses, the app it interrupted is resumed.

import AppKit
import CoreAudio

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

// MARK: - Audio output (Core Audio process objects)

enum AudioOutput {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// Maps helper processes (browser renderers, WebKit.GPU, Electron helpers) to their app.
    private static let responsiblePID: ResponsibleFn? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    private static func address(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(sel)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Whether any process belonging to the app is currently running audio output.
    /// nil if Core Audio can't tell (no process list available).
    static func isOutputting(bundle: String, pid: pid_t) -> Bool? {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }

        var targets = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .map(\.processIdentifier))
        if pid > 0 { targets.insert(pid) }

        for id in ids {
            guard let running: UInt32 = get(id, kAudioProcessPropertyIsRunningOutput, 0), running != 0,
                  let p: pid_t = get(id, kAudioProcessPropertyPID, 0) else { continue }
            if targets.contains(p) { return true }
            if let resp = responsiblePID?(p), targets.contains(resp) { return true }
        }
        return false
    }
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
    /// Only pause the previous app once the new one is actually outputting audio.
    var requireAudio = true
    var resumeDelay: TimeInterval = 1.0
    /// How long a new Now Playing app has to start outputting audio.
    var audioWait: TimeInterval = 3.0

    private(set) var current: (bundle: String, playing: Bool)?
    /// Apps Solo paused, most recent last.
    private(set) var pausedStack: [String] = []
    private var pendingResume: DispatchWorkItem?
    /// A play event waiting for the new app to become audible before pausing `victims`.
    private struct PendingPause {
        let id = UUID()
        let incoming: String
        let victims: [String]
    }
    private var pendingPause: PendingPause?
    /// Apps that claimed Now Playing without audio; Solo paused nothing for them,
    /// so their stopping must not trigger a resume.
    private var silentClaims: Set<String> = []
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
                nowPlaying(bundle: bundle, pid: pid_t(event["pid"] as? Int ?? 0), playing: playing)
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

    private func nowPlaying(bundle: String, pid: pid_t, playing: Bool) {
        let prev = current
        current = (bundle, playing)
        Log.shared.add("now playing: \(appName(bundle)) \(playing ? "▶︎" : "⏸")")
        guard enabled else { return }

        if playing {
            pendingResume?.cancel()
            pendingResume = nil
            // The user resumed something Solo had paused: it no longer needs resuming.
            pausedStack.removeAll { $0 == bundle }
            silentClaims.remove(bundle)
            // A superseded pending check still owes its victims a pause.
            var victims = pendingPause?.victims ?? []
            pendingPause = nil
            if let prev, prev.bundle != bundle, prev.playing, !victims.contains(prev.bundle) {
                victims.append(prev.bundle)
            }
            victims.removeAll { $0 == bundle }
            guard !victims.isEmpty else { return }
            if requireAudio {
                let p = PendingPause(incoming: bundle, victims: victims)
                pendingPause = p
                checkAudible(p.id, pid: pid, deadline: Date() + audioWait)
            } else {
                pause(victims)
            }
        } else {
            if let p = pendingPause, p.incoming == prev?.bundle {
                // Stopped before it ever made a sound: nothing was paused, nothing to resume.
                pendingPause = nil
                Log.shared.add("\(appName(p.incoming)) stopped before producing audio")
                return
            }
            if let prev, silentClaims.remove(prev.bundle) != nil { return }
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

    private func checkAudible(_ id: UUID, pid: pid_t, deadline: Date) {
        guard let p = pendingPause, p.id == id else { return }
        let audible = AudioOutput.isOutputting(bundle: p.incoming, pid: pid)
        if audible != false {
            pendingPause = nil
            if audible == nil { Log.shared.add("can't read audio output; pausing without check") }
            pause(p.victims)
            onChange?()
        } else if Date() >= deadline {
            pendingPause = nil
            silentClaims.insert(p.incoming)
            let names = p.victims.map(appName).joined(separator: ", ")
            Log.shared.add("\(appName(p.incoming)) claimed Now Playing but produced no audio; not pausing \(names)")
            onChange?()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.checkAudible(id, pid: pid, deadline: deadline)
            }
        }
    }

    private func pause(_ victims: [String]) {
        for v in victims where control(v, .pause) {
            pausedStack.removeAll { $0 == v }
            pausedStack.append(v)
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
        pendingPause = nil
        silentClaims.removeAll()
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
        coordinator.requireAudio = defaults.object(forKey: "requireAudio") as? Bool ?? true

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
        menu.addItem(toggle("Only pause when the new app makes sound",
                            coordinator.requireAudio, #selector(toggleRequireAudio)))
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

    @objc private func toggleRequireAudio() {
        coordinator.requireAudio.toggle()
        defaults.set(coordinator.requireAudio, forKey: "requireAudio")
        Log.shared.add("audio check \(coordinator.requireAudio ? "on" : "off")")
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
