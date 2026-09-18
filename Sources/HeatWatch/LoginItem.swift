import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Registering shows the
/// system's "Background Items Added" notice once; the entry then lives in
/// System Settings → General → Login Items.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
