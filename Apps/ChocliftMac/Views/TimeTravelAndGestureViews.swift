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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("应用时间旅行 (App Time Travel)", "App Time Travel", language: lang))
                        .font(.title3.bold())
                    Text(L10n.tr("动态追踪最近打开与切换的 Mac 应用，固定常用项，告别繁琐的 ⌘Tab 循环切换（支持拖拽文件时点选目标应用 Drag & Drop 2.0）。", "Dynamically tracks recently opened Mac apps with pin support and instant Drag & Drop 2.0 target switching.", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Live 8-card iPhone Time Travel Strip Preview
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("iPhone 端实时时间旅行视图（前 8 项）", "Live Companion Time Travel Strip (Top 8)", language: lang))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 8), spacing: 12) {
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
                                        .frame(width: 40, height: 40)
                                    if entry.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(palette.accentGold)
                                            .padding(3)
                                            .background(.black.opacity(0.6), in: Circle())
                                            .offset(x: 4, y: -4)
                                    }
                                }
                                Text(entry.appName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(LinearGradient(colors: [palette.tileFillTop, palette.tileFillBottom], startPoint: .top, endPoint: .bottom))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(entry.isFrontmost ? palette.accentGold : .clear, lineWidth: 2)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
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
                .padding(.vertical, 2)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("多指触控手势 (Finger Gestures)", "Multi-Touch Finger Gestures", language: lang))
                        .font(.title3.bold())
                    Text(L10n.tr("在 iPhone / iPad 触控栏任意区域使用双指或三指手势，即可远程控制 Mac 窗口最大化、最小化、贴靠分屏及复制粘贴。", "Perform 2-finger or 3-finger gestures anywhere on your companion screen to manage Mac windows & clipboard.", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    L10n.tr("启用全局手势覆盖层", "Enable Global Touch Gestures", language: lang),
                    isOn: Binding(
                        get: { coordinator.profile.gestureConfig.isGlobalOverlayEnabled },
                        set: { val in
                            coordinator.mutateProfile { $0.gestureConfig.isGlobalOverlayEnabled = val }
                        }
                    )
                )
                .toggleStyle(.switch)
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
                                    in: RoundedRectangle(cornerRadius: 10)
                                )

                            VStack(alignment: .leading, spacing: 3) {
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
                                .controlSize(.mini)
                                .help(L10n.tr("测试该手势动作", "Test Gesture Action", language: lang))
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
    }
}
