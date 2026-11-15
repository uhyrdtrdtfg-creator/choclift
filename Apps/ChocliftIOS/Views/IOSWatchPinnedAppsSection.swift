import ChocliftCore
import SwiftUI

struct IOSWatchPinnedAppsSection: View {
    @ObservedObject var client: CompanionClientEngine
    let toolsQuery: String

    @State private var showPickerSheet = false

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var pinnedBundleIDs: [String] { WatchPinnedApps.sanitize(client.profile.watchPinnedBundleIDs) }
    private var isAtLimit: Bool { pinnedBundleIDs.count >= WatchPinnedApps.maxCount }

    private var sectionHeaderTitle: String {
        L10n.tr("手表常用应用", "Watch Pinned Apps", language: lang)
    }

    private func appDisplayName(for bundleID: String) -> String {
        client.profile.resolvedAppDisplayName(
            forBundleIdentifier: bundleID,
            recentApps: client.recentApps,
            catalogApps: client.macCatalogApps
        )
    }

    private var filteredBundleIDs: [String] {
        let trimmed = toolsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pinnedBundleIDs }
        if sectionHeaderTitle.localizedCaseInsensitiveContains(trimmed) {
            return pinnedBundleIDs
        }
        return pinnedBundleIDs.filter { bundleID in
            appDisplayName(for: bundleID).localizedCaseInsensitiveContains(trimmed) ||
            bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var shouldShowAddRow: Bool {
        let trimmed = toolsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let addLabel = L10n.tr("添加常用应用", "Add Pinned App", language: lang)
        return addLabel.localizedCaseInsensitiveContains(trimmed) ||
            sectionHeaderTitle.localizedCaseInsensitiveContains(trimmed)
    }

    var body: some View {
        if !filteredBundleIDs.isEmpty || shouldShowAddRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(sectionHeaderTitle)
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                    Text("\(pinnedBundleIDs.count)/\(WatchPinnedApps.maxCount)")
                        .font(ChocType.micro.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    if !pinnedBundleIDs.isEmpty && toolsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            _ = client.setWatchPinnedApps([])
                        } label: {
                            Text(L10n.tr("清空", "Clear", language: lang))
                                .font(ChocType.micro)
                                .foregroundStyle(palette.statusFailure)
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(filteredBundleIDs, id: \.self) { bundleID in
                        pinnedAppRow(bundleID)
                        Divider().overlay(palette.subtleCardStroke)
                    }

                    if shouldShowAddRow {
                        Button {
                            if client.macCatalogApps.isEmpty && client.connectionState.isConnected {
                                client.requestMacCatalog()
                            }
                            showPickerSheet = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "applewatch")
                                    .foregroundStyle(isAtLimit ? palette.secondaryText : palette.accent)
                                    .frame(width: 22)
                                Text(
                                    isAtLimit
                                        ? L10n.tr("已选满 4 个手表常用应用", "4-App Watch Pin Limit Reached", language: lang)
                                        : L10n.tr("添加常用应用", "Add Pinned App", language: lang)
                                )
                                .foregroundStyle(isAtLimit ? palette.secondaryText : palette.primaryText)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .font(ChocType.body)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            }
            .sheet(isPresented: $showPickerSheet) {
                IOSWatchPinnedAppsEditorSheet(client: client)
            }
        }
    }

    private func pinnedAppRow(_ bundleID: String) -> some View {
        let icon = client.cachedAppIconData(forBundleIdentifier: bundleID)
            ?? BundledAppIcons.pngData(for: bundleID)
        let fullIndex = pinnedBundleIDs.firstIndex { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
        let canMoveUp = (fullIndex ?? 0) > 0
        let canMoveDown: Bool = {
            guard let fullIndex else { return false }
            return fullIndex < pinnedBundleIDs.count - 1
        }()

        return HStack(spacing: 12) {
            DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                .frame(width: 24, height: 24)

            Text(appDisplayName(for: bundleID))
                .font(ChocType.body)
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            if toolsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let fullIndex {
                Button {
                    moveApp(at: fullIndex, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(ChocType.caption)
                        .foregroundStyle(canMoveUp ? palette.secondaryText : palette.secondaryText.opacity(0.35))
                        .frame(width: 30, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canMoveUp)
                .accessibilityLabel(L10n.tr("上移", "Move Up", language: lang))

                Button {
                    moveApp(at: fullIndex, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(ChocType.caption)
                        .foregroundStyle(canMoveDown ? palette.secondaryText : palette.secondaryText.opacity(0.35))
                        .frame(width: 30, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canMoveDown)
                .accessibilityLabel(L10n.tr("下移", "Move Down", language: lang))
            }

            Button {
                var next = pinnedBundleIDs
                next.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
                _ = client.setWatchPinnedApps(next)
            } label: {
                Image(systemName: "trash")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.statusFailure)
                    .frame(width: 34, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("移除", "Remove", language: lang))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
    }

    private func moveApp(at index: Int, offset: Int) {
        let targetIndex = index + offset
        guard pinnedBundleIDs.indices.contains(index),
              pinnedBundleIDs.indices.contains(targetIndex) else {
            return
        }
        var next = pinnedBundleIDs
        next.swapAt(index, targetIndex)
        _ = client.setWatchPinnedApps(next)
    }
}

private struct IOSWatchPinnedAppsEditorSheet: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var pinnedBundleIDs: [String] { WatchPinnedApps.sanitize(client.profile.watchPinnedBundleIDs) }
    private var isAtLimit: Bool { pinnedBundleIDs.count >= WatchPinnedApps.maxCount }

    private var availableCandidates: [WatchPinnedAppCandidate] {
        let all = WatchPinnedApps.candidateApps(
            catalogApps: client.macCatalogApps,
            recentApps: client.recentApps,
            profile: client.profile,
            excludingBundleIDs: pinnedBundleIDs
        )
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.appName.localizedCaseInsensitiveContains(trimmed) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    currentSelectionCard

                    availableAppsCard
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(L10n.tr("手表常用应用", "Watch Pinned Apps", language: lang))
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if client.macCatalogApps.isEmpty && client.connectionState.isConnected {
                    client.requestMacCatalog()
                }
            }
        }
        .tint(palette.accent)
    }

    private var currentSelectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.tr("已固定到手表的常用应用", "Pinned on Apple Watch", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text("\(pinnedBundleIDs.count)/\(WatchPinnedApps.maxCount)")
                    .font(ChocType.micro.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }

            if pinnedBundleIDs.isEmpty {
                Text(
                    L10n.tr(
                        "从下方最近或已安装应用中点选最多 4 个应用。",
                        "Tap up to 4 recent or installed Mac apps below to pin them.",
                        language: lang
                    )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(pinnedBundleIDs.enumerated()), id: \.element) { idx, bundleID in
                        let name = client.profile.resolvedAppDisplayName(
                            forBundleIdentifier: bundleID,
                            recentApps: client.recentApps,
                            catalogApps: client.macCatalogApps
                        )
                        let icon = client.cachedAppIconData(forBundleIdentifier: bundleID)
                            ?? BundledAppIcons.pngData(for: bundleID)
                        HStack(spacing: 12) {
                            Text("\(idx + 1)")
                                .font(ChocType.micro.monospacedDigit())
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 18)

                            DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                                .frame(width: 24, height: 24)

                            Text(name)
                                .font(ChocType.body)
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)

                            Spacer(minLength: 6)

                            Button {
                                var next = pinnedBundleIDs
                                next.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
                                _ = client.setWatchPinnedApps(next)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(palette.statusFailure)
                                    .frame(width: 32, height: 36)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)

                        if idx < pinnedBundleIDs.count - 1 {
                            Divider().overlay(palette.subtleCardStroke)
                        }
                    }
                }
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            }
        }
    }

    private var availableAppsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.tr("可选 Mac 应用", "Available Mac Apps", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                if client.connectionState.isConnected {
                    Button {
                        client.requestMacCatalog()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(ChocType.caption)
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.secondaryText)
                TextField(
                    L10n.tr("搜索最近或已安装应用", "Search recent or installed apps", language: lang),
                    text: $searchText
                )
                .font(ChocType.body)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))

            if availableCandidates.isEmpty {
                Text(
                    client.connectionState.isConnected
                        ? L10n.tr("暂无更多可选应用。", "No additional Mac apps found.", language: lang)
                        : L10n.tr("连接 Mac 后可获取完整已安装应用列表。", "Connect to your Mac to browse installed apps.", language: lang)
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(availableCandidates.enumerated()), id: \.element.id) { idx, candidate in
                        let icon = client.cachedAppIconData(forBundleIdentifier: candidate.bundleIdentifier)
                            ?? BundledAppIcons.pngData(for: candidate.bundleIdentifier)
                        Button {
                            var next = pinnedBundleIDs
                            next.append(candidate.bundleIdentifier)
                            _ = client.setWatchPinnedApps(next)
                        } label: {
                            HStack(spacing: 12) {
                                DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                                    .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.appName)
                                        .font(ChocType.body)
                                        .foregroundStyle(isAtLimit ? palette.secondaryText : palette.primaryText)
                                        .lineLimit(1)
                                    Text(candidate.bundleIdentifier)
                                        .font(ChocType.micro)
                                        .foregroundStyle(palette.secondaryText)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 6)

                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(isAtLimit ? palette.secondaryText.opacity(0.4) : palette.accent)
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isAtLimit)

                        if idx < availableCandidates.count - 1 {
                            Divider().overlay(palette.subtleCardStroke)
                        }
                    }
                }
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            }
        }
    }
}
