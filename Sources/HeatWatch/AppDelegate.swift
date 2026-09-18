import AppKit
import SwiftUI

/// Owns the status item and the popover. Sampling only runs while the popover
/// is on screen: `popoverDidShow` starts it, `popoverDidClose` stops it. The
/// only thing that happens in the background is a push notification from the
/// OS when the thermal state changes, which swaps the menu bar icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = HeatModel()
    private var lastClose = Date.distantPast
    /// Screenshot mode (Tools/capture.sh): the panel opens by itself, stays open
    /// whatever the user clicks, and shows the requested scene.
    private let captureScenario = ProcessInfo.processInfo.environment["HEATWATCH_CAPTURE"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.toolTip = "HeatWatch — what is heating up the Mac"
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = captureScenario == nil ? .transient : .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: RootView.width, height: RootView.height)
        popover.contentViewController = NSHostingController(rootView: RootView(model: model))
        model.captureScenario = captureScenario

        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        thermalStateChanged()

        // Open without a click: screenshot mode, or the HEATWATCH_AUTO_OPEN debug hook.
        if captureScenario != nil || ProcessInfo.processInfo.environment["HEATWATCH_AUTO_OPEN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showPopover() }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A click on the status item first closes the transient popover, then
        // fires this action; without the guard the panel would flicker back open.
        if Date().timeIntervalSince(lastClose) < 0.3 { return }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidShow(_ notification: Notification) {
        model.start()
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
        model.stop()
    }

    // MARK: Menu bar icon

    @objc private func thermalStateChanged() {
        DispatchQueue.main.async {
            self.statusItem.button?.image = Self.icon(for: ProcessInfo.processInfo.thermalState)
        }
    }

    /// Nominal and fair use a template image, so the menu bar draws it in its
    /// own colour for the current appearance. Serious and critical get a
    /// pre-rendered coloured image. `contentTintColor` is deliberately not
    /// used: NSStatusBarButton renders a tinted template symbol as solid black.
    private static func icon(for state: ProcessInfo.ThermalState) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let base = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "HeatWatch")?
            .withSymbolConfiguration(config) else { return nil }

        let colour: NSColor?
        switch state {
        case .serious: colour = .systemOrange
        case .critical: colour = .systemRed
        default: colour = nil
        }
        guard let colour else {
            base.isTemplate = true
            return base
        }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            colour.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "HeatWatch — thermal \(state.label.lowercased())"
        return image
    }
}
