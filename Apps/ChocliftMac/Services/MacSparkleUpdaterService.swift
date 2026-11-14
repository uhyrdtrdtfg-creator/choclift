import AppKit
import ChocliftCore
import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
public final class MacSparkleUpdaterService: NSObject, ObservableObject {
    public let feedURL: URL = MacUpdateConfiguration.feedURL

    @Published public private(set) var canCheckForUpdates: Bool = false
    @Published public private(set) var automaticallyChecksForUpdates: Bool = MacUpdateConfiguration.enableAutomaticChecks
    @Published public private(set) var lastUpdateCheckDate: Date?

    private let updaterController: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    public override init() {
        let shouldStartUpdater = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        let controller = SPUStandardUpdaterController(
            startingUpdater: shouldStartUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller
        super.init()

        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &cancellables)

        controller.updater
            .publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.automaticallyChecksForUpdates = enabled
            }
            .store(in: &cancellables)

        controller.updater
            .publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] date in
                self?.lastUpdateCheckDate = date
            }
            .store(in: &cancellables)
    }

    public func checkForUpdates() {
        NSApp?.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
    }

    public var currentVersionBadgeText: String {
        let info = Bundle.main.infoDictionary
        return MacUpdateConfiguration.formattedVersionBadge(
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            buildVersion: info?["CFBundleVersion"] as? String
        )
    }
}

public struct CheckForUpdatesMenuItemView: View {
    @ObservedObject var updater: MacSparkleUpdaterService
    let language: AppLanguage

    public init(updater: MacSparkleUpdaterService, language: AppLanguage) {
        self.updater = updater
        self.language = language
    }

    public var body: some View {
        Button(MacUpdateConfiguration.checkForUpdatesMenuTitle(in: language)) {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
