import AppKit
import ChocliftCore
import SwiftUI

public struct MacWatchPinnedAppsCard: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @State private var showAppPickerSheet = false

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }
    private var pinnedBundleIDs: [String] { coordinator.profile.watchPinnedBundleIDs }
    private var canAddMore: Bool { pinnedBundleIDs.count < WatchPinnedApps.maxCount }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(
                    L10n.tr("手表常用应用", "Watch Pinned Apps", language: lang),
                    systemImage: "applewatch"
                )
                .font(ChocType.title)
                .foregroundStyle(palette.primaryText)

                Text("\(pinnedBundleIDs.count)/\(WatchPinnedApps.maxCount)")
                    .font(ChocType.micro.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.tileFillBottom, in: Capsule())

                Spacer()

                if !pinnedBundleIDs.isEmpty {
                    Button(role: .destructive) {
                        let res = coordinator.setWatchPinnedApps([])
                        coordinator.flashBanner(res.detail)
                    } label: {
                        Text(L10n.tr("清空", "Clear", language: lang))
                            .font(ChocType.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    if coordinator.installedApps.isEmpty {
                        coordinator.refreshCatalog()
                    }
                    showAppPickerSheet = true
                } label: {
                    Label(L10n.tr("添加应用", "Add App", language: lang), systemImage: "plus")
                        .font(ChocType.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)
                .controlSize(.small)
                .disabled(!canAddMore)
            }

            Text(
                L10n.tr(
                    "选择最多 4 个已安装应用，在 Apple Watch 快捷操作顶部显示大按钮，轻点即可在 Mac 上打开或切至前台。",
                    "Pick up to 4 installed apps to show as large buttons at the top of Apple Watch Quick Actions.",
                    language: lang
                )
            )
            .font(ChocType.caption)
            .foregroundStyle(palette.secondaryText)

            if pinnedBundleIDs.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "applewatch.watchface")
                        .font(ChocType.body)
                        .foregroundStyle(palette.secondaryText)
                    Text(
                        L10n.tr(
                            "尚未固定常用应用。未固定时手表快捷操作不会显示此区域。",
                            "No Watch pinned apps selected yet. When empty, this section is hidden on Apple Watch.",
                            language: lang
                        )
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(pinnedBundleIDs.enumerated()), id: \.element) { index, bundleID in
                        pinnedAppRow(bundleID: bundleID, index: index)
                    }
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .sheet(isPresented: $showAppPickerSheet) {
            MacWatchPinnedAppPickerSheet(coordinator: coordinator)
        }
    }

    private func pinnedAppRow(bundleID: String, index: Int) -> some View {
        let appName = coordinator.profile.resolvedAppDisplayName(
            forBundleIdentifier: bundleID,
            recentApps: coordinator.timeTravel.timeline,
            catalogApps: coordinator.installedApps
        )
        let iconData = resolveIconData(for: bundleID)

        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(ChocType.micro.monospacedDigit())
                .foregroundStyle(palette.secondaryText)
                .frame(width: 20, height: 20)
                .background(palette.barSurface, in: Circle())

            DataImageView(pngData: iconData, fallbackSymbol: "app.fill", tint: palette.secondaryText)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(appName)
                    .font(ChocType.body.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(bundleID)
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                moveApp(at: index, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(index == 0)
            .accessibilityLabel(L10n.tr("上移", "Move Up", language: lang))

            Button {
                moveApp(at: index, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(index >= pinnedBundleIDs.count - 1)
            .accessibilityLabel(L10n.tr("下移", "Move Down", language: lang))

            Button(role: .destructive) {
                var next = pinnedBundleIDs
                next.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
                let res = coordinator.setWatchPinnedApps(next)
                coordinator.flashBanner(res.detail)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(palette.statusFailure)
            .accessibilityLabel(L10n.tr("移除", "Remove", language: lang))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private func moveApp(at index: Int, offset: Int) {
        let targetIndex = index + offset
        guard pinnedBundleIDs.indices.contains(index),
              pinnedBundleIDs.indices.contains(targetIndex) else {
            return
        }
        var next = pinnedBundleIDs
        next.swapAt(index, targetIndex)
        _ = coordinator.setWatchPinnedApps(next)
    }

    private func resolveIconData(for bundleID: String) -> Data? {
        if let installed = coordinator.installedApps.first(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
        }), let png = installed.iconPNGData {
            return png
        }
        if let cached = coordinator.serverIcons(for: [bundleID])[bundleID] {
            return cached
        }
        return BundledAppIcons.pngData(for: bundleID)
    }
}

private struct MacWatchPinnedAppPickerSheet: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }
    private var pinnedBundleIDs: [String] { coordinator.profile.watchPinnedBundleIDs }

    private var candidates: [WatchPinnedAppCandidate] {
        let all = WatchPinnedApps.candidateApps(
            catalogApps: coordinator.installedApps,
            recentApps: coordinator.timeTravel.timeline,
            profile: coordinator.profile,
            excludingBundleIDs: pinnedBundleIDs
        )
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.appName.localizedCaseInsensitiveContains(trimmed) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("选择手表常用应用", "Choose Watch Pinned App", language: lang))
                    .font(ChocType.title)
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Text("\(pinnedBundleIDs.count)/\(WatchPinnedApps.maxCount)")
                    .font(ChocType.caption.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }

            HStack(spacing: 8) {
                TextField(
                    L10n.tr("搜索已安装应用", "Search installed apps", language: lang),
                    text: $query
                )
                .textFieldStyle(.roundedBorder)

                Button {
                    coordinator.refreshCatalog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.isScanningCatalog)
                .help(L10n.tr("重新扫描应用列表", "Rescan installed apps", language: lang))
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if candidates.isEmpty {
                        Text(
                            coordinator.isScanningCatalog
                                ? L10n.tr("正在扫描已安装应用…", "Scanning installed apps…", language: lang)
                                : L10n.tr("未找到匹配的可固定应用。", "No matching apps available to pin.", language: lang)
                        )
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                    } else {
                        ForEach(candidates) { app in
                            Button {
                                var next = pinnedBundleIDs
                                next.append(app.bundleIdentifier)
                                let res = coordinator.setWatchPinnedApps(next)
                                coordinator.flashBanner(res.detail)
                                if next.count >= WatchPinnedApps.maxCount {
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    DataImageView(
                                        pngData: iconData(for: app.bundleIdentifier),
                                        fallbackSymbol: "app.fill",
                                        tint: palette.secondaryText
                                    )
                                    .frame(width: 24, height: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.appName)
                                            .font(ChocType.body)
                                            .foregroundStyle(palette.primaryText)
                                            .lineLimit(1)
                                        Text(app.bundleIdentifier)
                                            .font(ChocType.micro)
                                            .foregroundStyle(palette.secondaryText)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(palette.accent)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(pinnedBundleIDs.count >= WatchPinnedApps.maxCount)
                        }
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 340)

            HStack {
                Spacer()
                Button(L10n.tr("完成", "Done", language: lang)) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(palette.backgroundTop)
        .onAppear {
            if coordinator.installedApps.isEmpty {
                coordinator.refreshCatalog()
            }
        }
    }

    private func iconData(for bundleID: String) -> Data? {
        if let installed = coordinator.installedApps.first(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
        }), let png = installed.iconPNGData {
            return png
        }
        return BundledAppIcons.pngData(for: bundleID)
    }
}
