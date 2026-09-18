import AppKit
import Darwin
import Foundation

/// Enumerates every process and measures CPU + memory. CPU% is a delta between
/// two samples, so the first call after `reset()` only primes the baseline.
/// Not thread-safe by itself — HeatModel calls it from one serial queue.
final class Sampler {
    private struct Prev { let ticks: UInt64; let at: UInt64 }
    private struct Identity {
        let start: Int
        let name: String
        let path: String?
        let icon: NSImage?
    }

    private var prevProc: [pid_t: Prev] = [:]
    private var prevGPU: [pid_t: Prev] = [:]     // ticks = GPU nanoseconds, at = wall nanoseconds
    /// Exponentially smoothed CPU / GPU per pid. A one-second spike should not
    /// reshuffle the whole list; sustained load still shows within two samples.
    private var smoothCPU: [pid_t: Double] = [:]
    private var smoothGPU: [pid_t: Double] = [:]
    private let smoothing = 0.45   // weight of the newest sample
    private var identityCache: [pid_t: Identity] = [:]
    private var iconCache: [String: NSImage] = [:]
    private let metrics = SystemMetrics()
    private let ownUID = getuid()
    private let tickNanos: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        tickNanos = Double(tb.numer) / Double(tb.denom)
    }

    func reset() {
        prevProc.removeAll()
        prevGPU.removeAll()
        smoothCPU.removeAll()
        smoothGPU.removeAll()
        metrics.reset()
    }

    private func smooth(_ raw: Double, previous: Double?) -> Double {
        guard let p = previous else { return raw }
        return p + (raw - p) * smoothing
    }

    func sample() -> Snapshot {
        let now = mach_continuous_time()   // same timebase as rusage tick counters
        let kinfos = Self.listProcesses()
        var procs: [ProcSnapshot] = []
        procs.reserveCapacity(kinfos.count)
        var next: [pid_t: Prev] = [:]
        var nextSmoothCPU: [pid_t: Double] = [:]
        var needsPS = false

        for var k in kinfos {
            let pid = k.kp_proc.p_pid
            let ppid = k.kp_eproc.e_ppid
            let uid = k.kp_eproc.e_ucred.cr_uid
            let ident = identity(for: pid, kinfo: &k)
            let isOwn = uid == ownUID

            if isOwn, let ru = Self.rusage(pid) {
                let ticks = ru.ri_user_time + ru.ri_system_time
                next[pid] = Prev(ticks: ticks, at: now)
                var cpu: Double? = nil
                if let p = prevProc[pid], now > p.at, ticks >= p.ticks {
                    let raw = Double(ticks - p.ticks) / Double(now - p.at) * 100
                    let s = smooth(raw, previous: smoothCPU[pid])
                    nextSmoothCPU[pid] = s
                    cpu = s
                }
                procs.append(ProcSnapshot(pid: pid, ppid: ppid, uid: uid, name: ident.name, path: ident.path,
                                          icon: ident.icon, cpu: cpu, memory: ru.ri_phys_footprint,
                                          source: .native, isOwn: true))
            } else {
                needsPS = true
                procs.append(ProcSnapshot(pid: pid, ppid: ppid, uid: uid, name: ident.name, path: ident.path,
                                          icon: ident.icon, cpu: nil, memory: 0, source: .ps, isOwn: isOwn))
            }
        }
        prevProc = next
        smoothCPU = nextSmoothCPU
        identityCache = identityCache.filter { key, _ in next[key] != nil || procs.contains { $0.pid == key } }

        if needsPS {
            let ps = Self.psStats()
            for i in procs.indices where procs[i].source == .ps {
                if let s = ps[procs[i].pid] {
                    procs[i].cpu = s.cpu
                    procs[i].memory = s.rssKB * 1024
                }
            }
        }

        // GPU: delta of each process's accumulated GPU nanoseconds over wall time.
        let gpuTime = metrics.gpuClientTime()
        let nowNS = UInt64(Double(now) * tickNanos)
        var nextGPU: [pid_t: Prev] = [:]
        var nextSmoothGPU: [pid_t: Double] = [:]
        var gpuCount = 0
        for i in procs.indices {
            let pid = procs[i].pid
            guard let t = gpuTime[pid] else { continue }
            procs[i].usesGPU = true
            gpuCount += 1
            nextGPU[pid] = Prev(ticks: t, at: nowNS)
            if let p = prevGPU[pid], nowNS > p.at, t >= p.ticks {
                let raw = Double(t - p.ticks) / Double(nowNS - p.at) * 100
                let s = smooth(raw, previous: smoothGPU[pid])
                nextSmoothGPU[pid] = s
                procs[i].gpu = s
            }
        }
        prevGPU = nextGPU
        smoothGPU = nextSmoothGPU

        let groups = Self.group(procs)
        return Snapshot(takenAt: Date(), system: metrics.sample(gpuProcessCount: gpuCount),
                        processes: procs, groups: groups)
    }

    // MARK: - Grouping

    private static func group(_ procs: [ProcSnapshot]) -> [ProcGroup] {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func root(of pid: pid_t) -> pid_t {
            var cur = pid
            var steps = 0
            while steps < 64, let p = byPid[cur], p.ppid > 1, byPid[p.ppid] != nil {
                cur = p.ppid
                steps += 1
            }
            return cur
        }
        var members: [pid_t: [ProcSnapshot]] = [:]
        for p in procs { members[root(of: p.pid), default: []].append(p) }
        return members.compactMap { rootPid, list in
            guard let r = byPid[rootPid] else { return nil }
            let sorted = list.sorted { ($0.cpu ?? 0, $0.memory) > ($1.cpu ?? 0, $1.memory) }
            return ProcGroup(root: r, members: sorted)
        }
    }

    // MARK: - Identity (name, path, icon), cached per pid + start time

    private func identity(for pid: pid_t, kinfo k: inout kinfo_proc) -> Identity {
        let start = Int(k.kp_proc.p_un.__p_starttime.tv_sec)
        if let cached = identityCache[pid], cached.start == start { return cached }

        let comm = withUnsafeBytes(of: &k.kp_proc.p_comm) { buf in
            String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
        }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path: String? = n > 0 ? String(cString: buf) : nil

        var name = path.map { ($0 as NSString).lastPathComponent } ?? comm
        if name.isEmpty { name = comm }
        if pid == 0 { name = "kernel_task" }

        var icon: NSImage? = nil
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let n = app.localizedName, !n.isEmpty { name = n }
            icon = app.icon
        }
        if icon == nil, let path, let bundle = Self.outermostAppBundle(in: path) {
            if let cached = iconCache[bundle] {
                icon = cached
            } else {
                let img = NSWorkspace.shared.icon(forFile: bundle)
                iconCache[bundle] = img
                icon = img
            }
        }
        let id = Identity(start: start, name: name, path: path, icon: icon)
        identityCache[pid] = id
        return id
    }

    /// `/Applications/Foo.app/Contents/Frameworks/Bar.app/...` → `/Applications/Foo.app`
    private static func outermostAppBundle(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    // MARK: - Kernel queries

    private static func listProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buf.count * stride
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
        return Array(buf.prefix(size / stride))
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { p in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, p)
            }
        }
        return rc == 0 ? info : nil
    }

    /// One `ps` for the processes libproc won't show us. %cpu here is the
    /// kernel's decaying average, not our exact interval — good enough for
    /// daemons, and the only unprivileged way to see them.
    private static func psStats() -> [pid_t: (cpu: Double, rssKB: UInt64)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,%cpu=,rss="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [pid_t: (cpu: Double, rssKB: UInt64)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]), let rss = UInt64(parts[2]) else { continue }
            out[pid] = (cpu, rss)
        }
        return out
    }
}
