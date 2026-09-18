import AppKit
import Combine
import Foundation

enum ListMode: Hashable {
    case cpu, memory, gpu
}

struct KillRequest: Identifiable {
    let id = UUID()
    let title: String
    let pids: [pid_t]
    let memberNames: [String]
    let mode: KillMode
    let cpu: Double
}

/// View state + the sampling loop. `start()`/`stop()` are driven by the popover
/// showing and closing, so nothing is measured while the panel is hidden.
@MainActor
final class HeatModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot? { didSet { rebuildLists() } }
    @Published private(set) var isSampling = false
    @Published var grouped = true { didSet { rebuildLists() } }
    @Published var mode: ListMode = .cpu { didSet { rebuildLists() } }
    @Published var expanded: Set<pid_t> = []
    /// What the list shows, rebuilt once per sample (not per render) with
    /// order hysteresis so near-ties don't swap places every refresh.
    @Published private(set) var visibleGroups: [ProcGroup] = []
    @Published private(set) var visibleProcesses: [ProcSnapshot] = []
    private var lastGroupOrder: [pid_t: Int] = [:]
    private var lastProcessOrder: [pid_t: Int] = [:]
    @Published var pendingKill: KillRequest?
    @Published private(set) var notice: String?

    /// Screenshot scene, set by AppDelegate from HEATWATCH_CAPTURE before start():
    /// cpu | memory | gpu | expanded | confirm.
    var captureScenario: String?
    private var captureApplied = false

    /// Seconds between refreshes while the panel is open (1…10, default 5, remembered).
    @Published var interval: TimeInterval = HeatModel.storedInterval {
        didSet {
            UserDefaults.standard.set(interval, forKey: "refreshInterval")
            if active, timer != nil { startTimer() }
        }
    }
    private static var storedInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "refreshInterval")
        return (1...10).contains(v) ? v : 5
    }

    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "heatwatch.sampler", qos: .userInitiated)
    private var timer: Timer?
    private var active = false
    private var generation = 0

    // MARK: Lifecycle

    /// Opening the panel shows something immediately: the last snapshot if there
    /// is one (kept in memory, nothing runs while closed), otherwise the first
    /// sample with CPU/GPU still "—". CPU and GPU are deltas, so the first real
    /// figures follow 0.8 s later and the timer takes over from there.
    func start() {
        generation += 1
        let gen = generation
        active = true
        isSampling = true
        notice = nil
        switch captureScenario {
        case "memory": mode = .memory
        case "gpu": mode = .gpu
        case .some: mode = .cpu
        case nil: break
        }
        sampler.reset()
        let sampler = self.sampler
        let hadSnapshot = snapshot != nil
        queue.async {
            let baseline = sampler.sample()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.generation == gen else { return }
                if !hadSnapshot { self.snapshot = baseline }
                self.isSampling = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.active, self.generation == gen else { return }
                self.refresh()
                self.startTimer()
            }
        }
    }

    func stop() {
        active = false
        timer?.invalidate()
        timer = nil
        isSampling = false
        pendingKill = nil
    }

    func refresh() {
        guard active, !isSampling else { return }
        isSampling = true
        let gen = generation
        let sampler = self.sampler
        queue.async {
            let snap = sampler.sample()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSampling = false
                guard self.active, self.generation == gen else { return }
                self.snapshot = snap
                self.applyCaptureScenario()
            }
        }
    }

    /// Scenes that need data: expand the biggest app, or show the kill card for
    /// it (never confirmed — the card just sits there for the screenshot).
    private func applyCaptureScenario() {
        guard let scenario = captureScenario, !captureApplied,
              snapshot?.processes.contains(where: { $0.cpu != nil }) == true,   // wait for real CPU figures
              let top = visibleGroups.first(where: { $0.count > 1 && $0.canKill }) else { return }
        switch scenario {
        case "expanded":
            expanded.insert(top.id)
        case "confirm":
            requestKill(group: top, mode: .force)
        default:
            break
        }
        captureApplied = true
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Derived lists

    /// GPU mode lists the processes holding a GPU context, sorted by GPU %.
    private func rebuildLists() {
        guard let s = snapshot else {
            visibleGroups = []
            visibleProcesses = []
            return
        }
        let mode = self.mode

        let groups = mode == .gpu ? s.groups.filter { $0.gpuCount > 0 } : s.groups
        let sortedGroups = groups.sorted {
            switch mode {
            case .cpu: return ($0.cpu, $0.memory) > ($1.cpu, $1.memory)
            case .memory: return $0.memory > $1.memory
            case .gpu: return ($0.gpu, $0.cpu) > ($1.gpu, $1.cpu)
            }
        }
        let groupKey: (ProcGroup) -> Double = {
            switch mode {
            case .cpu: return $0.cpu
            case .memory: return Double($0.memory)
            case .gpu: return $0.gpu
            }
        }
        let stableGroups = Self.stabilize(Array(sortedGroups.prefix(40)), key: groupKey,
                                          previous: lastGroupOrder, memory: mode == .memory)
        lastGroupOrder = Dictionary(uniqueKeysWithValues: stableGroups.enumerated().map { ($1.id, $0) })
        visibleGroups = stableGroups

        let procs = mode == .gpu ? s.processes.filter(\.usesGPU) : s.processes
        let sortedProcs = procs.sorted {
            switch mode {
            case .cpu: return ($0.cpu ?? 0, $0.memory) > ($1.cpu ?? 0, $1.memory)
            case .memory: return $0.memory > $1.memory
            case .gpu: return ($0.gpu ?? 0, $0.cpu ?? 0) > ($1.gpu ?? 0, $1.cpu ?? 0)
            }
        }
        let procKey: (ProcSnapshot) -> Double = {
            switch mode {
            case .cpu: return $0.cpu ?? 0
            case .memory: return Double($0.memory)
            case .gpu: return $0.gpu ?? 0
            }
        }
        let stableProcs = Self.stabilize(Array(sortedProcs.prefix(60)), key: procKey,
                                         previous: lastProcessOrder, memory: mode == .memory)
        lastProcessOrder = Dictionary(uniqueKeysWithValues: stableProcs.enumerated().map { ($1.id, $0) })
        visibleProcesses = stableProcs
    }

    /// Order hysteresis: if two neighbours have swapped since the last sample
    /// but the gap between them is small (1 point or 15% for percentages, 8%
    /// for memory), keep their previous order. Stops near-ties from flickering.
    private static func stabilize<T: Identifiable>(_ items: [T], key: (T) -> Double,
                                                    previous: [T.ID: Int], memory: Bool) -> [T] where T.ID == pid_t {
        guard items.count > 1 else { return items }
        var out = items
        for i in 1..<out.count {
            let upper = out[i - 1], lower = out[i]
            guard let pu = previous[upper.id], let pl = previous[lower.id], pl < pu else { continue }
            let ku = key(upper), kl = key(lower)
            let tolerance = memory ? ku * 0.08 : max(1.0, ku * 0.15)
            if ku - kl <= tolerance { out.swapAt(i - 1, i) }
        }
        return out
    }

    func toggleExpanded(_ pid: pid_t) {
        if expanded.contains(pid) { expanded.remove(pid) } else { expanded.insert(pid) }
    }

    var statusLine: String {
        guard let s = snapshot else { return "Sampling only while this panel is open" }
        let t = s.takenAt.formatted(date: .omitted, time: .standard)
        return "Sampled \(t) · nothing runs while the panel is closed"
    }

    // MARK: Kill flow (always confirmed first)

    func requestKill(group: ProcGroup, mode: KillMode) {
        let own = group.members.filter(\.isOwn)
        pendingKill = KillRequest(title: group.name, pids: group.killablePids,
                                  memberNames: own.map { "\($0.name) · \($0.pid)" },
                                  mode: mode, cpu: group.cpu)
    }

    func requestKill(proc: ProcSnapshot, mode: KillMode) {
        pendingKill = KillRequest(title: proc.name, pids: [proc.pid],
                                  memberNames: ["\(proc.name) · \(proc.pid)"],
                                  mode: mode, cpu: proc.cpu ?? 0)
    }

    func cancelKill() { pendingKill = nil }

    func confirmKill() {
        guard let r = pendingKill else { return }
        pendingKill = nil
        let out = ProcessKiller.send(r.mode, to: r.pids)
        if out.failures.isEmpty {
            notice = "\(r.mode.pastTense) \(out.sent) process\(out.sent == 1 ? "" : "es") of \(r.title)"
        } else {
            notice = "\(out.sent) signalled, \(out.failures.count) failed — \(out.failures[0].reason)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.notice = nil }
    }
}
