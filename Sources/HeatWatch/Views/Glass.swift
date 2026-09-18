import SwiftUI

// Liquid Glass on macOS 26, plain material boxes before that. Every surface in
// the panel goes through these so the fallback stays in one place.
//
// Apple's rules we follow (HIG "Materials", "Adopting Liquid Glass"): glass is
// for the control layer and is used sparingly; several glass views sit in one
// GlassEffectContainer because glass cannot sample other glass; the content
// layer (the process list) uses a standard material instead.

extension View {
    /// A rounded glass box (optionally tinted) — control-layer surfaces.
    @ViewBuilder
    func glassBox(_ radius: CGFloat, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.contentBox(radius)
        }
    }

    /// A glass capsule — tab bars and pills.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(Capsule().fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07))))
        }
    }

    /// A rounded standard-material box — content-layer surfaces.
    func contentBox(_ radius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))))
    }

    /// Glass button chrome; bordered before macOS 26.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Groups neighbouring glass views so they blend and morph together.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Glass tab bar: a glass capsule with a tinted selection pill that springs
/// between tabs (critically damped — no overshoot for a tap).
struct GlassTabs<Value: Hashable>: View {
    let items: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Text(item.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.7))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.accentColor)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                            selection = item.value
                        }
                    }
            }
        }
        .padding(3)
        .glassCapsule()
    }
}

/// Layout constants shared by the panel — one place to keep it concentric.
enum Metrics {
    static let margin: CGFloat = 12      // panel edge → modules
    static let gap: CGFloat = 8          // between modules
    static let moduleRadius: CGFloat = 16
    static let listRadius: CGFloat = 16
}
