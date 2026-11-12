import AppKit
import ChocliftCore
import SwiftUI

@main
struct ChocliftMacApp: App {
    @StateObject private var coordinator = MacAppCoordinator()

    var body: some Scene {
        Window("choclift", id: "studio-main") {
            MacMainWindowView(coordinator: coordinator)
        }
        .defaultSize(width: 960, height: 640)

        MenuBarExtra {
            MacMenuBarPopoverView(coordinator: coordinator)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: coordinator.server.connectedDeviceCount > 0 ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
