import SwiftUI

/// Inline confirmation card. It lives inside the popover on purpose — an
/// NSAlert would steal key focus and close the transient popover underneath it.
struct KillConfirmView: View {
    let request: KillRequest
    @ObservedObject var model: HeatModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .onTapGesture { model.cancelKill() }

            VStack(spacing: 12) {
                Image(systemName: request.mode == .force ? "bolt.trianglebadge.exclamationmark.fill" : "xmark.octagon.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(request.mode == .force ? .red : .orange)

                Text("\(request.mode.verb) \(request.title)?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if request.memberNames.count > 1 {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(request.memberNames.prefix(6), id: \.self) { name in
                            Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if request.memberNames.count > 6 {
                            Text("… and \(request.memberNames.count - 6) more")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }

                GlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button("Cancel") { model.cancelKill() }
                            .glassButton()
                            .keyboardShortcut(.cancelAction)
                        Button(request.mode.verb, role: .destructive) { model.confirmKill() }
                            .glassButton(prominent: true)
                            .tint(request.mode == .force ? .red : .orange)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(width: 320)
            .glassBox(Metrics.moduleRadius + 2)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        }
    }

    private var detail: String {
        let n = request.pids.count
        let procs = n == 1 ? "1 process" : "\(n) processes"
        let cpu = request.cpu >= 100 ? String(format: "%.0f%%", request.cpu) : String(format: "%.1f%%", request.cpu)
        return "Sends \(request.mode.signalName) to \(procs) using \(cpu) CPU."
            + (request.mode == .terminate ? "" : " Unsaved work in it is lost.")
    }
}
