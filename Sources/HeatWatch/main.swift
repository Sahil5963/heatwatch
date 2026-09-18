import AppKit

// Top-level code is nonisolated in language mode 5; the entry point is the
// main thread, so it is safe to assume the main actor here.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
