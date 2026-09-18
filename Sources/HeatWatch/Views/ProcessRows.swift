import AppKit
import SwiftUI

/// One row. The bold number on the right is whatever the selected tab is
/// about (CPU %, memory, or GPU %); the small one underneath is the next most
/// useful thing.
struct ProcessRowView: View {
    let icon: NSImage?
    let title: String
    let subtitle: String
    let primary: String
    let primaryColor: Color
    let secondary: String
    let chevron: String?
    let indent: Bool
    let canKill: Bool
    let onTap: (() -> Void)?
    let onKill: (KillMode) -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let chevron {
                    Image(systemName: chevron)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)

            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: indent ? 18 : 22, height: indent ? 18 : 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: indent ? 12 : 12.5, weight: indent ? .regular : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text(primary)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(primaryColor)
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 74, alignment: .trailing)

            Menu {
                Button { onKill(.terminate) } label: {
                    Label("Quit (SIGTERM)", systemImage: "xmark")
                }
                Button(role: .destructive) { onKill(.force) } label: {
                    Label("Force Kill (SIGKILL)", systemImage: "bolt.slash")
                }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(canKill ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!canKill)
            .opacity(hover || !canKill ? 1 : 0.5)
            .help(canKill ? "Quit or force-kill" : "Owned by another user — use Activity Monitor with admin rights")
        }
        .padding(.leading, indent ? 28 : 10)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(hover ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .onHover { hover = $0 }
    }

    // MARK: Formatting shared with the list

    static func percentText(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v >= 100 ? String(format: "%.0f%%", v) : String(format: "%.1f%%", v)
    }

    static func memoryText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// CPU can exceed 100% (many cores); the GPU is one device, so it runs hot earlier.
    static func cpuColor(_ cpu: Double?) -> Color {
        guard let c = cpu else { return .secondary }
        if c >= 100 { return .red }
        if c >= 40 { return .orange }
        return .primary
    }

    static func gpuColor(_ gpu: Double?) -> Color {
        guard let g = gpu else { return .secondary }
        if g >= 60 { return .red }
        if g >= 25 { return .orange }
        return .primary
    }
}
