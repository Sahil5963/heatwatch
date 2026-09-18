import AppKit
import Foundation

/// Where a process's numbers came from.
/// - native: `proc_pid_rusage` — exact CPU over our sampling interval, physical footprint.
/// - ps: one `/bin/ps` call — used for processes owned by other users (root daemons,
///   WindowServer…) because libproc refuses them without root. `ps` is setuid.
enum ProcSource { case native, ps }

struct ProcSnapshot: Identifiable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String?
    let icon: NSImage?
    var cpu: Double?        // % of one core; nil = not measured yet
    var memory: UInt64      // bytes
    var source: ProcSource
    let isOwn: Bool         // owned by the current user → we can signal it
    var usesGPU = false     // holds an IOAccelerator client right now (IORegistry)
    var gpu: Double?        // % of the GPU over the interval; nil = not measured yet
    var id: pid_t { pid }
}

/// A process tree rooted at a direct child of launchd (or launchd/kernel_task
/// themselves). Chrome and its helpers, a terminal and everything it spawned,
/// an automation daemon and its browser — each is one group.
struct ProcGroup: Identifiable {
    let root: ProcSnapshot
    let members: [ProcSnapshot]   // sorted hottest first, root included
    var id: pid_t { root.pid }
    var name: String { root.name }
    var icon: NSImage? { root.icon ?? members.first(where: { $0.icon != nil })?.icon }
    var cpu: Double { members.reduce(0) { $0 + ($1.cpu ?? 0) } }
    var memory: UInt64 { members.reduce(0) { $0 + $1.memory } }
    var count: Int { members.count }
    var gpuCount: Int { members.filter(\.usesGPU).count }
    var gpu: Double { members.reduce(0) { $0 + ($1.gpu ?? 0) } }
    var canKill: Bool { members.contains { $0.isOwn } }
    /// Own processes, helpers first and the root last so a graceful quit reaches
    /// the parent after its children.
    var killablePids: [pid_t] {
        members.filter(\.isOwn)
            .sorted { ($0.pid == root.pid ? 1 : 0) < ($1.pid == root.pid ? 1 : 0) }
            .map(\.pid)
    }
}

struct SystemStats {
    var cpuPercent: Double?        // whole machine, 0…100
    var coreCount: Int
    var loadAverage: [Double]
    var gpuPercent: Double?        // IOAccelerator "Device Utilization %"
    var gpuMemoryInUse: UInt64?    // IOAccelerator "In use system memory", bytes
    var gpuCoreCount: Int?         // "gpu-core-count" on the GPU device node
    var gpuProcessCount: Int?      // processes holding a GPU context
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var memoryFreePercent: Int?    // kern.memorystatus_level, what `memory_pressure` prints
    var thermalState: ProcessInfo.ThermalState
    var dieTempMax: Double?        // hottest SoC die sensor, °C
    var dieTempAvg: Double?
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

struct Snapshot {
    let takenAt: Date
    let system: SystemStats
    let processes: [ProcSnapshot]
    let groups: [ProcGroup]
}
