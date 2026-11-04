import Foundation
import ServiceManagement

/// The app's own "Open at login", through macOS's login-item service.
///
/// The old login item was a LaunchAgent whose program was /bin/bash (a
/// wrapper that retired itself when the app was deleted). macOS showed it
/// as "bash" from an "Unknown Developer", in Login Items and in the
/// "can run in the background" notice Set up triggers. `SMAppService.mainApp`
/// shows as Usage HUD with its icon and goes away when the app is deleted.
///
/// Tests (and override dirs) leave `Paths.systemLoginItem` nil and keep the
/// plist path, so no test touches the real login items.
struct SystemLoginItem {
    var isEnabled: () -> Bool
    var register: () throws -> Void
    var unregister: () throws -> Void

    static let mainApp = SystemLoginItem(
        isEnabled: { SMAppService.mainApp.status == .enabled },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() }
    )
}
