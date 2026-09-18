import SwiftUI

struct HeaderView: View {
    let stats: SystemStats?

    var body: some View {
        HStack(spacing: 8) {
            StatTile(
                title: "CPU",
                value: stats?.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—",
                details: cpuDetails,
                fraction: (stats?.cpuPercent ?? 0) / 100,
                tint: Self.loadTint(stats?.cpuPercent, warn: 50, hot: 80))
            StatTile(
                title: "GPU",
                value: stats?.gpuPercent.map { "\(Int($0.rounded()))%" } ?? "—",
                details: gpuDetails,
                fraction: (stats?.gpuPercent ?? 0) / 100,
                tint: Self.loadTint(stats?.gpuPercent, warn: 50, hot: 80))
            StatTile(
                title: "Memory",
                value: stats.map { Self.gb($0.memoryUsed) } ?? "—",
                details: memoryDetails,
                fraction: stats.map { Double($0.memoryUsed) / Double(max($0.memoryTotal, 1)) } ?? 0,
                tint: Self.memoryTint(stats?.memoryFreePercent))
            StatTile(
                title: "Heat",
                value: stats?.dieTempMax.map { String(format: "%.0f°", $0) } ?? (stats?.thermalState.label ?? "—"),
                details: heatDetails,
                fraction: stats?.dieTempMax.map { min(1, max(0, ($0 - 40) / 60)) } ?? 0,
                tint: Self.thermalTint(stats?.thermalState))
        }
        .padding(10)
    }

    /// "3.3 / 15 cores" — how much of the machine the percentage actually is.
    private var cpuDetails: [String] {
        guard let s = stats else { return [] }
        var d: [String] = []
        if let p = s.cpuPercent {
            d.append(String(format: "%.1f / %d cores", p / 100 * Double(s.coreCount), s.coreCount))
        }
        d.append(String(format: "load %.1f", s.loadAverage.first ?? 0))
        return d
    }

    /// "2.4 GB in use" / "16 cores · 98 procs" — what is on the GPU and how big it is.
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
        if let avg = s.dieTempAvg { d.append(String(format: "avg %.0f°", avg)) }
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
        return .accentColor
    }

    /// Tint follows the kernel's memory-pressure level, not the arithmetic
    /// "left" figure — cached files count as reclaimable, so pressure can be
    /// fine while the arithmetic looks tight. That matches Activity Monitor.
    static func memoryTint(_ freePercent: Int?) -> Color {
        guard let f = freePercent else { return .accentColor }
        if f < 20 { return .red }
        if f < 40 { return .orange }
        return .accentColor
    }

    static func thermalTint(_ state: ProcessInfo.ThermalState?) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        default: return .secondary
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let details: [String]   // up to two lines; always laid out as two so tiles match
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.bottom, 1)
            ForEach(0..<2, id: \.self) { i in
                Text(i < details.count ? details[i] : " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: max(0, min(1, fraction)) * g.size.width)
                }
            }
            .frame(height: 3)
            .padding(.top, 3)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
