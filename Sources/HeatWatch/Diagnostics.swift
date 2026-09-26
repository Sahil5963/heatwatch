import AppKit
import Darwin
import Foundation

// What is wrong with a process or an app tree, beyond "it is using CPU right
// now": automation browsers that were never closed, hung apps, orphaned
// leftovers whose terminal is long gone, and processes that have been burning
// a core for hours. Everything here is a plain classification of one
// snapshot — no background work, no extra permissions.

enum Severity: Int, Comparable {
    case info = 0, warn, hot
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

struct Issue: Hashable {
    enum Kind: Int, Comparable {
        case unresponsive = 0, burning, pegged, automation, orphaned, idle
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    let kind: Kind
    let severity: Severity
    let short: String    // row pill: "agent-browser 4d", "not responding"
    let detail: String   // Issues list: "agent-browser · running 4d 2h"
}

/// A browser or driver that exists to be scripted, not used by a person.
struct AutomationKind: Hashable {
    let name: String     // "agent-browser", "Playwright", "DevTools-driven browser"
    let short: String    // pill text
    let isTool: Bool     // a known tool outranks a generic flag when both are present in a group
}

enum Age {
    /// "4d 2h", "3h 12m", "12m", "45s"
    static func text(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h \(m % 60)m" }
        return "\(h / 24)d \(h % 24)h"
    }

    /// Largest unit only: "4d", "3h", "12m".
    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

enum Diagnostics {
    static let orphanMinAge: TimeInterval = 120       // younger than this, the parent may just be mid-exit
    static let burningMinAge: TimeInterval = 600      // lifetime average needs some lifetime
    static let burningCores = 0.5                     // average cores over the lifetime
    static let peggedCPU = 90.0                       // % of one core, smoothed, while the panel is open
    static let peggedMin: TimeInterval = 30

    // MARK: Automation

    /// Known tools by path first, then the flags a scripted browser is launched with.
    static func automation(path: String?, args: [String]) -> AutomationKind? {
        let p = (path ?? "").lowercased()
        let tools: [(String, String)] = [
            ("agent-browser", "agent-browser"), ("ms-playwright", "Playwright"), ("/playwright", "Playwright"),
            ("puppeteer", "Puppeteer"), ("chromedriver", "WebDriver"), ("geckodriver", "WebDriver"),
            ("msedgedriver", "WebDriver"), ("safaridriver", "WebDriver"), ("selenium", "Selenium"),
            ("lighthouse", "Lighthouse"), ("chrome-headless-shell", "headless Chrome"),
        ]
        for (needle, name) in tools where p.contains(needle) {
            return AutomationKind(name: name, short: name, isTool: true)
        }
        // Launch flags only mean "scripted" on a real browser. Electron apps
        // and node wrappers run with a DevTools port all day in development.
        guard isBrowser(path: p) else { return nil }
        for a in args {
            if a.hasPrefix("--remote-debugging-port") || a.hasPrefix("--remote-debugging-pipe") {
                return AutomationKind(name: "DevTools-driven browser", short: "automated", isTool: false)
            }
            if a == "--headless" || a.hasPrefix("--headless=") {
                return AutomationKind(name: "headless browser", short: "headless", isTool: false)
            }
            if a == "--enable-automation" {
                return AutomationKind(name: "automated browser", short: "automated", isTool: false)
            }
            if a.hasPrefix("--user-data-dir="), a.contains("/var/folders/") || a.contains("/tmp/") || a.contains("/T/") {
                return AutomationKind(name: "temporary-profile browser", short: "automated", isTool: false)
            }
        }
        return nil
    }

    private static let browserMarks = ["google chrome", "chromium", "brave browser", "microsoft edge", "chrome for testing",
                                       "chrome-headless-shell", "firefox", "vivaldi", "opera", "arc.app"]

    static func isBrowser(path: String) -> Bool {
        browserMarks.contains { path.contains($0) }
    }

    // MARK: Orphans

    /// An own process re-parented to launchd that launchd does not manage: its
    /// real parent (a terminal, an agent, a script) exited and left it behind.
    /// System binaries and anything inside a bundle are left alone — those are
    /// XPC services and app helpers launchd starts in other domains.
    static func isOrphan(_ p: ProcSnapshot, launchd: LaunchdRegistry, at now: Date) -> Bool {
        guard p.isOwn, p.ppid == 1, p.pid > 1, let age = p.age(at: now), age >= orphanMinAge,
              let path = p.path, !isSystemPath(path), !isBundled(path) else { return false }
        return !launchd.isManaged(p.pid)
    }

    static func isSystemPath(_ path: String) -> Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/Library/Developer/", "/private/var/"]
            .contains { path.hasPrefix($0) }
    }

    static func isBundled(_ path: String) -> Bool {
        path.contains(".app/") || path.contains(".appex/") || path.contains(".xpc/")
    }

    /// `/Applications/Foo.app/Contents/Frameworks/Bar.app/...` → `/Applications/Foo.app`
    static func outermostAppBundle(in path: String?) -> String? {
        guard let path, let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// A generic flag (remote debugging, headless…) only means "scripted" when
    /// the browser was started by something outside its own app: an agent
    /// daemon, a terminal, a test runner. An app driving its *own* embedded
    /// renderer that way (ChatGPT's Codex view, Electron dev tools) is not
    /// automation, so helpers launched by a parent in the same bundle keep
    /// only a tool-based kind.
    static func keepsAutomation(_ p: ProcSnapshot, parent: ProcSnapshot?) -> Bool {
        guard let a = p.automation else { return false }
        if a.isTool { return true }
        guard let mine = outermostAppBundle(in: p.path) else { return true }
        return mine != outermostAppBundle(in: parent?.path)
    }

    // MARK: Classification

    static func issues(for p: ProcSnapshot, at now: Date) -> [Issue] {
        var out: [Issue] = []
        if p.unresponsive {
            out.append(Issue(kind: .unresponsive, severity: .hot, short: "not responding",
                             detail: "not responding to events"))
        }
        if let age = p.age(at: now) {
            if let b = burning(cpuSeconds: p.cpuSeconds, age: age) { out.append(b) }
            if let a = p.automation { out.append(automation(a, age: age)) }
            if p.orphaned {
                out.append(orphan(avgCPU: age > 0 ? p.cpuSeconds / age * 100 : 0, current: p.cpu ?? 0, age: age))
            }
        }
        return sorted(out)
    }

    static func issues(for g: ProcGroup, peggedFor: TimeInterval?, at now: Date) -> [Issue] {
        var out: [Issue] = []
        let age = g.root.age(at: now)
        if let m = g.members.first(where: \.unresponsive) {
            out.append(Issue(kind: .unresponsive, severity: .hot, short: "not responding",
                             detail: m.pid == g.root.pid ? "not responding to events" : "\(m.name) is not responding"))
        }
        if let age, let b = burning(cpuSeconds: g.cpuSeconds, age: age) { out.append(b) }
        if let s = peggedFor, s >= peggedMin {
            out.append(Issue(kind: .pegged, severity: s >= 300 ? .hot : .warn, short: "pegged \(Age.short(s))",
                             detail: "≥\(Int(peggedCPU))% CPU for \(Age.text(s)) while watching"))
        }
        if let age, let kind = automationKind(of: g) { out.append(automation(kind, age: age)) }
        if let age, g.root.orphaned {
            out.append(orphan(avgCPU: age > 0 ? g.cpuSeconds / age * 100 : 0, current: g.cpu, age: age))
        }
        return sorted(out)
    }

    private static func sorted(_ issues: [Issue]) -> [Issue] {
        issues.sorted { a, b in a.severity != b.severity ? a.severity > b.severity : a.kind < b.kind }
    }

    private static func automationKind(of g: ProcGroup) -> AutomationKind? {
        if let r = g.root.automation { return r }
        let kinds = g.members.compactMap(\.automation)
        return kinds.first(where: \.isTool) ?? kinds.first
    }

    private static func automation(_ kind: AutomationKind, age: TimeInterval) -> Issue {
        let severity: Severity = age >= 86400 ? .hot : age >= 3600 ? .warn : .info
        return Issue(kind: .automation, severity: severity, short: "\(kind.short) \(Age.short(age))",
                     detail: kind.isTool ? "\(kind.name) session" : kind.name)
    }

    /// Lifetime average — the figure `ps %cpu` shows — catches a process that
    /// has been cooking for days even if this sample happens to be quiet.
    private static func burning(cpuSeconds: Double, age: TimeInterval) -> Issue? {
        guard age >= burningMinAge else { return nil }
        let cores = cpuSeconds / age
        guard cores >= burningCores else { return nil }
        let severity: Severity = cores >= 1 && age >= 3600 ? .hot : .warn
        let coresText = cores >= 1 ? String(format: " (%.1f cores)", cores) : ""
        return Issue(kind: .burning, severity: severity, short: "burning \(Age.short(age))",
                     detail: "avg \(Int((cores * 100).rounded()))% CPU\(coresText) since start")
    }

    private static func orphan(avgCPU: Double, current: Double, age: TimeInterval) -> Issue {
        if avgCPU < 1, current < 1 {
            return Issue(kind: .idle, severity: age >= 3600 ? .warn : .info, short: "idle \(Age.short(age))",
                         detail: "orphaned, parent gone · idle")
        }
        return Issue(kind: .orphaned, severity: .warn, short: "orphaned \(Age.short(age))",
                     detail: "orphaned, parent gone")
    }
}

/// Which of our processes launchd itself started (`launchctl list`: agents,
/// login items, every app opened through LaunchServices). A direct child of
/// launchd that is *not* in this list was re-parented there — an orphan.
/// `launchctl` is only spawned when a launchd child we have not judged yet is
/// old enough to judge, so a quiet machine never runs it again.
final class LaunchdRegistry {
    private var managed: Set<pid_t> = []
    private var judged: Set<pid_t> = []

    func reset() { judged.removeAll() }

    func update(candidates: [pid_t]) {
        if candidates.contains(where: { !judged.contains($0) }) { managed = Self.listPids() }
        judged = Set(candidates)
    }

    func isManaged(_ pid: pid_t) -> Bool { managed.contains(pid) }

    private static func listPids() -> Set<pid_t> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: Set<pid_t> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let first = line.split(separator: "\t", maxSplits: 1).first, let pid = pid_t(first) { out.insert(pid) }
        }
        return out
    }
}

/// WindowServer's own verdict on whether an app is draining its event queue —
/// the "Not Responding" Activity Monitor shows. Private SkyLight API, resolved
/// at runtime; if it is ever gone the probe just answers "no". WindowServer
/// only judges an app that has events waiting, so a hung app is flagged once
/// someone clicks or hovers it (about 15 s later), not merely for being idle.
final class ResponsivenessProbe {
    private struct PSN { var high: UInt32 = 0; var low: UInt32 = 0 }
    private typealias ConnFn = @convention(c) () -> Int32
    // Raw pointers: a C function type cannot mention a Swift struct.
    private typealias UnresponsiveFn = @convention(c) (Int32, UnsafeRawPointer) -> Bool
    private typealias PSNFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private let unresponsive: UnresponsiveFn?
    private let psnFor: PSNFn?
    private let connection: Int32

    init() {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let conn = dlsym(sky, "CGSMainConnectionID"),
              let check = dlsym(sky, "CGSEventIsAppUnresponsive"),
              let psn = dlsym(services, "GetProcessForPID") else {
            unresponsive = nil
            psnFor = nil
            connection = 0
            return
        }
        connection = unsafeBitCast(conn, to: ConnFn.self)()
        unresponsive = unsafeBitCast(check, to: UnresponsiveFn.self)
        psnFor = unsafeBitCast(psn, to: PSNFn.self)
    }

    func isUnresponsive(_ pid: pid_t) -> Bool {
        guard let unresponsive, let psnFor else { return false }
        var psn = PSN()
        return withUnsafeMutablePointer(to: &psn) { p in
            guard psnFor(pid, UnsafeMutableRawPointer(p)) == 0 else { return false }   // not a GUI app
            return unresponsive(connection, UnsafeRawPointer(p))
        }
    }
}

/// Command-line arguments of one of our own processes (`KERN_PROCARGS2`).
/// The buffer is reused; the sampler calls this from one serial queue.
final class ProcArgsReader {
    private var buffer: [UInt8]

    init() {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.argmax", &argmax, &size, nil, 0)
        buffer = [UInt8](repeating: 0, count: argmax > 0 ? Int(argmax) : 262_144)
    }

    func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let ok = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) == 0 }
        guard ok, size > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }   // executable path
        while i < size, buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        var start = i
        while i < size, args.count < argc {
            if buffer[i] == 0 {
                args.append(String(decoding: buffer[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }
}
