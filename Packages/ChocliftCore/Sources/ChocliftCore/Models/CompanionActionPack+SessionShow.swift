import Foundation

public struct SessionShowAppCandidate: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var localizedName: String?
    public var isRegularActivationPolicy: Bool
    public var isTerminated: Bool
    public var isHidden: Bool

    public init(
        pid: Int32,
        bundleIdentifier: String? = nil,
        localizedName: String? = nil,
        isRegularActivationPolicy: Bool = true,
        isTerminated: Bool = false,
        isHidden: Bool = false
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isRegularActivationPolicy = isRegularActivationPolicy
        self.isTerminated = isTerminated
        self.isHidden = isHidden
    }
}

public struct SessionShowOutcome: Equatable, Sendable {
    public let success: Bool
    public let unhiddenCount: Int
    public let message: String

    public init(success: Bool, unhiddenCount: Int, message: String) {
        self.success = success
        self.unhiddenCount = unhiddenCount
        self.message = message
    }
}

public enum SessionShowCompanionAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case showAllApps = "session.show_all_apps"

    public static let chocliftBundleIdentifier = "com.choclift.mac"
    public static let chocliftBundlePrefix = "com.choclift."

    public var companionAction: CompanionAction {
        switch self {
        case .showAllApps:
            return CompanionAction(
                id: rawValue,
                titleZh: "显示全部应用",
                titleEn: "Show All Apps",
                sfSymbol: "eye"
            )
        }
    }

    public static func isChocliftBundle(
        _ bundleIdentifier: String?,
        selfBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> Bool {
        guard let raw = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        let lower = raw.lowercased()
        if lower == "com.choclift"
            || lower == chocliftBundleIdentifier
            || lower.hasPrefix(chocliftBundlePrefix) {
            return true
        }
        if let selfRaw = selfBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selfRaw.isEmpty,
           lower == selfRaw.lowercased() {
            return true
        }
        return false
    }

    public static func shouldUnhide(
        _ candidate: SessionShowAppCandidate,
        selfPID: Int32,
        selfBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> Bool {
        guard candidate.pid > 0,
              candidate.isRegularActivationPolicy,
              !candidate.isTerminated,
              candidate.isHidden,
              candidate.pid != selfPID else {
            return false
        }
        if isChocliftBundle(candidate.bundleIdentifier, selfBundleIdentifier: selfBundleIdentifier) {
            return false
        }
        if let lowerBundle = candidate.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           lowerBundle == "com.apple.loginwindow" {
            return false
        }
        return true
    }

    public static func execute(
        id: String,
        candidates: [SessionShowAppCandidate],
        selfPID: Int32,
        selfBundleIdentifier: String? = chocliftBundleIdentifier,
        language: AppLanguage = .system,
        unhide: (SessionShowAppCandidate) -> Bool
    ) -> SessionShowOutcome {
        guard SessionShowCompanionAction(rawValue: id) == .showAllApps else {
            return SessionShowOutcome(
                success: false,
                unhiddenCount: 0,
                message: L10n.tr("不支持此操作", "Unsupported action", language: language)
            )
        }

        let eligibleHidden = candidates.filter {
            shouldUnhide($0, selfPID: selfPID, selfBundleIdentifier: selfBundleIdentifier)
        }

        guard !eligibleHidden.isEmpty else {
            return SessionShowOutcome(
                success: true,
                unhiddenCount: 0,
                message: L10n.tr("当前没有已隐藏的应用", "No apps were hidden", language: language)
            )
        }

        var unhiddenCount = 0
        for app in eligibleHidden where unhide(app) {
            unhiddenCount += 1
        }

        guard unhiddenCount > 0 else {
            return SessionShowOutcome(
                success: false,
                unhiddenCount: 0,
                message: L10n.tr("无法显示已隐藏的应用", "Could not unhide hidden apps", language: language)
            )
        }

        return SessionShowOutcome(
            success: true,
            unhiddenCount: unhiddenCount,
            message: L10n.tr(
                "已显示 \(unhiddenCount) 个隐藏应用",
                "Unhid \(unhiddenCount) hidden app\(unhiddenCount == 1 ? "" : "s")",
                language: language
            )
        )
    }
}

extension CompanionActionCatalog {
    public static let sessionShowPack: [CompanionAction] = SessionShowCompanionAction.allCases.map(\.companionAction)
}
