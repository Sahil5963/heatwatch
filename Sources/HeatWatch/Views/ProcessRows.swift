import AppKit
import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .hot: return .red
        case .warn: return .orange
        case .info: return .secondary
        }
    }
}

/// One row. The bold number on the right is whatever the selected tab is
/// about (CPU %, memory, or GPU %); the small one underneath is the next most
/// useful thing. A flagged row carries a small pill after its name. The left
/// column is the expand chevron, or a tick box once a selection is under way
/// (or the pointer is over the row).
struct ProcessRowView: View {
    let icon: NSImage?
    let title: String
    let subtitle: String
    let badge: Issue?
    let primary: String
    let primaryColor: Color
    let secondary: String
    let chevron: String?
    let indent: Bool
    let canKill: Bool
    let selectable: Bool
    let selected: Bool
    let selectionActive: Bool
    let onTap: (() -> Void)?
    let onSelect: (() -> Void)?
    let onKill: (KillMode) -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if selectable, selectionActive || hover || selected {
                    Button { onSelect?() } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help(selected ? "Remove from selection" : "Add to selection")
                } else if let chevron {
                    Image(systemName: chevron)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)

            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    ZStack {
                        Circle().fill(Color.primary.opacity(0.08))
                        Image(systemName: "gearshape")
                            .font(.system(size: indent ? 10 : 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: indent ? 18 : 22, height: indent ? 18 : 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: indent ? 12 : 12.5, weight: indent ? .regular : .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge {
                        Text(badge.short)
                            .font(.system(size: 9.5, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(badge.severity.color.opacity(badge.severity == .info ? 0.10 : 0.16)))
                            .foregroundStyle(badge.severity.color)
                            .layoutPriority(1)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        .padding(.leading, indent ? 30 : 10)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.10) : hover ? Color.primary.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35).padding(.leading, indent ? 60 : 50)
        }
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
