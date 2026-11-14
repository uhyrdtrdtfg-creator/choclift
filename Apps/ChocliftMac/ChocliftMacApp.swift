import AppKit
import ChocliftCore
import SwiftUI

@main
struct ChocliftMacApp: App {
    @StateObject private var coordinator = MacAppCoordinator()

    var body: some Scene {
        Window("choclift", id: "studio-main") {
            MacMainWindowView(coordinator: coordinator)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1120, height: 700)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle(
                    L10n.tr("顶部刘海悬浮巧克力栏", "Notch Chocolate Bar Panel", language: coordinator.lang),
                    isOn: Binding(
                        get: { coordinator.notchPanelEnabled },
                        set: { coordinator.setNotchPanelEnabled($0) }
                    )
                )
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Toggle(
                    L10n.tr("屏幕左边缘悬停呼出面板", "Left Screen Edge Hover", language: coordinator.lang),
                    isOn: Binding(
                        get: { coordinator.leftEdgePanelEnabled },
                        set: { coordinator.setLeftEdgePanelEnabled($0) }
                    )
                )
                .disabled(!coordinator.notchPanelEnabled)

                Divider()
            }
        }
    }
}
