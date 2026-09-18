import SwiftUI

/// Four compact glass modules: title and big value on the left, the details
/// right-aligned beside it. The value is coloured only when something is
/// warm or hot, so a calm machine reads as plain text.
struct HeaderView: View {
    let stats: SystemStats?

    var body: some View {
        GlassGroup(spacing: 4) {
            VStack(spacing: Metrics.gap) {
                HStack(spacing: Metrics.gap) {
                    StatModule(
                        title: "CPU",
                        value: stats?.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—",
                        details: cpuDetails,
                        tint: Self.loadTint(stats?.cpuPercent, warn: 50, hot: 80))
                    StatModule(
                        title: "GPU",
                        value: stats?.gpuPercent.map { "\(Int($0.rounded()))%" } ?? "—",
                        details: gpuDetails,
                        tint: Self.loadTint(stats?.gpuPercent, warn: 50, hot: 80))
                }
                HStack(spacing: Metrics.gap) {
                    StatModule(
                        title: "Memory",
                        value: stats.map { Self.gb($0.memoryUsed) } ?? "—",
                        details: memoryDetails,
                        tint: Self.memoryTint(stats?.memoryFreePercent))
                    StatModule(
                        title: "Heat",
                        value: stats?.dieTempMax.map { String(format: "%.0f°", $0) } ?? (stats?.thermalState.label ?? "—"),
                        details: heatDetails,
                        tint: Self.thermalTint(stats?.thermalState))
                }
            }
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.top, Metrics.margin)
        .padding(.bottom, Metrics.gap)
    }

    private var cpuDetails: [String] {
        guard let s = stats else { return [] }
        var d: [String] = []
        if let p = s.cpuPercent {
            d.append(String(format: "%.1f of %d cores", p / 100 * Double(s.coreCount), s.coreCount))
        }
        d.append(String(format: "load %.1f", s.loadAverage.first ?? 0))
        return d
    }

    private var gpuDetails: [String] {
        guard let s = stats, s.gpuPercent != nil else { return [] }
        var d: [String] = []
        if let m = s.gpuMemoryInUse { d.append("\(Self.gb(m)) in use") }
        var size: [String] = []
        if let c = s.gpuCoreCount { size.append("\(c) cores") }
        if let n = s.gpuProcessCount { size.append("\(n) procs") }
        if !size.isEmpty { d.append(size.joined(separator: " · ")) }
        return d.isEmpty ? ["device busy"] : d
    }

    /// Used is Activity Monitor's "Memory Used"; left is plain total − used.
    private var memoryDetails: [String] {
        guard let s = stats, s.memoryTotal > 0 else { return [] }
        let left = s.memoryTotal > s.memoryUsed ? s.memoryTotal - s.memoryUsed : 0
        let pct = Int((Double(left) / Double(s.memoryTotal) * 100).rounded())
        return ["of \(Self.gb(s.memoryTotal))", "\(Self.gb(left)) left · \(pct)%"]
    }

    private var heatDetails: [String] {
        guard let s = stats else { return [] }
        var d = [s.thermalState.label]
        if let avg = s.dieTempAvg { d.append(String(format: "average %.0f°", avg)) }
        return d
    }

    static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        let rounded = (g * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(format: "%.0f GB", rounded) : String(format: "%.1f GB", rounded)
    }

    static func loadTint(_ v: Double?, warn: Double, hot: Double) -> Color {
        guard let v else { return .secondary }
        if v >= hot { return .red }
        if v >= warn { return .orange }
        return .primary
    }

    /// Follows the kernel's memory-pressure level, not the arithmetic "left":
    /// cached files count as reclaimable, so pressure can be fine while the
    /// arithmetic looks tight. That matches Activity Monitor.
    static func memoryTint(_ freePercent: Int?) -> Color {
        guard let f = freePercent else { return .primary }
        if f < 20 { return .red }
        if f < 40 { return .orange }
        return .primary
    }

    static func thermalTint(_ state: ProcessInfo.ThermalState?) -> Color {
        switch state {
        case .nominal: return .primary
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        default: return .secondary
        }
    }
}

struct StatModule: View {
    let title: String
    let value: String
    let details: [String]   // up to two lines, right-aligned beside the value
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(0..<2, id: \.self) { i in
                    Text(i < details.count ? details[i] : " ")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBox(Metrics.moduleRadius)
    }
}
