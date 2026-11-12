import ChocliftCore
import SwiftUI

// MARK: - App Time Travel Studio

public struct TimeTravelStudioView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var monitor: MacTimeTravelMonitor

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.monitor = coordinator.timeTravel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("应用时间旅行", "App Time Travel", language: lang))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text(L10n.tr("动态记录最近激活的 Mac 应用，固定高频窗口，一键直达而无需循环按 ⌘Tab。", "Tracks recently active Mac apps with favorites pinning for one-tap window switching.", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if monitor.timeline.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundStyle(palette.accentGold)
                    Text(L10n.tr("尚未捕获最近切换的应用", "No Recent Apps Yet", language: lang))
                        .font(.headline)
                    Text(L10n.tr("在任意 Mac 应用之间切换一次，应用时间旅行列表即会实时出现并同步到伴侣设备。", "Switch between any Mac apps to populate the live Time Travel strip across your companions.", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Live 8-card Companion Time Travel Strip Preview
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("伴侣端实时时间旅行预览（前 8 项）", "Companion Time Travel Strip Preview (Top 8)", language: lang))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 8), spacing: 10) {
                        ForEach(Array(monitor.timeline.prefix(8))) { entry in
                            let icon = coordinator.catalogService.iconData(forBundleID: entry.bundleIdentifier, fallbackPath: entry.appPath)
                            Button {
                                Task {
                                    _ = await coordinator.catalogService.launchOrActivateApp(
                                        bundleIdentifier: entry.bundleIdentifier,
                                        appPath: entry.appPath,
                                        windowService: coordinator.windowService
                                    )
                                }
                            } label: {
                                VStack(spacing: 5) {
                                    ZStack(alignment: .topTrailing) {
                                        DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                                            .frame(width: 38, height: 38)
                                        if entry.isPinned {
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(palette.accentGold)
                                                .padding(3)
                                                .background(.black.opacity(0.65), in: Circle())
                                                .offset(x: 4, y: -4)
                                        }
                                    }
                                    Text(entry.appName)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(LinearGradient(colors: [palette.tileFillTop, palette.tileFillBottom], startPoint: .top, endPoint: .bottom))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(entry.isFrontmost ? palette.accentGold : palette.subtleCardStroke, lineWidth: entry.isFrontmost ? 2 : 1)
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    )
                }

                // Full Timeline Table
                List(monitor.timeline) { entry in
                    let icon = coordinator.catalogService.iconData(forBundleID: entry.bundleIdentifier, fallbackPath: entry.appPath)
                    HStack(spacing: 12) {
                        DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: .accentColor)
                            .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.appName)
                                    .font(.body.weight(.semibold))
                                if entry.isFrontmost {
                                    Text(L10n.tr("当前前台", "Frontmost", language: lang))
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                                if !entry.isRunning {
                                    Text(L10n.tr("未运行", "Not Running", language: lang))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(entry.bundleIdentifier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            coordinator.togglePinApp(bundleIdentifier: entry.bundleIdentifier)
                        } label: {
                            Label(
                                entry.isPinned
                                    ? L10n.tr("已固定", "Pinned", language: lang)
                                    : L10n.tr("固定", "Pin", language: lang),
                                systemImage: entry.isPinned ? "pin.slash.fill" : "pin"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(entry.isPinned ? .orange : nil)

                        Button {
                            addAppToFirstAvailableSlot(entry)
                        } label: {
                            Label(L10n.tr("加入巧克力栏", "Add to Bar", language: lang), systemImage: "plus.square.on.square")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task {
                                _ = await coordinator.catalogService.launchOrActivateApp(
                                    bundleIdentifier: entry.bundleIdentifier,
                                    appPath: entry.appPath,
                                    windowService: coordinator.windowService
                                )
                            }
                        } label: {
                            Text(L10n.tr("切换", "Switch", language: lang))
                                .font(.caption.bold())
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
    }

    private func addAppToFirstAvailableSlot(_ entry: RecentAppEntry) {
        let pageIdx = coordinator.selectedPageIndex
        guard coordinator.profile.pages.indices.contains(pageIdx) else { return }
        if let emptySlot = coordinator.profile.pages[pageIdx].slots.firstIndex(where: { $0 == nil }) {
            let item = BarItem(kind: .macApp(
                bundleIdentifier: entry.bundleIdentifier,
                appName: entry.appName,
                appPath: entry.appPath
            ))
            coordinator.setSlotItem(item, pageIndex: pageIdx, slotIndex: emptySlot)
            coordinator.flashBanner(L10n.tr("已将 \(entry.appName) 添加到第 \(pageIdx + 1) 页槽位 #\(emptySlot + 1)", "Added \(entry.appName) to Page \(pageIdx + 1) Slot #\(emptySlot + 1)", language: lang))
        } else {
            coordinator.flashBanner(L10n.tr("当前第 \(pageIdx + 1) 页已满，请先清空一个槽位或切换页面", "Current page is full — switch page or clear a slot first", language: lang))
        }
    }
}

// MARK: - Finger Gestures Studio

public struct GestureStudioView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    private var lang: AppLanguage { coordinator.lang }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("多指触控手势", "Multi-Touch Finger Gestures", language: lang))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text(L10n.tr("在 iPhone / iPad 任意区域执行双指或三指手势控制 Mac 窗口与剪贴板，单指点按仍直达底层按钮。", "Use 2- or 3-finger gestures anywhere on iPhone/iPad while 1-finger taps pass straight through to controls.", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    L10n.tr("启用全局多指手势", "Enable Multi-Touch Gestures", language: lang),
                    isOn: Binding(
                        get: { coordinator.profile.gestureConfig.isGlobalOverlayEnabled },
                        set: { val in
                            coordinator.mutateProfile { $0.gestureConfig.isGlobalOverlayEnabled = val }
                        }
                    )
                )
                .toggleStyle(.switch)
            }

            if !coordinator.profile.gestureConfig.isGlobalOverlayEnabled {
                Label(
                    L10n.tr("全局多指手势已暂停 — iPhone / iPad 手势板中的快捷触发按钮仍可正常点按使用。", "Global multi-touch gestures are paused — quick-trigger buttons on the Gesture Pad remain active.", language: lang),
                    systemImage: "pause.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 12) {
                    ForEach(Array(coordinator.profile.gestureConfig.bindings.enumerated()), id: \.element.id) { idx, binding in
                        HStack(spacing: 12) {
                            Image(systemName: binding.gesture.sfSymbol)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(
                                    binding.isEnabled ? Color(hex: binding.action.accentHex) : Color.gray.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(binding.gesture.title(in: lang))
                                    .font(.subheadline.bold())
                                Text(binding.gesture.subtitle(in: lang))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Picker(
                                    "",
                                    selection: Binding(
                                        get: { coordinator.profile.gestureConfig.bindings[idx].action },
                                        set: { newAction in
                                            coordinator.mutateProfile { $0.gestureConfig.bindings[idx].action = newAction }
                                        }
                                    )
                                ) {
                                    ForEach(SystemQuickAction.allCases) { act in
                                        Text(act.title(in: lang)).tag(act)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                            }

                            Spacer(minLength: 4)

                            VStack(spacing: 8) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { coordinator.profile.gestureConfig.bindings[idx].isEnabled },
                                        set: { enabled in
                                            coordinator.mutateProfile { $0.gestureConfig.bindings[idx].isEnabled = enabled }
                                        }
                                    )
                                )
                                .labelsHidden()
                                .controlSize(.small)

                                Button {
                                    _ = coordinator.executeGesture(binding.gesture, triggeredBy: "Mac Gesture Test")
                                } label: {
                                    Image(systemName: "play.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(L10n.tr("测试该手势动作", "Test Gesture Action", language: lang))
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
    }
}
