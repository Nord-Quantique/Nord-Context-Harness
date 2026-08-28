// Nord Context — V1: a launcher.
//
// The context bundle already renders itself: _edit/server.py serves it and
// injects the authoring layer. Everything this app does is spare the person a
// terminal. It starts that server, tells them whether it is up, and opens it.
//
// Deliberately not here: authentication and repository sync. Those are V2, and
// keeping them out means this version has nothing to configure and nothing that
// can fail while someone is trying to read a page.

import AppKit
import Foundation

// MARK: - where the bundle lives

enum Repo {
    /// Baked in at build time, overridable without rebuilding — so moving the
    /// .app somewhere tidy does not break it.
    static let compiledDefault = COMPILED_REPO_PATH

    static var path: String {
        if let env = ProcessInfo.processInfo.environment["NORD_CONTEXT_REPO"], isValid(env) { return env }
        if let saved = UserDefaults.standard.string(forKey: "repoPath"), isValid(saved) { return saved }
        return compiledDefault
    }

    static func isValid(_ p: String) -> Bool {
        FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent("index.html"))
    }

    static func remember(_ p: String) { UserDefaults.standard.set(p, forKey: "repoPath") }
}

/// Where server.py and shim.js live. They are identical for every store, so they
/// sit once in the harness repository rather than duplicated into each one — which
/// means the app has to carry both paths, not just the store.
enum Runtime {
    static var path: String {
        UserDefaults.standard.string(forKey: "runtimePath") ?? COMPILED_RUNTIME_PATH
    }
    static var isValid: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("server.py"))
    }
}

/// 8137 is the reader port. The admin server — the working bundle, where documents
/// are actually authored — defaults to 8136, so the two never contend for one port
/// and the port itself says which server answered.
/// Reader serves a published store read-only; admin serves the working bundle,
/// where documents are authored. Fixed at build time so one installed app is one
/// mode — two apps can sit side by side without arguing over a port or a menu.
let IS_READER = COMPILED_IS_READER

/// The port names the mode: 8137 reader, 8136 admin. They never contend.
var PORT: Int {
    let n = UserDefaults.standard.integer(forKey: "port")
    return n > 0 ? n : (IS_READER ? 8137 : 8136)
}
var siteURL: URL { URL(string: "http://localhost:\(PORT)/index.html")! }


// MARK: - staying current

/// Two branches, and the app moves between them.
///
///   main   the published content, kept exactly at origin/main
///   local  anything edited here, carried on its own branch
///
/// Content is pulled seamlessly and without asking. Edits are never merged into
/// main and never discarded: the first edit moves onto `local`, main is reset to
/// what was published, and the menu offers a way back. Comments and other saved
/// artefacts sit outside git in a store, so no branch change can touch them.
enum SyncState {
    case unknown
    case current(Date)                  // on main, matching what was published
    case updated(Int, Date)             // pulled n commits
    case carried(Int, Date)             // edits moved to `local`, then pulled
    case onLocal(Int)                   // viewing local work; n newer upstream
    case authoring(Int)                 // the machine content is written on
    case offline(String)
    case failed(String)

    var line: String {
        switch self {
        case .unknown:              return "Not checked yet"
        case .current(let t):       return "Latest content · checked \(SyncState.ago(t))"
        case .updated(let n, _):    return "Updated · \(n) new commit\(n == 1 ? "" : "s")"
        case .carried(let n, _):    return "Your edits moved to “My changes” · pulled \(n)"
        case .onLocal(let n):       return n == 0 ? "Viewing your changes"
                                                  : "Viewing your changes · \(n) newer published"
        case .authoring(let n):     return n == 0 ? "Authoring copy · nothing new"
                                                  : "Authoring copy · \(n) newer published, not pulled"
        case .offline(let why):     return why
        case .failed(let why):      return why
        }
    }
    var isProblem: Bool {
        switch self { case .offline, .failed: return true; default: return false }
    }
    static func ago(_ t: Date) -> String {
        let s = Int(Date().timeIntervalSince(t))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }
}

enum Git {
    static let localBranch = "local"

    /// Never let git open a prompt: a launcher that hangs waiting for a password
    /// nobody can see is worse than one that reports it cannot reach the remote.
    @discardableResult
    static func run(_ args: [String], in dir: String, timeout: TimeInterval = 30) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "could not run git") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate(); return (-1, "timed out") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func branch(_ dir: String) -> String { run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir).1 }
    static func isDirty(_ dir: String) -> Bool { !run(["status", "--porcelain"], in: dir).1.isEmpty }
    /// A store ships the reading runtime only. A copy that also has the authoring
    /// layer is where content is *written*, and parking its work on a branch or
    /// resetting it to the published copy would be reaching into someone's desk.
    /// Such a copy is reported on and never modified.
    static func isAuthoringCopy(_ dir: String) -> Bool {
        FileManager.default.fileExists(
            atPath: (dir as NSString).appendingPathComponent("_edit/shim.js"))
    }

    static func hasLocalBranch(_ dir: String) -> Bool {
        run(["rev-parse", "--verify", "--quiet", localBranch], in: dir).0 == 0
    }
    static func upstream(_ dir: String) -> String {
        let r = run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: dir)
        return r.0 == 0 ? r.1 : "origin/main"
    }
    static func behind(_ dir: String, _ up: String) -> Int {
        Int(run(["rev-list", "--count", "HEAD..\(up)"], in: dir).1) ?? 0
    }

    /// Pull the published content, seamlessly. Edits are carried to `local` first
    /// so main can be set to exactly what was published without losing anything.
    static func sync(_ dir: String) -> SyncState {
        guard run(["remote"], in: dir).1.isEmpty == false else { return .offline("No remote to pull from") }
        let up = upstream(dir)
        if run(["fetch", "--quiet", "origin"], in: dir, timeout: 45).0 != 0 {
            return .offline("Cannot reach the remote — showing the copy you have")
        }

        if isAuthoringCopy(dir) {
            return .authoring(behind(dir, up))
        }

        // Someone reading their own work is left alone; the menu says how far the
        // published copy has moved and offers the way back.
        if branch(dir) == localBranch {
            let n = Int(run(["rev-list", "--count", "HEAD..\(up)"], in: dir).1) ?? 0
            return .onLocal(n)
        }

        var carried = false
        if isDirty(dir) {
            let target = hasLocalBranch(dir) ? ["checkout", localBranch] : ["checkout", "-b", localBranch]
            guard run(target, in: dir).0 == 0 else {
                return .failed("Local edits could not be parked — leaving them alone")
            }
            run(["add", "-A"], in: dir)
            run(["-c", "user.email=local@nord", "-c", "user.name=Nord Context",
                 "commit", "-m", "Local changes"], in: dir)
            guard run(["checkout", "-"], in: dir).0 == 0 else {
                return .failed("Edits saved on “My changes”, but could not return to the published copy")
            }
            carried = true
        }

        let n = behind(dir, up)
        if n == 0 && !carried { return .current(Date()) }
        // main is a mirror of what was published, so it is set rather than merged
        guard run(["reset", "--hard", up], in: dir, timeout: 60).0 == 0 else {
            return .failed("Could not update to the published copy")
        }
        return carried ? .carried(n, Date()) : .updated(n, Date())
    }

    static func viewLocal(_ dir: String) -> String? {
        guard hasLocalBranch(dir) else { return "There are no local changes yet" }
        return run(["checkout", localBranch], in: dir).0 == 0 ? nil : "Could not switch to your changes"
    }

    static func viewPublished(_ dir: String) -> String? {
        let up = upstream(dir)
        let target = up.hasPrefix("origin/") ? String(up.dropFirst("origin/".count)) : "main"
        return run(["checkout", target], in: dir).0 == 0 ? nil : "Could not switch to the published copy"
    }
}

// MARK: - the server process

final class Server {
    private var task: Process?
    /// True when this app started it. Something already listening is used as-is
    /// rather than fought with, so a terminal the person left open still works.
    private(set) var ownsProcess = false

    var isReachable: Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(PORT)/")!)
        req.timeoutInterval = 0.6
        req.httpMethod = "HEAD"
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse) != nil
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.0)
        return ok
    }

    @discardableResult
    func start() -> String? {
        if isReachable { ownsProcess = false; return nil }          // already up
        guard Repo.isValid(Repo.path) else {
            return "No context bundle at \(Repo.path)"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // The app is what a reader loads, so it starts the server in reader mode:
        // comments and zoom, nothing else. Authoring runs the server from a terminal.
        var argv = ["python3", (Runtime.path as NSString).appendingPathComponent("server.py"),
                    "--store", Repo.path, "--port", "\(PORT)"]
        if IS_READER { argv.append("--reader") }
        p.arguments = argv
        p.currentDirectoryURL = URL(fileURLWithPath: Repo.path)

        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(IS_READER ? "nord-context-server.log"
                                  : "nord-context-admin-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = h
            p.standardError = h
        }
        do { try p.run() } catch { return "Could not start: \(error.localizedDescription)" }
        task = p
        ownsProcess = true
        recordPID(p.processIdentifier)

        // give it a moment to bind before reporting a state
        for _ in 0..<25 {
            if isReachable { return nil }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return "Server did not answer on port \(PORT)"
    }

    private var pidFile: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(IS_READER ? "nord-context-server.pid"
                                              : "nord-context-admin-server.pid")
    }

    private func recordPID(_ pid: Int32) {
        try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    /// A force quit cannot be caught, so the child outlives the app and keeps the
    /// port. The next launch finds it by PID and clears it before starting.
    func reapOrphan() {
        // names this app has had before, so a server left by an older build is
        // still cleared rather than left holding the port
        let legacy = ["nord-quantext-server.pid"].map {
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent($0)
        }
        for f in [pidFile] + legacy { reap(f) }
    }

    private func reap(_ pidFile: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0 else { return }
        kill(pid, SIGTERM)
        for _ in 0..<20 where kill(pid, 0) == 0 { usleep(100_000) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    func stop() {
        guard let p = task, p.isRunning else { task = nil; return }
        p.terminate()
        p.waitUntilExit()
        task = nil
        ownsProcess = false
        try? FileManager.default.removeItem(at: pidFile)
    }
}


// MARK: - the launcher updating itself

/// A pull can bring a newer launcher source than the binary that is running.
/// There is no signed release channel yet, so "update" means rebuild from the
/// source already in the working copy — which is honest, and needs no
/// notarisation to be useful.
enum SelfUpdate {
    static func sourceIsNewer() -> Bool {
        let fm = FileManager.default
        guard let binPath = Bundle.main.executableURL?.path,
              let bin = try? fm.attributesOfItem(atPath: binPath)[.modificationDate] as? Date
        else { return false }
        let repo = Repo.path as NSString
        for rel in ["app/NordContext.swift", "app/build.sh", "app/icon/icon.html"] {
            let f = repo.appendingPathComponent(rel)
            if let d = try? fm.attributesOfItem(atPath: f)[.modificationDate] as? Date, d > bin {
                return true
            }
        }
        return false
    }

    /// Build, then hand off to a detached shell that waits for this process to go
    /// away before reopening — an app cannot replace and relaunch itself in place.
    static func rebuildAndRelaunch() -> String? {
        let script = (Repo.path as NSString).appendingPathComponent("app/build.sh")
        guard FileManager.default.isExecutableFile(atPath: script) else {
            return "No app/build.sh in the bundle"
        }
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = [script]
        build.currentDirectoryURL = URL(fileURLWithPath: Repo.path)
        let pipe = Pipe(); build.standardOutput = pipe; build.standardError = pipe
        do { try build.run() } catch { return "Could not run the build" }
        build.waitUntilExit()
        if build.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return "Build failed: " + out.suffix(120)
        }
        let appPath = (Repo.path as NSString).appendingPathComponent("app/build/Nord Context.app")
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/bash")
        relaunch.arguments = ["-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(appPath)\""]
        try? relaunch.run()
        return nil
    }
}

// MARK: - the menu bar

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusItem.self
    var statusItem: NSStatusItem!
    let server = Server()
    var timer: Timer?
    var signalSources: [DispatchSourceSignal] = []
    var sync: SyncState = .unknown
    var syncTimer: Timer?
    var syncing = false
    var launcherStale = false
    var onLocalBranch = false
    var hasLocal = false

    func applicationDidFinishLaunching(_ n: Notification) {
        // .regular so it appears in the Dock as well as the menu bar. A Dock icon
        // with no window is only sensible because clicking it reopens the site.
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        installSignalHandlers()
        server.reapOrphan()                                     // left behind by a force quit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            if let img = NSImage(systemSymbolName: "circle.hexagongrid",
                                 accessibilityDescription: "Nord Context") {
                img.isTemplate = true
                b.image = img
            } else {
                b.title = "NQ"          // a symbol that will not load must not leave a
            }                           // zero-width, invisible menu bar item
            b.toolTip = "Nord Context"
        }
        rebuildMenu(status: "Starting…")

        DispatchQueue.global(qos: .userInitiated).async {
            let err = self.server.start()
            DispatchQueue.main.async {
                if let err { self.rebuildMenu(status: err, failed: true) }
                else { self.refresh(); self.openSite() }
            }
        }
        // check for content updates shortly after launch, then every five minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkSync() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.checkSync()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let up = self?.server.isReachable ?? false
                DispatchQueue.main.async { self?.refresh(up: up) }
            }
        }
    }

    /// Double-clicking a menu-bar app that is already running does not launch it
    /// again — it reopens it. Without this the click appears to do nothing, because
    /// there is no dock icon and no window to bring forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSite()
        return true
    }

    /// A Dock app gets an application menu whether or not one is supplied. Without
    /// this it renders as an empty bar, which reads as a broken app.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nord Context",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, "Hide Nord Context", #selector(NSApplication.hide(_:)), "h").target = NSApp
        appMenu.addItem(.separator())
        add(appMenu, "Quit Nord Context", #selector(quit), "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let ctxItem = NSMenuItem()
        let ctx = NSMenu(title: "Context")
        add(ctx, "Open Context", #selector(openSite), "o")
        add(ctx, "Check for Updates", #selector(checkSync), "u")
        add(ctx, "Restart Server", #selector(restart), "r")
        ctx.addItem(.separator())
        add(ctx, "Reveal Store in Finder", #selector(reveal), "")
        add(ctx, "Open Server Log", #selector(openLog), "")
        add(ctx, "Choose Store Folder…", #selector(chooseFolder), "")
        ctxItem.submenu = ctx
        main.addItem(ctxItem)

        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ n: Notification) { server.stop() }

    /// SIGTERM arrives on logout and from pkill. Without this the app dies and the
    /// server it started does not.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.server.stop()
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func refresh(up: Bool? = nil) {
        let running = up ?? server.isReachable
        rebuildMenu(status: running ? "Running on port \(PORT)" : "Not running", failed: !running)
    }

    func rebuildMenu(status: String, failed: Bool = false) {
        let m = NSMenu()

        let head = NSMenuItem(title: "Nord Context", action: nil, keyEquivalent: "")
        head.attributedTitle = NSAttributedString(
            string: IS_READER ? "Nord Context" : "Nord Context — Admin",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        m.addItem(head)

        // One line: the status pill, then what the port is. The two servers used to
        // share a port and the only symptom was reading the wrong content, so the
        // store and port belong next to the thing that says whether it is up.
        let store = (Repo.path as NSString).lastPathComponent
        let line = NSMutableAttributedString(
            string: (failed ? "⚠︎  " : "●  ") + status,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: failed ? NSColor.systemOrange : NSColor.systemGreen])
        line.append(NSAttributedString(
            string: "   ·   \(store)",
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        let st = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        st.attributedTitle = line
        m.addItem(st)
        m.addItem(.separator())

        let sy = NSMenuItem(title: sync.line, action: nil, keyEquivalent: "")
        sy.attributedTitle = NSAttributedString(
            string: (sync.isProblem ? "↯  " : "⤓  ") + sync.line,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: sync.isProblem ? NSColor.systemOrange
                                                          : NSColor.secondaryLabelColor])
        m.addItem(sy)
        m.addItem(.separator())

        add(m, "Open Context", #selector(openSite), "o")
        add(m, syncing ? "Checking…" : "Check for Updates", #selector(checkSync), "u").isEnabled = !syncing
        add(m, server.isReachable ? "Restart Server" : "Start Server", #selector(restart), "r")
        m.addItem(.separator())
        add(m, "Reveal Store in Finder", #selector(reveal), "")
        add(m, "Open Server Log", #selector(openLog), "")
        add(m, "Choose Store Folder…", #selector(chooseFolder), "")
        if launcherStale {
            add(m, "Rebuild Launcher", #selector(rebuildSelf), "")
        }
        m.addItem(.separator())
        add(m, "Quit", #selector(quit), "q")

        statusItem.menu = m
    }

    @discardableResult
    private func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        m.addItem(i)
        return i
    }

    @objc func checkSync() {
        guard !syncing else { return }
        syncing = true
        let dir = Repo.path
        DispatchQueue.global(qos: .utility).async {
            let result = Git.sync(dir)
            DispatchQueue.main.async {
                self.syncing = false
                self.sync = result
                self.launcherStale = SelfUpdate.sourceIsNewer()
                self.onLocalBranch = Git.branch(dir) == Git.localBranch
                self.hasLocal = Git.hasLocalBranch(dir)
                self.refresh()
            }
        }
    }

    @objc func rebuildSelf() {
        rebuildMenu(status: "Rebuilding the launcher…")
        DispatchQueue.global(qos: .userInitiated).async {
            let err = SelfUpdate.rebuildAndRelaunch()
            DispatchQueue.main.async {
                if let err {
                    self.rebuildMenu(status: err, failed: true)
                } else {
                    self.server.stop()
                    NSApp.terminate(nil)          // the detached shell reopens it
                }
            }
        }
    }

    @objc func viewLocal()     { switchBranch(Git.viewLocal(Repo.path)) }
    @objc func viewPublished() { switchBranch(Git.viewPublished(Repo.path)) }

    private func switchBranch(_ err: String?) {
        if let err { rebuildMenu(status: err, failed: true); return }
        checkSync()
        openSite()
    }

    @objc func openSite() { NSWorkspace.shared.open(siteURL) }

    @objc func restart() {
        rebuildMenu(status: "Restarting…")
        DispatchQueue.global(qos: .userInitiated).async {
            self.server.stop()
            let err = self.server.start()
            DispatchQueue.main.async {
                if let err { self.rebuildMenu(status: err, failed: true) } else { self.refresh() }
            }
        }
    }

    @objc func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Repo.path)
    }

    @objc func openLog() {
        let p = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(IS_READER ? "nord-context-server.log"
                                  : "nord-context-admin-server.log")
        NSWorkspace.shared.open(p)
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the store folder — the one containing index.html"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Repo.isValid(url.path) else {
            let a = NSAlert()
            a.messageText = "That folder has no index.html in it."
            a.runModal()
            return
        }
        Repo.remember(url.path)
        restart()
    }

    @objc func quit() { server.stop(); NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
