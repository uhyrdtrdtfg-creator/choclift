import AppKit
import ChocliftCore
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - 1. macOS 13 Public ServiceManagement Login Item Adapter

public struct MacLaunchAtLoginService: LaunchAtLoginServing {
    public init() {}

    public func currentStatus() -> LaunchAtLoginRegistrationStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notRegistered
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openLoginItemsSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - 2. Single Menu-Bar Status Item Controller

@MainActor
public final class MacMenuBarStatusController: NSObject {
    private weak var coordinator: MacAppCoordinator?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    public private(set) var currentSummary = MacMenuBarStatusSummary(
        connectedCompanionCount: 0,
        isKeepAwakeOn: false
    )

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    public func start() {
        guard statusItem == nil else {
            refresh()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "com.choclift.mac.statusitem"
        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        self.statusItem = item
        refresh()
    }

    public func stop() {
        popover?.performClose(nil)
        popover = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    public func refresh() {
        guard let coordinator else { return }
        let summary = MacMenuBarStatusSummary(
            connectedCompanionCount: coordinator.connectedCompanionCount,
            isKeepAwakeOn: coordinator.isKeepMacAwakeEnabled
        )
        currentSummary = summary

        guard let button = statusItem?.button else { return }
        let lang = coordinator.lang

        if let image = NSImage(
            systemSymbolName: summary.symbolName,
            accessibilityDescription: "Choclift"
        ) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = true
            button.image = configured
        }
        button.title = " \(summary.menuBarTitle(in: lang))"
        let tooltip = summary.tooltipText(in: lang)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.setAccessibilityIdentifier("mac-menubar-status-button")
    }

    @objc
    private func handleStatusBarButtonClicked(_ sender: NSStatusBarButton?) {
        guard let coordinator else { return }
        let event = NSApp.currentEvent
        let isSecondaryClick = (event?.type == .rightMouseUp) || (event?.modifierFlags.contains(.control) == true)

        if isSecondaryClick {
            presentSecondaryContextMenu()
            return
        }

        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentViewController = NSHostingController(rootView: MacMenuBarPopoverView(coordinator: coordinator))
        popover = panel
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func presentSecondaryContextMenu() {
        guard let coordinator, let statusItem, let button = statusItem.button else { return }
        let lang = coordinator.lang
        let summary = currentSummary
        popover?.performClose(nil)

        let menu = NSMenu()
        for line in summary.menuStatusLines(in: lang) {
            let statusLineItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            statusLineItem.isEnabled = false
            menu.addItem(statusLineItem)
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: L10n.tr("打开 Choclift 窗口", "Open Choclift Window", language: lang),
            action: #selector(handleOpenMainWindowFromMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let updateItem = NSMenuItem(
            title: MacUpdateConfiguration.checkForUpdatesMenuTitle(in: lang),
            action: coordinator.updaterService.canCheckForUpdates ? #selector(handleCheckForUpdatesFromMenu) : nil,
            keyEquivalent: ""
        )
        updateItem.target = coordinator.updaterService.canCheckForUpdates ? self : nil
        updateItem.isEnabled = coordinator.updaterService.canCheckForUpdates
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.tr("退出 Choclift", "Quit Choclift", language: lang),
            action: #selector(handleQuitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc
    private func handleOpenMainWindowFromMenu() {
        coordinator?.openMainStudioWindow()
    }

    @objc
    private func handleCheckForUpdatesFromMenu() {
        coordinator?.updaterService.checkForUpdates()
    }

    @objc
    private func handleQuitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}
