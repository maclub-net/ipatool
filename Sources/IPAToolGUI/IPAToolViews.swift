import AppKit
import SwiftUI
import IPAToolCore

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isAddAccountSheetPresented = false

    var body: some View {
        let section = model.selectedSection ?? .search

        NavigationSplitView {
            SidebarView(selection: $model.selectedSection)
                .navigationSplitViewColumnWidth(min: 248, ideal: 280)
        } detail: {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.06),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        selectedPage(for: section)
                    }
                    .frame(maxWidth: 1100, alignment: .topLeading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }

                if let popup = model.popup {
                    GlobalPopupView(popup: popup) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                            model.dismissPopup()
                        }
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.popup?.id)
        }
        .navigationTitle(section.title)
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            // 沙盒版本首次启动引导用户授权下载目录（LocalRelease 内部自动跳过）
            DispatchQueue.main.async {
                model.promptForDownloadDirectoryAuthorizationIfNeeded()
            }
        }
        .onChange(of: section) { _, newSection in
            if newSection == .purchased && model.purchasedApps.isEmpty && !model.isLoadingPurchased {
                Task { await model.loadPurchasedApps() }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                headerActions(for: section)
            }
        }
        .sheet(isPresented: $isAddAccountSheetPresented, onDismiss: {
            model.clearAccountEditor()
        }) {
            AddAccountSheetView(isPresented: $isAddAccountSheetPresented)
                .environmentObject(model)
                .frame(minWidth: 480, idealWidth: 500, minHeight: 360, idealHeight: 400)
        }
    }

    @ViewBuilder
    private func selectedPage(for section: AppSection) -> some View {
        switch section {
        case .search:
            SearchView()
        case .purchased:
            PurchasedView()
        case .library:
            LibraryView()
        case .accounts:
            AccountsView()
        case .settings:
            SettingsView()
        }
    }

    @ViewBuilder
    private func headerActions(for section: AppSection) -> some View {
        switch section {
        case .search:
            EmptyView()
        case .purchased:
            HeaderActionGroup {
                Button {
                    Task { await model.loadPurchasedApps() }
                } label: {
                    ToolbarActionLabel(title: "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ToolbarActionButtonStyle())
                .disabled(model.isLoadingPurchased)
            }
        case .library:
            HeaderActionGroup {
                Button {
                    model.clearCompletedDownloads()
                } label: {
                    ToolbarActionLabel(title: "Clear Completed", systemImage: "trash")
                }
                .buttonStyle(ToolbarActionButtonStyle())
                .disabled(model.downloadTasks.filter({ $0.status == .completed }).isEmpty)
            }
        case .accounts:
            HeaderActionGroup {
                Button {
                    model.prepareAccountEditor()
                    isAddAccountSheetPresented = true
                } label: {
                    ToolbarActionLabel(title: "Add Account", systemImage: "plus")
                }
                .buttonStyle(ToolbarActionButtonStyle(emphasized: true))
            }
        case .settings:
            HeaderActionGroup {
                Button {
                    Task {
                        let result = await model.resetSettings()
                        model.showMessage(result.message, success: result.success)
                    }
                } label: {
                    ToolbarActionLabel(title: "Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(ToolbarActionButtonStyle())

                Button {
                    Task {
                        let result = await model.saveSettings(model.settingsDraft)
                        model.showMessage(result.message, success: result.success)
                    }
                } label: {
                    ToolbarActionLabel(title: "Save", systemImage: "checkmark")
                }
                .buttonStyle(ToolbarActionButtonStyle(emphasized: true))
            }
        }
    }
}

// MARK: - Sidebar

/// 应用图标（优先使用 AppIcon 资源，回退到 NSApp 应用图标）
private var appIconImage: Image {
    if let nsImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
        return Image(nsImage: nsImage)
    }
    return Image(systemName: "app.fill")
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: AppSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarHeader

            VStack(alignment: .leading, spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selection == section ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
                                Image(systemName: section.systemImage)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(selection == section ? Color.accentColor : .secondary)
                            }
                            .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(section.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(selection == section ? Color.accentColor.opacity(0.10) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selection == section ? Color.accentColor.opacity(0.18) : Color.clear, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    openDecryptDownload()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Decrypted IPA Downloads")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Mac俱乐部")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            sidebarStatusCard
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
    }

    /// 打开砸壳包下载入口：已安装 MaClub 客户端则直接打开，否则跳转官网下载页
    private func openDecryptDownload() {
        // 通过 bundle ID 判断客户端是否已安装，避免硬编码路径（应用可安装在非 /Applications 目录）
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.maclub.mac") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    print("[sidebar] open MaClub failed: \(error.localizedDescription)")
                }
            }
        } else if let url = URL(string: "https://www.maclub.net") {
            NSWorkspace.shared.open(url)
        }
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                appIconImage
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text("IPATool")
                        .font(.system(size: 18, weight: .bold))
                    Text("macOS App Store Tool")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Search, download, and manage App Store apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var sidebarStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let account = model.activeAccount {
                // 已登录：带国旗 + 快捷切换的账号卡片
                Menu {
                    ForEach(model.accounts) { acc in
                        Button {
                            Task { await model.setActiveAccount(acc) }
                        } label: {
                            // macOS Menu 中单 Text 才能正常布局，组合国旗 + 邮箱
                            Text("\(acc.flagEmoji)  \(acc.email)\(acc.needsReauth ? "  ⚠️" : "")")
                        }
                    }
                    Divider()
                    Button {
                        model.selectedSection = .accounts
                    } label: {
                        Label("Manage Accounts", systemImage: "person.2.fill")
                    }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        // 国旗 + 首字母头像
                        ZStack {
                            Circle()
                                .fill(Color.brandGradient)
                                .frame(width: 36, height: 36)
                            Text(String(account.email.prefix(1)).uppercased())
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .overlay(
                            Text(account.flagEmoji)
                                .font(.system(size: 12))
                                .offset(x: 12, y: 12)
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(account.regionDisplayName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Circle()
                                    .fill(account.needsReauth ? Color.orange : Color.green)
                                    .frame(width: 6, height: 6)
                                Text(account.needsReauth ? String(localized: "Sign-in Required") : String(localized: "Signed In"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(account.needsReauth ? Color.orange : .secondary)
                            }
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // 未登录
                Button {
                    model.selectedSection = .accounts
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Circle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Not Signed In")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("Click to sign in with an Apple ID")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Search View

struct SearchView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.hasSearched && model.searchResults.isEmpty {
            searchHero
        } else {
            searchWithResults
        }
    }

    // MARK: - 初始状态：居中的搜索英雄区
    private var searchHero: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 18) {
                // Logo：直接显示应用图标，不叠加渐变背景
                appIconImage
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)

                VStack(spacing: 6) {
                    Text("IPATool")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Search the App Store and download IPA files")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                // 搜索框
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search App Store", text: $model.searchTerm)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onSubmit { Task { await model.performSearch() } }

                    Button {
                        Task { await model.performSearch() }
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.searchTerm.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.brandSecondary)
                    .disabled(model.isSearching || model.searchTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.nsBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: 680)
                .onChange(of: model.searchTerm) { _, newValue in
                    // 输入停顿后自动搜索（debounce 600ms）
                    let term = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !term.isEmpty else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        // 再次确认文本未变化
                        guard model.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
                        await model.performSearch()
                    }
                }

                // 平台筛选（换行布局，避免水平滚动截断）
                VStack(alignment: .leading, spacing: 10) {
                    Text("Platform")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    PlatformFilterChips(selected: $model.searchPlatform)
                }
                .frame(maxWidth: 680)

                // 当前账号提示
                if let account = model.activeAccount {
                    HStack(spacing: 8) {
                        Text(account.flagEmoji ?? "🏳️")
                            .font(.system(size: 16))
                        Text(account.email)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .onTapGesture {
                        model.selectedSection = .accounts
                    }
                } else {
                    Button {
                        model.selectedSection = .accounts
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.badge.plus")
                            Text("Sign in with Apple ID")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brandSecondary)
                }

                if model.isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching...").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - 有结果状态
    private var searchWithResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 顶部搜索条
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search App Store", text: $model.searchTerm)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await model.performSearch() } }

                    Button {
                        Task { await model.performSearch() }
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brandSecondary)
                    .disabled(model.isSearching)

                    Button {
                        model.resetSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.nsBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .onChange(of: model.searchTerm) { _, newValue in
                    let term = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !term.isEmpty else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard model.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines) == term else { return }
                        await model.performSearch()
                    }
                }

                PlatformFilterChips(selected: $model.searchPlatform)

                // 结果统计
                HStack {
                    Text(model.isSearching ? String(localized: "Searching...") : String(localized: "\(model.searchResults.count) results"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if model.isSearching && model.searchResults.isEmpty {
                    ContentUnavailableView("Searching", systemImage: "magnifyingglass", description: Text("Querying the App Store..."))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 300)
                } else if model.searchResults.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("Try a different keyword."))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 300)
                } else {
                    // 网格布局
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(model.searchResults) { app in
                            AppResultGridCard(app: app) {
                                model.openAppDetail(app)
                            } onDownload: {
                                Task { await model.downloadApp(app) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: Binding(
            get: { model.selectedApp != nil },
            set: { if !$0 { model.closeAppDetail() } }
        )) {
            AppDetailView()
        }
    }
}

// MARK: - 平台筛选标签
private struct PlatformFilterChips: View {
    @Binding var selected: Platform?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            PlatformChip(label: String(localized: "All"), icon: "square.grid.2x2.fill", isSelected: selected == nil) {
                selected = nil
            }
            ForEach(Platform.allCases, id: \.self) { platform in
                PlatformChip(label: platform.displayName, icon: platform.systemImage, isSelected: selected == platform) {
                    selected = (selected == platform) ? nil : platform
                }
            }
        }
    }
}

private struct PlatformChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.brandPrimary.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.brandSecondary.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.brandSecondary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 网格卡片
private struct AppResultGridCard: View {
    let app: AppStoreApp
    let onTap: () -> Void
    let onDownload: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                AppIconView(urlString: app.artworkUrl, size: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.trackName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        ForEach(app.platforms.prefix(3), id: \.self) { p in
                            Image(systemName: p.systemImage)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        if !app.version.isEmpty {
                            Text("v\(app.version)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !app.sellerName.isEmpty {
                        Text(app.sellerName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.brandSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.nsBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Purchased View

struct PurchasedView: View {
    @EnvironmentObject private var model: AppModel

    private var filteredApps: [OwnedApp] {
        guard let platform = model.purchasedPlatform else { return model.purchasedApps }
        return model.purchasedApps.filter { $0.platforms.contains(platform) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 当前账号信息
                if let account = model.activeAccount {
                    HStack(spacing: 12) {
                        Text(account.flagEmoji)
                            .font(.system(size: 28))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                                .font(.system(size: 15, weight: .semibold))
                            Text("Purchased Apps · \(account.regionDisplayName)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.brandGradient.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.brandSecondary.opacity(0.2), lineWidth: 1)
                    )
                }

                // 平台筛选
                PlatformFilterChips(selected: $model.purchasedPlatform)

                // 结果统计
                HStack {
                    Text(model.isLoadingPurchased ? String(localized: "Loading...") : String(localized: "\(filteredApps.count) purchased apps"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if model.isLoadingPurchased {
                    ContentUnavailableView("Loading Purchased Apps", systemImage: "bag.fill", description: Text("Please wait..."))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 320)
                } else if filteredApps.isEmpty {
                    ContentUnavailableView("No Purchased Apps", systemImage: "bag", description: Text("Click Refresh in the top-right corner, or change the platform filter."))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 320)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(filteredApps) { owned in
                            OwnedAppCard(owned: owned) {
                                model.openOwnedAppDetail(owned)
                            } onDownload: {
                                Task { await model.downloadOwnedApp(owned) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: Binding(
            get: { model.selectedApp != nil },
            set: { if !$0 { model.closeAppDetail() } }
        )) {
            AppDetailView()
        }
    }
}

private struct OwnedAppCard: View {
    let owned: OwnedApp
    let onTap: () -> Void
    let onDownload: () -> Void

    private var dateString: String {
        guard let date = owned.purchaseDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // 应用图标（优先 artwork，回退首字母占位）
            AppIconView(urlString: owned.artworkUrl, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(owned.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ForEach(owned.platforms.prefix(4), id: \.self) { p in
                        Image(systemName: p.systemImage)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if !owned.version.isEmpty {
                        Text("v\(owned.version)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if !dateString.isEmpty {
                        Text(dateString)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                if !owned.bundleId.isEmpty {
                    Text(owned.bundleId)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.brandSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.nsBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

/// 应用图标：优先加载远程 artwork，失败时回退到占位图标
private struct AppIconView: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.blue.opacity(0.12))
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.blue)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - App Detail View

private struct AppDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let app = model.selectedApp {
                // ── Header ──
                HStack(alignment: .top, spacing: 16) {
                    AppIconView(urlString: app.artworkUrl, size: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.trackName)
                            .font(.system(size: 18, weight: .bold))
                            .lineLimit(2)
                        if !app.sellerName.isEmpty {
                            Text(app.sellerName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            DetailBadge(text: priceText(app), tint: (app.price ?? 0) == 0 ? .green : .orange)
                            if !app.version.isEmpty {
                                DetailBadge(text: "v\(app.version)", tint: .brandSecondary)
                            }
                        }
                    }

                    Spacer()

                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Divider()
                    .padding(.top, 16)

                // ── Body ──
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        versionsSection(app)
                        infoSection(app)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }

                Divider()

                // ── Footer ──
                HStack(spacing: 10) {
                    Button {
                        Task { await model.purchaseApp(app) }
                    } label: {
                        ActionButtonLabel(title: "Purchase App", systemImage: "bag.fill")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Spacer()

                    Button {
                        Task { await model.downloadApp(app) }
                        dismiss()
                    } label: {
                        ActionButtonLabel(title: "Download Latest", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
    }

    private func priceText(_ app: AppStoreApp) -> String {
        guard let price = app.price, price > 0 else { return String(localized: "Free") }
        return String(format: "¥%.2f", price)
    }

    // MARK: 基本信息

    private func infoSection(_ app: AppStoreApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Basic Information", systemImage: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            DetailInfoRow(label: "Bundle ID", value: app.bundleId)
            DetailInfoRow(label: "Apple ID", value: "\(app.trackId)")
            DetailInfoRow(label: "Price", value: priceText(app))
            if !app.version.isEmpty {
                DetailInfoRow(label: "Version", value: app.version)
            }
            if !app.sellerName.isEmpty {
                DetailInfoRow(label: "Developer", value: app.sellerName)
            }
            if !app.platforms.isEmpty {
                DetailInfoRow(label: "Platform", value: app.platforms.map(\.displayName).joined(separator: String(localized: ", ")))
            }
        }
    }

    // MARK: Versions Section

    private func versionsSection(_ app: AppStoreApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Version History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.isLoadingVersions && !model.appVersions.isEmpty {
                    DetailBadge(text: String(localized: "\(model.appVersions.count) versions"), tint: .secondary)
                }
            }

            if model.isLoadingVersions {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading version list...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
            } else if model.appVersions.isEmpty {
                ContentUnavailableView("No Version Information", systemImage: "square.stack.3d.up.slash", description: Text("The app may not have been purchased yet, or the version list is unavailable."))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 140)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.appVersions) { version in
                        versionRow(app: app, version: version)
                    }
                }
            }
        }
    }

    private func versionRow(app: AppStoreApp, version: AppVersion) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(version.isLatest ? Color.green.opacity(0.15) : Color.secondary.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: version.isLatest ? "checkmark.seal.fill" : "archivebox")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(version.isLatest ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if version.version != nil {
                        Text("Version \(version.displayName)")
                            .font(.system(size: 15, weight: .semibold))
                    } else {
                        Text("Version \(version.externalVersionID)")
                            .font(.system(size: 15, weight: .semibold))
                        ProgressView().controlSize(.small)
                    }
                }

                HStack(spacing: 6) {
                    Text("ID: \(version.externalVersionID)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let date = version.formattedDate {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(date)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            if version.isLatest {
                Text("Latest")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green))
            }

            Button {
                Task { await model.downloadApp(app, externalVersionID: version.externalVersionID) }
                dismiss()
            } label: {
                ActionButtonLabel(title: "Download", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(SecondaryActionButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear {
            Task { await model.fetchVersionMetadataIfNeeded(versionID: version.id, appID: app.trackId) }
        }
    }
}

// MARK: - 详情页徽标

private struct DetailBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

// MARK: - 详情页信息行

private struct DetailInfoRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Library View

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScaffold {
            MetricsGrid(items: [
                .init(title: "All Tasks", value: "\(model.downloadTasks.count)", icon: "tray.full.fill", tint: .blue),
                .init(title: "Downloading", value: "\(model.activeDownloads)", icon: "arrow.down.circle.fill", tint: .orange),
                .init(title: "Completed", value: "\(model.completedDownloads)", icon: "checkmark.circle.fill", tint: .green)
            ])

            libraryCard
        }
        .confirmationDialog(
            model.removalRequest?.title ?? "",
            isPresented: Binding(
                get: { model.removalRequest != nil },
                set: { if !$0 { model.cancelRemoval() } }
            ),
            titleVisibility: .visible
        ) {
            if let request = model.removalRequest {
                if request.hasDeletableFiles {
                    Button("Delete Files Too", role: .destructive) {
                        model.confirmRemoval(deleteFiles: true)
                    }
                    Button("Remove Records Only", role: .destructive) {
                        model.confirmRemoval(deleteFiles: false)
                    }
                } else {
                    Button("Remove Records", role: .destructive) {
                        model.confirmRemoval(deleteFiles: false)
                    }
                }
                Button("Cancel", role: .cancel) {
                    model.cancelRemoval()
                }
            }
        } message: {
            if let request = model.removalRequest, request.hasDeletableFiles {
                Text("The selected download records include downloaded files. Delete the local files as well?")
            } else {
                Text("This only removes the download records and will not delete local files.")
            }
        }
    }

    private var libraryCard: some View {
        SectionCard(title: "Downloads", subtitle: "Shows downloaded apps and their status.") {
            if model.downloadTasks.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "square.and.arrow.down", description: Text("Find apps in Search and start downloading."))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 320)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(model.downloadTasks) { task in
                        DownloadTaskRowCard(task: task) {
                            model.removeDownloadTask(task)
                        } onReveal: {
                            model.openDownloadLocation(task)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct DownloadTaskRowCard: View {
    let task: DownloadTask
    let onRemove: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                AppIconView(urlString: task.app.artworkUrl, size: 48)

                if task.status == .downloading {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(2)
                        .background(.ultraThinMaterial, in: Circle())
                        .offset(x: 4, y: 4)
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(statusTint, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(task.app.trackName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)

                    statusBadge
                }

                Text(task.app.bundleId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if task.status == .completed {
                    Button(action: onReveal) {
                        ToolbarActionLabel(title: "Reveal", systemImage: "folder")
                    }
                    .buttonStyle(ToolbarActionButtonStyle())
                    .disabled(task.outputURL == nil)
                }

                Button(role: .destructive, action: onRemove) {
                    ToolbarActionLabel(title: "Remove", systemImage: "trash")
                }
                .buttonStyle(ToolbarActionButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(0.035))

                    // 下载进度以「冲水」效果作为卡片背景从左向右填充，
                    // 不占用布局空间，卡片内容不会因进度条出现/消失而变化
                    if task.status == .downloading {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(statusTint.opacity(0.16))
                            .frame(width: geo.size.width * min(max(task.progress, 0), 1))
                    }
                }
            }
        )
        .animation(.easeOut(duration: 0.25), value: task.progress)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var statusTint: Color {
        switch task.status {
        case .pending: return .orange
        case .downloading: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var statusIcon: String {
        switch task.status {
        case .pending: return "clock"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusBadge: some View {
        Text(task.status == .downloading
             ? "\(task.status.displayName) \(Int(task.progress * 100))%"
             : task.status.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusTint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Accounts View

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScaffold {
            MetricsGrid(items: [
                .init(title: "Configured Accounts", value: "\(model.accounts.count)", icon: "person.2.fill", tint: .blue),
                .init(title: "Regions Covered", value: "\(Set(model.accounts.map { $0.region }).count)", icon: "globe.asia.australia.fill", tint: .green),
                .init(title: "Current Account", value: model.activeAccount?.email ?? String(localized: "None"), icon: "person.crop.circle.fill", tint: .purple)
            ])

            VStack(alignment: .leading, spacing: 20) {
                accountsListCard
                accountsGuideCard
            }
        }
        .task {
            // refresh if needed
        }
    }

    private var accountsListCard: some View {
        SectionCard(title: "Configured Accounts", subtitle: "Account credentials are managed through the App Store sign-in flow.") {
            if model.accounts.isEmpty {
                ContentUnavailableView("No Accounts", systemImage: "person.2", description: Text("Click \"Add Account\" in the top-right corner to get started."))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 320)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(model.accounts.sorted { $0.region < $1.region }) { account in
                        AccountRowCard(account: account) {
                            model.setActiveAccount(account)
                        } onDelete: {
                            model.deleteAccount(account)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var accountsGuideCard: some View {
        SectionCard(title: "Add Account", subtitle: "Click the \"Add Account\" button at the top right.") {
            VStack(alignment: .leading, spacing: 14) {
                SelectableValueBlock(text: "1. Click \"Add Account\" in the top-right corner\n2. Choose a region and enter your Apple ID\n3. Your credentials will be verified through the App Store sign-in service")
                Text("Multiple regional accounts are supported, and you can switch the active account at any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AccountRowCard: View {
    let account: AppAccount
    let onActivate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                Text(RegionOption.flag(for: account.region))
                    .font(.system(size: 18))
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(RegionOption.label(for: account.region))
                        .font(.subheadline.weight(.semibold))

                    Text(account.region.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12), in: Capsule())

                    if account.isActive {
                        Text("Current")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }

                    if account.needsReauth {
                        Text("Sign-in Required")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                Text(account.email)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if !account.name.isEmpty {
                    Text(account.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if !account.isActive {
                    Button(action: onActivate) {
                        ToolbarActionLabel(title: "Switch", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(ToolbarActionButtonStyle())
                }

                Button(role: .destructive, action: onDelete) {
                    ToolbarActionLabel(title: "Delete", systemImage: "trash")
                }
                .buttonStyle(ToolbarActionButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScaffold {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 20) {
                        directorySettingsCard
                        behaviorSettingsCard
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    sapSettingsCard
                        .frame(width: 420)
                }

                VStack(alignment: .leading, spacing: 20) {
                    directorySettingsCard
                    behaviorSettingsCard
                    sapSettingsCard
                }
            }
        }
    }

    private var directorySettingsCard: some View {
        SectionCard(title: "Folder", subtitle: "Choose where IPA files are saved.") {
            VStack(alignment: .leading, spacing: 18) {
                DirectoryPickerField(
                    title: "Download Folder",
                    caption: "Downloaded IPA files will be saved to this folder.",
                    placeholder: "~/IPATool/downloads",
                    defaultValue: "~/IPATool/downloads",
                    text: $model.settingsDraft.downloadDirectory,
                    bookmark: $model.settingsDraft.downloadBookmark
                )
            }
        }
    }

    private var behaviorSettingsCard: some View {
        SectionCard(title: "Download Behavior", subtitle: "Control what happens after downloads complete.") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Keep Original Files", isOn: $model.settingsDraft.keepOriginal)
                    .toggleStyle(.switch)

                Toggle("Reveal in Finder after download", isOn: $model.settingsDraft.autoImport)
                    .toggleStyle(.switch)
            }
        }
    }

    private var sapSettingsCard: some View {
        SectionCard(title: "SAP Signing Engine", subtitle: "FairPlay signing service status.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(model.sapStatus.label, systemImage: model.sapStatus == .ready ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.sapStatus.tint)

                    Spacer()

                    Button {
                        Task { await model.setupSAP() }
                    } label: {
                        ActionButtonLabel(title: model.sapStatus == .loading ? "Initializing" : (model.sapStatus == .failed ? "Retry" : "Initialize"), systemImage: "bolt.fill")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(model.sapStatus == .loading || model.sapStatus == .ready)
                }

                Text("The SAP engine signs App Store requests with FairPlay and is required before downloading apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Add Account Sheet

private struct AddAccountSheetView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var isLoading = false

    var body: some View {
        Group {
            if model.accountEditor.awaiting2FA {
                otpView
            } else {
                formView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color.brandPrimary.opacity(0.06), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - 2FA 验证码输入
    private var otpView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.brandSecondary)

                VStack(spacing: 6) {
                    Text("Two-Factor Authentication")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Enter the 6-digit code sent to your devices")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                OTPCodeField(code: $model.accountEditor.code, length: 6) { code in
                    submit(withCode: code)
                }

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Verifying...").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Button("Back") {
                    model.accountEditor.awaiting2FA = false
                    model.accountEditor.code = ""
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    private func submit(withCode code: String) {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let result = await model.addAccountFromEditor()
            model.showMessage(result.message, success: result.success)
            if result.success {
                isPresented = false
                model.clearAccountEditor()
            } else if !model.accountEditor.awaiting2FA {
                // 登录失败且不是 2FA，重置验证码
                model.accountEditor.code = ""
            }
            isLoading = false
        }
    }

    // MARK: - 账号表单
    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add Account")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Enter your Apple ID credentials and sign in")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .padding(8)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 14) {
                    FieldBlock(title: "Region") {
                        RegionPickerField(selection: $model.accountEditor.region)
                    }

                    FieldBlock(title: "Apple ID Email") {
                        AppTextField("name@example.com", text: $model.accountEditor.email)
                    }

                    FieldBlock(title: "Password") {
                        AppSecureField("Enter password", text: $model.accountEditor.password)
                    }
                }

                HStack(spacing: 10) {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .buttonStyle(SecondaryActionButtonStyle())

                    Button {
                        isLoading = true
                        Task {
                            let result = await model.addAccountFromEditor()
                            model.showMessage(result.message, success: result.success)
                            if result.success {
                                isPresented = false
                                model.clearAccountEditor()
                            }
                            isLoading = false
                        }
                    } label: {
                        ActionButtonLabel(title: isLoading ? "Signing In" : "Sign In & Save", systemImage: "person.badge.key.fill")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(isLoading || model.accountEditor.region.isEmpty || model.accountEditor.email.isEmpty || model.accountEditor.password.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - 6 位验证码输入框
private struct OTPCodeField: View {
    @Binding var code: String
    let length: Int
    let onComplete: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // 隐藏的输入框，实际接收输入
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .opacity(0)
                .frame(width: 1, height: 1)
                .onChange(of: code) { _, newValue in
                    let filtered = newValue.filter { $0.isNumber }
                    if filtered.count > length {
                        code = String(filtered.prefix(length))
                    } else if filtered != newValue {
                        code = filtered
                    }
                    if code.count == length {
                        onComplete(code)
                    }
                }

            // 可视化的 6 个格子
            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in
                    let digit = digit(at: index)
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        isFocused && index == code.count ? Color.brandSecondary : Color.primary.opacity(0.1),
                                        lineWidth: 1.5
                                    )
                            )
                        Text(digit)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 44, height: 52)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
    }

    private func digit(at index: Int) -> String {
        let chars = Array(code)
        if index < chars.count {
            return String(chars[index])
        }
        return ""
    }
}

// MARK: - 可搜索的地区选择器
private struct RegionPickerField: View {
    @Binding var selection: String
    @State private var isPresented = false
    @State private var searchText = ""

    private var selectedRegion: RegionOption? {
        RegionOption.all.first { $0.code == selection }
    }

    var body: some View {
        Button {
            isPresented = true
            searchText = ""
        } label: {
            InputSurface {
                HStack(spacing: 10) {
                    if let region = selectedRegion {
                        Text(region.flag)
                            .font(.system(size: 18))
                        Text(region.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                    } else {
                        Text("Select a region")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RegionPickerPopover(selection: $selection, searchText: $searchText)
                .frame(width: 340, height: 420)
        }
    }
}

private struct RegionPickerPopover: View {
    @Binding var selection: String
    @Binding var searchText: String
    @Environment(\.dismiss) private var dismiss

    private var filteredRegions: [RegionOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return RegionOption.all }
        return RegionOption.all.filter { region in
            region.code.lowercased().contains(query) ||
            region.displayName.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search country code or name", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.04))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredRegions) { region in
                        Button {
                            selection = region.code
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text(region.flag)
                                    .font(.system(size: 18))
                                Text(region.displayName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(region.code.uppercased())
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                if selection == region.code {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.brandSecondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selection == region.code ? Color.brandPrimary.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if filteredRegions.isEmpty {
                        Text("No matching regions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    }
                }
                .padding(8)
            }
        }
    }
}

// MARK: - Shared Components

private struct HeaderActionGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content() }
            VStack(alignment: .leading, spacing: 10) { content() }
        }
    }
}

private struct ToolbarActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12.5, weight: .semibold))
            .labelStyle(.titleAndIcon)
    }
}

private struct ActionButtonLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .labelStyle(.titleAndIcon)
    }
}

private struct ToolbarActionButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background(configuration: configuration))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(borderColor(configuration: configuration), lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.role == .destructive ? 0.92 : 1)
    }

    private func background(configuration: Configuration) -> some ShapeStyle {
        if emphasized {
            return AnyShapeStyle(Color.accentColor.opacity(configuration.isPressed ? 0.78 : 0.92))
        }
        return AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.08 : 0.05))
    }

    private func borderColor(configuration: Configuration) -> Color {
        if emphasized { return .accentColor.opacity(0.18) }
        return .primary.opacity(0.08)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.78 : 0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.16), radius: 10, x: 0, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct GlobalPopupView: View {
    let popup: AppPopup
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(popup.title)
                        .font(.headline)

                    Spacer(minLength: 0)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Text(popup.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(backgroundColor)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 22, x: 0, y: 12)
    }

    private var iconName: String {
        switch popup.level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch popup.level {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        }
    }

    private var borderColor: Color {
        switch popup.level {
        case .info: return .blue.opacity(0.22)
        case .success: return .green.opacity(0.22)
        case .error: return .red.opacity(0.20)
        }
    }

    private var backgroundColor: Color {
        switch popup.level {
        case .info: return .blue.opacity(0.16)
        case .success: return .green.opacity(0.16)
        case .error: return .red.opacity(0.16)
        }
    }
}

private struct PageScaffold<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            content()
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 16, x: 0, y: 10)
    }
}

private struct MetricsGrid: View {
    let items: [MetricItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                ForEach(items) { item in
                    MetricCard(item: item)
                }
            }
            VStack(spacing: 12) {
                ForEach(items) { item in
                    MetricCard(item: item)
                }
            }
        }
    }
}

private struct MetricCard: View {
    let item: MetricItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(item.tint.opacity(0.14))
                Image(systemName: item.icon)
                    .foregroundStyle(item.tint)
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct FieldBlock<Content: View>: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    init(title: LocalizedStringKey, caption: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }
}

private struct InputSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct AppTextField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    init(_ placeholder: LocalizedStringKey, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        InputSurface {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
        }
    }
}

private struct AppSecureField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    init(_ placeholder: LocalizedStringKey, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        InputSurface {
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
        }
    }
}

private struct DirectoryPickerField: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey?
    let placeholder: LocalizedStringKey
    let defaultValue: String
    @Binding var text: String
    /// 可选：选择目录后同步生成安全作用域书签（沙盒持久授权），恢复默认时清除
    var bookmark: Binding<Data?>?

    var body: some View {
        FieldBlock(title: title, caption: caption) {
            HStack(alignment: .center, spacing: 10) {
                AppTextField(placeholder, text: $text)

                Button {
                    chooseDirectory()
                } label: {
                    ToolbarActionLabel(title: "Choose Folder", systemImage: "folder")
                }
                .buttonStyle(ToolbarActionButtonStyle())

                Button {
                    text = defaultValue
                    bookmark?.wrappedValue = nil
                } label: {
                    ToolbarActionLabel(title: "Reset to Default", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(ToolbarActionButtonStyle())
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")

        let initialPath = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultValue : text
        let expandedPath = expandTildeInPath(initialPath)
        if FileManager.default.fileExists(atPath: expandedPath) {
            panel.directoryURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        }

        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
            if let bookmark {
                bookmark.wrappedValue = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        }
    }
}

private struct AppMenuField<MenuContent: View>: View {
    let title: String
    var isEnabled = true
    @ViewBuilder var menuContent: () -> MenuContent

    var body: some View {
        Menu {
            menuContent()
        } label: {
            InputSurface {
                HStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(isEnabled ? .secondary : .tertiary)
                    .frame(width: 44, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct MenuOptionRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 12)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }
}

private struct SelectableValueBlock: View {
    let text: LocalizedStringKey
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(tint == .accentColor ? .primary : tint)
            .textSelection(.enabled)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }
}
