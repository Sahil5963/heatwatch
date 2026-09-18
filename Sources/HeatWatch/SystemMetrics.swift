import Darwin
import Foundation
import IOKit

// Private IOKit HID API — the same route `Hot`, `stats` and `macmon` use to
// read the SoC die sensors on Apple silicon without root. Declared by symbol
// name; if Apple ever removes them the app just shows no temperature.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

private let kHIDTemperatureType: Int64 = 15
private let kHIDTemperatureField = Int32(kHIDTemperatureType << 16)

/// Machine-wide numbers: CPU, GPU, memory, thermal state, die temperature.
final class SystemMetrics {
    private var prevHost: (busy: UInt64, idle: UInt64)?
    private let pageSize: UInt64
    private let memoryTotal: UInt64
    private let coreCount: Int
    private var hidClient: AnyObject?
    private var tempServices: [AnyObject] = []
    private var hidProbed = false
    private var smoothCPU: Double?
    private var smoothGPU: Double?

    /// Same smoothing as the per-process figures, so the tiles and the list agree.
    private func smooth(_ raw: Double?, _ previous: inout Double?) -> Double? {
        guard let raw else { return previous }
        let s = previous.map { $0 + (raw - $0) * 0.45 } ?? raw
        previous = s
        return s
    }

    init() {
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        pageSize = UInt64(ps)

        var mem: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &sz, nil, 0)
        memoryTotal = mem

        coreCount = ProcessInfo.processInfo.activeProcessorCount
    }

    func reset() {
        prevHost = nil
        smoothCPU = nil
        smoothGPU = nil
    }

    func sample(gpuProcessCount: Int?) -> SystemStats {
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        let temps = temperatures()
        let gpu = gpuReading()
        return SystemStats(
            cpuPercent: smooth(hostCPU(), &smoothCPU),
            coreCount: coreCount,
            loadAverage: la,
            gpuPercent: smooth(gpu.utilization, &smoothGPU),
            gpuMemoryInUse: gpu.memoryInUse,
            gpuCoreCount: gpuCoreCount,
            gpuProcessCount: gpuProcessCount,
            memoryUsed: memoryUsed(),
            memoryTotal: memoryTotal,
            memoryFreePercent: memoryFreePercent(),
            thermalState: ProcessInfo.processInfo.thermalState,
            dieTempMax: temps?.max,
            dieTempAvg: temps?.avg)
    }

    // MARK: CPU

    private func hostCPU() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, idle: UInt64 = 0
        for i in 0..<Int(cpuCount) {
            let b = i * Int(CPU_STATE_MAX)
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[b + Int(state)])) }
            busy += tick(CPU_STATE_USER) + tick(CPU_STATE_SYSTEM) + tick(CPU_STATE_NICE)
            idle += tick(CPU_STATE_IDLE)
        }
        let prev = prevHost
        prevHost = (busy, idle)
        guard let prev else { return nil }
        let db = busy &- prev.busy, di = idle &- prev.idle
        guard db + di > 0 else { return nil }
        return Double(db) / Double(db + di) * 100
    }

    // MARK: GPU

    private struct GPUReading {
        var utilization: Double?
        var memoryInUse: UInt64?
    }

    private var gpuCoreCount: Int?

    /// Device-wide numbers from the accelerator's PerformanceStatistics. On a
    /// multi-GPU machine utilisation is the busiest device, memory is summed.
    private func gpuReading() -> GPUReading {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else {
            return GPUReading()
        }
        defer { IOObjectRelease(it) }
        var r = GPUReading()
        var entry = IOIteratorNext(it)
        while entry != 0 {
            if gpuCoreCount == nil { gpuCoreCount = Self.coreCount(above: entry) }
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                if let v = stats["Device Utilization %"] as? NSNumber {
                    r.utilization = max(r.utilization ?? 0, v.doubleValue)
                }
                if let m = stats["In use system memory"] as? NSNumber {
                    r.memoryInUse = (r.memoryInUse ?? 0) + m.uint64Value
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(it)
        }
        return r
    }

    /// "gpu-core-count" lives on the GPU device node a few levels above the
    /// accelerator; it is stored as a 4-byte little-endian blob.
    private static func coreCount(above accelerator: io_registry_entry_t) -> Int? {
        var node = accelerator
        IOObjectRetain(node)
        defer { IOObjectRelease(node) }
        for _ in 0..<6 {
            if let raw = IORegistryEntryCreateCFProperty(node, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let n = raw as? NSNumber { return n.intValue }
                if let d = raw as? Data, d.count >= 4 {
                    return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(node)
            node = parent
        }
        return nil
    }

    /// Accumulated GPU time (nanoseconds) per pid, summed over every GPU user
    /// client the process holds. Each `AGXDeviceUserClient` is tagged
    /// "pid N, name" and carries an `AppUsage` array whose entries count
    /// `accumulatedGPUTime` — the accounting Activity Monitor's "% GPU" column
    /// is built on, readable without root. Pids that hold a client but have
    /// never submitted work are present with 0.
    func gpuClientTime() -> [pid_t: UInt64] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(it) }
        var time: [pid_t: UInt64] = [:]
        var accel = IOIteratorNext(it)
        while accel != 0 {
            var kids: io_iterator_t = 0
            if IORegistryEntryCreateIterator(accel, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &kids) == KERN_SUCCESS {
                var child = IOIteratorNext(kids)
                while child != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                       creator.hasPrefix("pid "),
                       let comma = creator.firstIndex(of: ","),
                       let pid = pid_t(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]) {
                        var total: UInt64 = 0
                        if let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                            .takeRetainedValue() as? [[String: Any]] {
                            for entry in usage {
                                if let t = entry["accumulatedGPUTime"] as? NSNumber { total &+= t.uint64Value }
                            }
                        }
                        time[pid, default: 0] &+= total
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(kids)
                }
                IOObjectRelease(kids)
            }
            IOObjectRelease(accel)
            accel = IOIteratorNext(it)
        }
        return time
    }

    // MARK: Memory

    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
            &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)
        return pages * pageSize
    }

    private func memoryFreePercent() -> Int? {
        var level: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &sz, nil, 0) == 0 else { return nil }
        return Int(level)
    }

    // MARK: Temperature

    private func temperatures() -> (max: Double, avg: Double)? {
        if !hidProbed {
            hidProbed = true
            probeHID()
        }
        guard !tempServices.isEmpty else { return nil }
        var values: [Double] = []
        for s in tempServices {
            guard let ev = IOHIDServiceClientCopyEvent(s, kHIDTemperatureType, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(ev, kHIDTemperatureField)
            if v > 0, v < 130 { values.append(v) }   // dead sensors report ~-9200
        }
        guard let mx = values.max() else { return nil }
        return (mx, values.reduce(0, +) / Double(values.count))
    }

    private func probeHID() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary   // AppleSensor / temperature
        _ = IOHIDEventSystemClientSetMatching(client, matching)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return }
        hidClient = client
        let named: [(String, AnyObject)] = services.map {
            ((IOHIDServiceClientCopyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String) ?? "", $0)
        }
        // Apple silicon: "PMU tdie1…N" are the SoC die sensors. Fall back to
        // anything that looks like a CPU/SoC sensor on other machines.
        let die = named.filter { $0.0.hasPrefix("PMU tdie") }
        let chosen = die.isEmpty
            ? named.filter { let n = $0.0.lowercased(); return n.contains("tdie") || n.contains("cpu") || n.contains("soc") }
            : die
        tempServices = chosen.map { $0.1 }
    }
}
