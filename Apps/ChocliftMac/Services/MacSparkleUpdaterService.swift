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
    @Published public private(set) var checkState: MacUpdateCheckState = .idle

    public var languageProvider: () -> AppLanguage = { .system }

    public var latestCheckResult: MacUpdateCheckResult? {
        checkState.result
    }

    private let updater: SPUUpdater
    private let userDriver: MacSparkleUserDriver
    private let delegateProxy: MacSparkleUpdaterDelegateProxy
    private var stateMachine = MacUpdateCheckStateMachine()
    private var updaterStarted: Bool = false
    private var cancellables = Set<AnyCancellable>()

    public override init() {
        let hostBundle = Bundle.main
        let driver = MacSparkleUserDriver(hostBundle: hostBundle, delegate: nil)
        let proxy = MacSparkleUpdaterDelegateProxy()
        let sparkleUpdater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: driver,
            delegate: proxy
        )

        self.userDriver = driver
        self.delegateProxy = proxy
        self.updater = sparkleUpdater
        super.init()

        driver.owner = self
        proxy.owner = self

        let shouldStartUpdater = hostBundle.bundleURL.pathExtension.lowercased() == "app"
        if shouldStartUpdater {
            do {
                try sparkleUpdater.start()
                self.updaterStarted = true
            } catch {
                self.updaterStarted = false
                let nsError = error as NSError
                transition { machine in
                    _ = machine.recordError(
                        nsError,
                        fallbackHostShortVersion: self.hostShortVersion,
                        fallbackHostBuildVersion: self.hostBuildVersion
                    )
                }
                self.canCheckForUpdates = true
            }
        }

        sparkleUpdater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                guard let self else { return }
                self.canCheckForUpdates = self.updaterStarted ? canCheck : true
            }
            .store(in: &cancellables)

        sparkleUpdater
            .publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.automaticallyChecksForUpdates = enabled
            }
            .store(in: &cancellables)

        sparkleUpdater
            .publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] date in
                self?.lastUpdateCheckDate = date
            }
            .store(in: &cancellables)
    }

    public func checkForUpdates() {
        NSApp?.activate(ignoringOtherApps: true)

        if !updaterStarted {
            do {
                try updater.start()
                updaterStarted = true
            } catch {
                let nsError = error as NSError
                let enriched = prepareUpdaterErrorForPresentation(nsError)
                userDriver.presentImmediateErrorAlert(enriched)
                return
            }
        }

        if !updater.sessionInProgress {
            transition { machine in
                machine.beginCheck()
            }
        }
        updater.checkForUpdates()
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    public func menuStatusSubtitle(in language: AppLanguage) -> String? {
        checkState.menuStatusLine(in: language)
    }

    public var currentVersionBadgeText: String {
        MacUpdateConfiguration.formattedVersionBadge(
            shortVersion: hostShortVersion,
            buildVersion: hostBuildVersion
        )
    }

    // MARK: - Internal Sparkle Lifecycle Hooks

    fileprivate var hostShortVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    fileprivate var hostBuildVersion: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    fileprivate static func makeSnapshot(from item: SUAppcastItem) -> SparkleAppcastItemSnapshot {
        let enclosure = item.propertiesDictionary[MacUpdateConfiguration.enclosureDictionaryKey] as? [AnyHashable: Any]
        let edSig = enclosure?[MacUpdateConfiguration.edSignatureAttributeKey] as? String
        return SparkleAppcastItemSnapshot(
            shortVersion: item.displayVersionString,
            buildVersion: item.versionString,
            hasEnclosureURL: item.fileURL != nil,
            isInformationOnly: item.isInformationOnlyUpdate,
            edSignatureBase64: edSig,
            feedSigningValidationFailed: item.signingValidationStatus == .failed
        )
    }

    fileprivate func handleUserInitiatedCheckStarted() {
        transition { machine in
            machine.beginCheck()
        }
    }

    fileprivate func handleFoundUpdate(_ item: SUAppcastItem) {
        let snapshot = Self.makeSnapshot(from: item)
        transition { machine in
            _ = machine.recordFoundUpdate(snapshot)
        }
    }

    @discardableResult
    fileprivate func handleNoUpdate(error: NSError) -> MacUpdateCheckResult {
        let latestAppcastItem = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let snapshot = latestAppcastItem.map(Self.makeSnapshot(from:))
        var classified: MacUpdateCheckResult = .checkFailed(detail: nil)
        transition { machine in
            classified = machine.recordNoUpdate(
                error: error,
                latestItem: snapshot,
                fallbackHostShortVersion: self.hostShortVersion,
                fallbackHostBuildVersion: self.hostBuildVersion
            )
        }
        return classified
    }

    @discardableResult
    fileprivate func handleUpdaterError(_ error: NSError) -> MacUpdateCheckResult? {
        let latestAppcastItem = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let snapshot = latestAppcastItem.map(Self.makeSnapshot(from:))
        var classified: MacUpdateCheckResult?
        transition { machine in
            classified = machine.recordError(
                error,
                latestItem: snapshot,
                fallbackHostShortVersion: self.hostShortVersion,
                fallbackHostBuildVersion: self.hostBuildVersion
            )
        }
        return classified
    }

    fileprivate func handleFinishUpdateCycle(error: NSError?) {
        let latestAppcastItem = error?.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let snapshot = latestAppcastItem.map(Self.makeSnapshot(from:))
        transition { machine in
            machine.finishCycle(
                error: error,
                latestItem: snapshot,
                fallbackHostShortVersion: self.hostShortVersion,
                fallbackHostBuildVersion: self.hostBuildVersion
            )
        }
    }

    fileprivate func prepareUpdaterErrorForPresentation(_ error: NSError) -> NSError {
        guard let result = handleUpdaterError(error) else {
            return error
        }
        return enrichedAlertError(from: error, for: result)
    }

    fileprivate func enrichedAlertError(from originalError: NSError, for result: MacUpdateCheckResult) -> NSError {
        let lang = languageProvider()
        var userInfo = originalError.userInfo
        userInfo[NSLocalizedDescriptionKey] = result.title(in: lang)
        if let detail = result.detailText(in: lang), !detail.isEmpty {
            userInfo[NSLocalizedRecoverySuggestionErrorKey] = detail
        }
        userInfo[NSUnderlyingErrorKey] = originalError
        return NSError(domain: originalError.domain, code: originalError.code, userInfo: userInfo)
    }

    private func transition(_ mutate: (inout MacUpdateCheckStateMachine) -> Void) {
        mutate(&stateMachine)
        if checkState != stateMachine.state {
            checkState = stateMachine.state
        }
    }
}

// MARK: - Sparkle User Driver Subclass

@MainActor
private final class MacSparkleUserDriver: SPUStandardUserDriver {
    weak var owner: MacSparkleUpdaterService?

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.handleUserInitiatedCheckStarted()
        super.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        owner?.handleFoundUpdate(appcastItem)
        super.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    override func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let nsError = error as NSError
        guard let owner else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        let result = owner.handleNoUpdate(error: nsError)
        switch result {
        case .alreadyCurrent, .updateFound:
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        case .feedUnreachable, .signatureMismatch:
            // Prevent Sparkle from presenting "You're up to date!" when the XML feed had zero valid items
            // or when enclosure signature validation failed.
            let enriched = owner.enrichedAlertError(from: nsError, for: result)
            super.showUpdaterError(enriched, acknowledgement: acknowledgement)
        case .checkFailed:
            let lower = nsError.localizedDescription.lowercased()
            if lower.contains("up to date") || lower.contains("up-to-date") || lower.contains("已是最新") {
                let enriched = owner.enrichedAlertError(from: nsError, for: result)
                super.showUpdaterError(enriched, acknowledgement: acknowledgement)
            } else {
                super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            }
        }
    }

    override func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let nsError = error as NSError
        let enriched = owner?.prepareUpdaterErrorForPresentation(nsError) ?? nsError
        super.showUpdaterError(enriched, acknowledgement: acknowledgement)
    }

    func presentImmediateErrorAlert(_ error: NSError) {
        super.showUpdaterError(error, acknowledgement: {})
    }
}

// MARK: - Sparkle Updater Delegate Proxy

@MainActor
private final class MacSparkleUpdaterDelegateProxy: NSObject, SPUUpdaterDelegate {
    weak var owner: MacSparkleUpdaterService?

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let snapshot = MacSparkleUpdaterService.makeSnapshot(from: updateItem)
        if let issue = MacUpdateConfiguration.validateEnclosureSignature(of: snapshot) {
            let code = (!snapshot.isInformationOnly && !snapshot.hasEnclosureURL)
                ? MacUpdateConfiguration.SparkleErrorCode.appcast
                : MacUpdateConfiguration.SparkleErrorCode.signature
            throw NSError(
                domain: MacUpdateConfiguration.sparkleErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: issue]
            )
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        owner?.handleFoundUpdate(item)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        owner?.handleNoUpdate(error: error as NSError)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        owner?.handleUpdaterError(error as NSError)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        if nsError.domain == MacUpdateConfiguration.sparkleErrorDomain,
           nsError.code == MacUpdateConfiguration.SparkleErrorCode.noUpdate {
            owner?.handleNoUpdate(error: nsError)
        } else {
            owner?.handleUpdaterError(nsError)
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        owner?.handleFinishUpdateCycle(error: error as NSError?)
    }
}

// MARK: - Menu Item View

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

        if let statusLine = updater.menuStatusSubtitle(in: language) {
            Text(statusLine)
        }
    }
}
