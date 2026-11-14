import AppKit
import ChocliftCore
import Combine
import Foundation
import Security
import Sparkle
import SwiftUI

@MainActor
public final class MacSparkleUpdaterService: NSObject, ObservableObject {
    public let feedURL: URL = MacUpdateConfiguration.feedURL
    public let hostDescriptor: MacUpdateHostDescriptor

    @Published public private(set) var canCheckForUpdates: Bool
    @Published public private(set) var automaticallyChecksForUpdates: Bool
    @Published public private(set) var lastUpdateCheckDate: Date?
    @Published public private(set) var checkState: MacUpdateCheckState

    public var languageProvider: () -> AppLanguage = { .system }

    public var latestCheckResult: MacUpdateCheckResult? {
        checkState.result
    }

    public var canStartUpdater: Bool {
        hostDescriptor.canStartSparkleUpdater && updaterStarted
    }

    private let hostBundle: Bundle
    private let updater: SPUUpdater
    private let userDriver: MacSparkleUserDriver
    private let delegateProxy: MacSparkleUpdaterDelegateProxy
    private var stateMachine: MacUpdateCheckStateMachine
    private var updaterStarted: Bool = false
    private var pendingUserInitiatedCheck: Bool = false
    private var cancellables = Set<AnyCancellable>()

    public convenience override init() {
        self.init(hostBundle: .main, hostDescriptor: nil)
    }

    public init(hostBundle: Bundle, hostDescriptor: MacUpdateHostDescriptor? = nil) {
        let resolvedDescriptor = hostDescriptor ?? Self.inspectHostBundle(hostBundle)
        let initialMachine = MacUpdateConfiguration.initialStateMachine(for: resolvedDescriptor)
        let driver = MacSparkleUserDriver(hostBundle: hostBundle, delegate: nil)
        let proxy = MacSparkleUpdaterDelegateProxy()
        let sparkleUpdater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: driver,
            delegate: proxy
        )

        self.hostBundle = hostBundle
        self.hostDescriptor = resolvedDescriptor
        self.stateMachine = initialMachine
        self.canCheckForUpdates = resolvedDescriptor.canCheckForUpdates
        self.automaticallyChecksForUpdates = resolvedDescriptor.canStartSparkleUpdater
            ? MacUpdateConfiguration.enableAutomaticChecks
            : false
        self.checkState = initialMachine.state
        self.userDriver = driver
        self.delegateProxy = proxy
        self.updater = sparkleUpdater
        super.init()

        driver.owner = self
        proxy.owner = self

        if resolvedDescriptor.canStartSparkleUpdater {
            do {
                try sparkleUpdater.start()
                self.updaterStarted = true
                self.automaticallyChecksForUpdates = sparkleUpdater.automaticallyChecksForUpdates
                self.lastUpdateCheckDate = sparkleUpdater.lastUpdateCheckDate
            } catch {
                self.updaterStarted = false
                self.automaticallyChecksForUpdates = false
                let nsError = error as NSError
                transition { machine in
                    _ = machine.recordError(
                        nsError,
                        fallbackHostShortVersion: self.hostShortVersion,
                        fallbackHostBuildVersion: self.hostBuildVersion
                    )
                }
            }

            sparkleUpdater
                .publisher(for: \.automaticallyChecksForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] enabled in
                    guard let self, self.updaterStarted else { return }
                    self.automaticallyChecksForUpdates = enabled
                }
                .store(in: &cancellables)

            sparkleUpdater
                .publisher(for: \.lastUpdateCheckDate)
                .receive(on: RunLoop.main)
                .sink { [weak self] date in
                    self?.lastUpdateCheckDate = date
                }
                .store(in: &cancellables)

            sparkleUpdater
                .publisher(for: \.sessionInProgress)
                .receive(on: RunLoop.main)
                .sink { [weak self] inProgress in
                    guard let self, !inProgress, self.pendingUserInitiatedCheck else { return }
                    self.pendingUserInitiatedCheck = false
                    self.checkForUpdates()
                }
                .store(in: &cancellables)
        }
    }

    public static func inspectHostBundle(_ bundle: Bundle) -> MacUpdateHostDescriptor {
        let bundleURL = bundle.bundleURL
        let pathExtension = bundleURL.pathExtension
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildVersion = bundle.infoDictionary?["CFBundleVersion"] as? String

        guard pathExtension.lowercased() == "app" else {
            return MacUpdateHostDescriptor(
                bundlePathExtension: pathExtension,
                isCodeSignatureValid: false,
                isAdhocSigned: false,
                teamIdentifier: nil,
                shortVersion: shortVersion,
                buildVersion: buildVersion
            )
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return MacUpdateHostDescriptor(
                bundlePathExtension: pathExtension,
                isCodeSignatureValid: false,
                isAdhocSigned: false,
                teamIdentifier: nil,
                shortVersion: shortVersion,
                buildVersion: buildVersion
            )
        }

        let isValid = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(), nil, nil) == errSecSuccess

        var cfSigningInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &cfSigningInfo
        )
        let signingInfo = (infoStatus == errSecSuccess) ? (cfSigningInfo as? [String: Any]) : nil
        let rawFlags = (signingInfo?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdhoc = SecCodeSignatureFlags(rawValue: rawFlags).contains(.adhoc)
        let teamIdentifier = signingInfo?[kSecCodeInfoTeamIdentifier as String] as? String

        return MacUpdateHostDescriptor(
            bundlePathExtension: pathExtension,
            isCodeSignatureValid: isValid,
            isAdhocSigned: isAdhoc,
            teamIdentifier: teamIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
    }

    public func checkForUpdates() {
        NSApp?.activate(ignoringOtherApps: true)

        if let unavailableReason = hostDescriptor.unavailableReason {
            var result = MacUpdateCheckResult.hostCannotUpdate(reason: unavailableReason)
            transition { machine in
                result = machine.recordHostUnavailable(unavailableReason)
            }
            let baseError = NSError(
                domain: MacUpdateConfiguration.sparkleErrorDomain,
                code: MacUpdateConfiguration.SparkleErrorCode.insufficientSigning,
                userInfo: nil
            )
            userDriver.presentImmediateErrorAlert(enrichedAlertError(from: baseError, for: result))
            return
        }

        if !updaterStarted {
            do {
                try updater.start()
                updaterStarted = true
                automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
                lastUpdateCheckDate = updater.lastUpdateCheckDate
            } catch {
                let nsError = error as NSError
                let enriched = prepareUpdaterErrorForPresentation(nsError)
                userDriver.presentImmediateErrorAlert(enriched)
                return
            }
        }

        if updater.sessionInProgress && !updater.canCheckForUpdates {
            pendingUserInitiatedCheck = true
            transition { machine in
                machine.beginCheck()
            }
            return
        }

        pendingUserInitiatedCheck = false
        if !updater.sessionInProgress {
            transition { machine in
                machine.beginCheck()
            }
        }
        updater.checkForUpdates()
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard updaterStarted else {
            automaticallyChecksForUpdates = false
            return
        }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    public func menuStatusSubtitle(in language: AppLanguage) -> String? {
        statusPresentation(in: language).menuStatusText
    }

    public func statusPresentation(in language: AppLanguage) -> MacUpdateStatusPresentation {
        MacUpdateConfiguration.statusPresentation(
            host: hostDescriptor,
            state: checkState,
            language: language
        )
    }

    public var currentVersionBadgeText: String {
        MacUpdateConfiguration.formattedVersionBadge(
            shortVersion: hostShortVersion,
            buildVersion: hostBuildVersion
        )
    }

    // MARK: - Internal Sparkle Lifecycle Hooks

    fileprivate var hostShortVersion: String? {
        hostDescriptor.shortVersion ?? (hostBundle.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    fileprivate var hostBuildVersion: String? {
        hostDescriptor.buildVersion ?? (hostBundle.infoDictionary?["CFBundleVersion"] as? String)
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
        case .hostCannotUpdate, .feedUnreachable, .signatureMismatch:
            // Prevent Sparkle from presenting "You're up to date!" when the XML feed had zero valid items
            // or when enclosure signature / host signing validation failed.
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
