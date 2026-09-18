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
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isSampling = false
    @Published var grouped = true
    @Published var mode: ListMode = .cpu
    @Published var expanded: Set<pid_t> = []
    @Published var pendingKill: KillRequest?
    @Published private(set) var notice: String?

    /// Screenshot scene, set by AppDelegate from HEATWATCH_CAPTURE before start():
    /// cpu | memory | gpu | expanded | confirm.
    var captureScenario: String?
    private var captureApplied = false

    let interval: TimeInterval = 2
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
    var visibleGroups: [ProcGroup] {
        guard let s = snapshot else { return [] }
        let groups = mode == .gpu ? s.groups.filter { $0.gpuCount > 0 } : s.groups
        let sorted = groups.sorted {
            switch mode {
            case .cpu: return ($0.cpu, $0.memory) > ($1.cpu, $1.memory)
            case .memory: return $0.memory > $1.memory
            case .gpu: return ($0.gpu, $0.cpu) > ($1.gpu, $1.cpu)
            }
        }
        return Array(sorted.prefix(40))
    }

    var visibleProcesses: [ProcSnapshot] {
        guard let s = snapshot else { return [] }
        let procs = mode == .gpu ? s.processes.filter(\.usesGPU) : s.processes
        let sorted = procs.sorted {
            switch mode {
            case .cpu: return ($0.cpu ?? 0, $0.memory) > ($1.cpu ?? 0, $1.memory)
            case .memory: return $0.memory > $1.memory
            case .gpu: return ($0.gpu ?? 0, $0.cpu ?? 0) > ($1.gpu ?? 0, $1.cpu ?? 0)
            }
        }
        return Array(sorted.prefix(60))
    }

    func toggleExpanded(_ pid: pid_t) {
        if expanded.contains(pid) { expanded.remove(pid) } else { expanded.insert(pid) }
    }

    var statusLine: String {
        guard let s = snapshot else { return "Sampling only while this panel is open" }
        let t = s.takenAt.formatted(date: .omitted, time: .standard)
        return "Sampled \(t) · live every \(Int(interval)) s while open, idle when closed"
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
