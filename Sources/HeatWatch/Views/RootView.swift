import AppKit
import SwiftUI

struct RootView: View {
    static let width: CGFloat = 490
    static let height: CGFloat = 610

    @ObservedObject var model: HeatModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderView(stats: model.snapshot?.system)
                ControlsView(model: model)
                ProcessListView(model: model)
                    .padding(.horizontal, Metrics.margin)
                if model.selectionActive {
                    SelectionBar(model: model)
                        .padding(.horizontal, Metrics.margin)
                        .padding(.top, Metrics.gap)
                }
                IntervalModule(model: model)
                    .padding(.horizontal, Metrics.margin)
                    .padding(.top, Metrics.gap)
                FooterView(model: model)
            }
            if let request = model.pendingKill {
                KillConfirmView(request: request, model: model)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width, height: Self.height)
        // Let the popover's own Liquid Glass show; the list sits on a material box
        // and the modules are regular glass, so text stays legible without a dark fill.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.12))
        .animation(.easeOut(duration: 0.15), value: model.pendingKill?.id)
        .animation(.easeOut(duration: 0.15), value: model.selectionActive)
        // Screenshot mode: render controls as active even if another app is frontmost.
        .transformEnvironment(\.controlActiveState) { state in
            if model.captureScenario != nil { state = .key }
        }
    }
}

struct ControlsView: View {
    @ObservedObject var model: HeatModel

    var body: some View {
        GlassGroup(spacing: 4) {
            HStack(spacing: Metrics.gap) {
                GlassTabs(items: [(true, "Apps"), (false, "Processes")], selection: $model.grouped)
                GlassTabs(items: [(ListMode.cpu, "CPU"), (.memory, "Memory"), (.gpu, "GPU"),
                                  (.issues, model.flaggedCount > 0 ? "Issues · \(model.flaggedCount)" : "Issues")],
                          selection: $model.mode)

                Spacer()

                // No spinner: inserting one changed the row's height every sample
                // and shifted the whole list. The icon just dims while sampling.
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 14, height: 14)
                        .opacity(model.isSampling ? 0.4 : 1)
                }
                .glassButton()
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh now (⌘R)")
            }
        }
        .padding(.horizontal, Metrics.margin)
        .padding(.bottom, Metrics.gap)
    }
}

/// The content layer: a standard-material box, not glass (HIG: keep Liquid
/// Glass for controls; content sits on standard materials).
struct ProcessListView: View {
    @ObservedObject var model: HeatModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.snapshot == nil {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if model.mode == .gpu && model.visibleGroups.isEmpty && model.visibleProcesses.isEmpty {
                    Text("Nothing holds a GPU context right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if model.mode == .issues && model.visibleGroups.isEmpty && model.visibleProcesses.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text("Nothing looks stuck, stale or orphaned.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Scripted browsers left running, hung apps, orphaned leftovers and long burners show up here.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
                } else if model.grouped {
                    if model.mode == .issues { IssuesHeader(model: model, count: model.visibleGroups.count) }
                    ForEach(model.visibleGroups) { group in
                        let expanded = model.expanded.contains(group.id)
                        let m = metric(cpu: group.cpu, memory: group.memory, gpu: group.gpu, age: group.age)
                        ProcessRowView(
                            icon: group.icon,
                            title: group.name,
                            subtitle: subtitle(for: group),
                            badge: model.mode == .issues ? nil : group.issues.first,
                            primary: m.primary,
                            primaryColor: m.color,
                            secondary: m.secondary,
                            chevron: group.count > 1 ? (expanded ? "chevron.down" : "chevron.right") : nil,
                            indent: false,
                            canKill: group.canKill,
                            selectable: group.canKill,
                            selected: model.selected.contains(group.id),
                            selectionActive: model.selectionActive,
                            onTap: group.count > 1 ? { model.toggleExpanded(group.id) } : nil,
                            onSelect: { model.toggleSelected(group.id) },
                            onKill: { model.requestKill(group: group, mode: $0) })
                        if expanded {
                            ForEach(group.members) { proc in
                                let m = metric(cpu: proc.cpu, memory: proc.memory, gpu: proc.gpu, age: proc.age)
                                ProcessRowView(
                                    icon: proc.icon,
                                    title: proc.name,
                                    subtitle: subtitle(for: proc),
                                    badge: proc.issues.first,
                                    primary: m.primary,
                                    primaryColor: m.color,
                                    secondary: m.secondary,
                                    chevron: nil,
                                    indent: true,
                                    canKill: proc.isOwn,
                                    selectable: false,
                                    selected: false,
                                    selectionActive: model.selectionActive,
                                    onTap: nil,
                                    onSelect: nil,
                                    onKill: { model.requestKill(proc: proc, mode: $0) })
                            }
                        }
                    }
                } else {
                    if model.mode == .issues { IssuesHeader(model: model, count: model.visibleProcesses.count) }
                    ForEach(model.visibleProcesses) { proc in
                        let m = metric(cpu: proc.cpu, memory: proc.memory, gpu: proc.gpu, age: proc.age)
                        ProcessRowView(
                            icon: proc.icon,
                            title: proc.name,
                            subtitle: subtitle(for: proc),
                            badge: model.mode == .issues ? nil : proc.issues.first,
                            primary: m.primary,
                            primaryColor: m.color,
                            secondary: m.secondary,
                            chevron: nil,
                            indent: false,
                            canKill: proc.isOwn,
                            selectable: proc.isOwn,
                            selected: model.selected.contains(proc.pid),
                            selectionActive: model.selectionActive,
                            onTap: nil,
                            onSelect: { model.toggleSelected(proc.pid) },
                            onKill: { model.requestKill(proc: proc, mode: $0) })
                    }
                }
            }
            .padding(.vertical, 6)
            // No implicit animation on refresh: animating the whole lazy list
            // every sample makes each text change re-layout and flicker over glass.
            // Order stability comes from smoothing + hysteresis in the model instead.
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.listRadius, style: .continuous))
        .contentBox(Metrics.listRadius)
    }

    /// The bold figure follows the selected tab; the small one is the runner-up.
    /// Issues shows CPU with the age underneath — how long it has been there.
    private func metric(cpu: Double?, memory: UInt64, gpu: Double?, age: TimeInterval?) -> (primary: String, color: Color, secondary: String) {
        let cpuText = ProcessRowView.percentText(cpu)
        let memText = ProcessRowView.memoryText(memory)
        switch model.mode {
        case .cpu:
            return (cpuText, ProcessRowView.cpuColor(cpu), memText)
        case .memory:
            return (memText, .primary, "\(cpuText) CPU")
        case .gpu:
            return (ProcessRowView.percentText(gpu), ProcessRowView.gpuColor(gpu), "\(cpuText) CPU")
        case .issues:
            return (cpuText, ProcessRowView.cpuColor(cpu), age.map { "up \(Age.text($0))" } ?? "")
        }
    }

    private func subtitle(for group: ProcGroup) -> String {
        if model.mode == .issues, !group.issues.isEmpty {
            return group.issues.map(\.detail).joined(separator: " · ")
        }
        var s = "pid \(group.root.pid)"
        if group.count > 1 { s += " · \(group.count) processes" }
        if group.gpuCount > 0 { s += group.count > 1 ? " · \(group.gpuCount) on GPU" : " · GPU" }
        if !group.root.isOwn { s += " · system" }
        return s
    }

    private func subtitle(for proc: ProcSnapshot) -> String {
        if model.mode == .issues, !proc.issues.isEmpty {
            return proc.issues.map(\.detail).joined(separator: " · ")
        }
        var s = "pid \(proc.pid)"
        if proc.usesGPU { s += " · GPU" }
        if !proc.isOwn { s += " · system" }
        if proc.source == .ps, proc.cpu == nil { s += " · cpu unavailable" }
        return s
    }
}

/// First line of the Issues list: how many rows, and one click to tick them all.
struct IssuesHeader: View {
    @ObservedObject var model: HeatModel
    let count: Int

    var body: some View {
        HStack {
            Text("\(count) flagged")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.allVisibleSelected ? "Clear" : "Select all") {
                if model.allVisibleSelected { model.clearSelection() } else { model.selectAllVisible() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .help("Tick every flagged row you are allowed to quit or kill")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }
}

/// Appears once a row is ticked: what is selected and the two ways to end it.
struct SelectionBar: View {
    @ObservedObject var model: HeatModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(model.selected.count) selected")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(ProcessRowView.percentText(model.selectedCPU)) CPU · \(model.selectedProcessCount) process\(model.selectedProcessCount == 1 ? "" : "es")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button("Quit") { model.requestKillSelected(mode: .terminate) }
                        .glassButton()
                        .help("SIGTERM every selected process")
                    Button("Force Kill") { model.requestKillSelected(mode: .force) }
                        .glassButton(prominent: true)
                        .tint(.red)
                        .help("SIGKILL every selected process")
                    Button { model.clearSelection() } label: {
                        Image(systemName: "xmark").frame(width: 12, height: 14)
                    }
                    .glassButton()
                    .help("Clear selection")
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBox(Metrics.moduleRadius)
    }
}

/// Control-Center-style bottom module: a label, the current value and a slider.
struct IntervalModule: View {
    @ObservedObject var model: HeatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Refresh")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("every \(Int(model.interval)) s while open")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Image(systemName: "hare")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $model.interval, in: 1...10, step: 1)
                    .controlSize(.small)
                Image(systemName: "tortoise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBox(Metrics.moduleRadius)
    }
}

struct FooterView: View {
    @ObservedObject var model: HeatModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        HStack {
            Text(loginError ?? model.notice ?? model.statusLine)
                .font(.caption2)
                .foregroundStyle(model.notice == nil && loginError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Divider()
                Button("Quit HeatWatch") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Launch at Login · Quit")
        }
        .padding(.horizontal, Metrics.margin + 2)
        .padding(.vertical, 8)
        .onChange(of: launchAtLogin) { _, on in
            loginError = LoginItem.set(on)
            if loginError != nil { launchAtLogin = LoginItem.isEnabled }
        }
    }
}
