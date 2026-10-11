import SwiftUI

struct SearchView: View {
    @ObservedObject var service: AppStoreService
    @State private var searchTerm = ""
    @State private var searchResults: [AppInfo] = []
    @State private var isSearching = false
    @State private var selectedApp: AppInfo? = nil
    @State private var selectedPlatform: String? = nil
    @State private var appIdInput = ""

    private var appIdInt: Int64? { Int64(appIdInput.trimmingCharacters(in: .whitespaces)) }

    private let platforms: [(label: String, value: String?)] = [
        ("全部", nil), ("iOS", "iphone"), ("iPad", "ipad"),
        ("Apple TV", "appletv"), ("macOS", "macos")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 账号选择
            SectionCard(title: "当前账号", subtitle: "将使用该地区账号进行搜索和下载") {
                InputSurface {
                    Menu {
                        ForEach(service.accounts) { account in
                            Button {
                                service.selectedAccount = account
                            } label: {
                                MenuOptionRow(
                                    title: "\(account.name) (\(account.regionDisplayName))",
                                    isSelected: account.id == service.selectedAccount?.id
                                )
                            }
                        }

                        if service.accounts.isEmpty {
                            Text("暂无账号").foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            if let acc = service.selectedAccount {
                                Text("\(acc.name) — \(acc.regionDisplayName)")
                                    .foregroundStyle(.primary)
                            } else {
                                Text("请先添加并选择账号")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // 搜索
            SectionCard(title: "搜索应用", subtitle: "输入应用名称或 Bundle ID") {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        AppTextField("请输入 App 名称 / Bundle ID", text: $searchTerm)
                            .onSubmit { performSearch() }

                        Button {
                            performSearch()
                        } label: {
                            HStack(spacing: 6) {
                                if isSearching {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Text("搜索")
                            }
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .disabled(isSearching || service.selectedAccount == nil || searchTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    // 平台选择
                    HStack(spacing: 6) {
                        ForEach(platforms, id: \.label) { platform in
                            Button {
                                selectedPlatform = platform.value
                            } label: {
                                Text(platform.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(selectedPlatform == platform.value ? Color.appAccent.opacity(0.18) : Color.primary.opacity(0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(selectedPlatform == platform.value ? Color.appAccent.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
                                    )
                                    .foregroundStyle(selectedPlatform == platform.value ? Color.appAccent : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
            }

            // 按 App ID 直接操作
            SectionCard(title: "按 App ID 操作", subtitle: "已知 Apple ID 时可直接购买或下载") {
                HStack(spacing: 10) {
                    AppTextField("输入 App ID（数字）", text: $appIdInput)
                        .onSubmit { /* allow enter to focus buttons */ }

                    Button {
                        purchaseByAppID()
                    } label: {
                        Image(systemName: "cart.badge.plus")
                        Text("购买")
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(appIdInt == nil || service.selectedAccount == nil)

                    Button {
                        downloadByAppID()
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                        Text("下载")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(appIdInt == nil || service.selectedAccount == nil)
                }
            }

            // 结果
            if !searchResults.isEmpty {
                SectionCard(
                    title: "搜索结果",
                    subtitle: "找到 \(searchResults.count) 个结果"
                ) {
                    LazyVStack(spacing: 2) {
                        ForEach(searchResults) { app in
                            AppResultCard(
                                app: app,
                                service: service,
                                onTap: { selectedApp = app }
                            )
                        }
                    }
                }
            }
        }
        .onChange(of: service.selectedAccount?.id) { _, _ in
            searchTerm = ""
            searchResults = []
        }
        .sheet(item: $selectedApp) { app in
            AppDetailSheetView(service: service, app: app)
                .accentColor(.appAccent)
                .frame(minWidth: 560, idealWidth: 600, minHeight: 540, idealHeight: 600)
        }
    }

    private func performSearch() {
        let term = searchTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        Task {
            isSearching = true
            do {
                searchResults = try await service.search(term: term, platform: selectedPlatform)
            } catch {
                service.log("搜索失败: \(error.localizedDescription)", type: .error)
            }
            isSearching = false
        }
    }

    private func purchaseByAppID() {
        guard let id = appIdInt else { return }
        Task {
            do {
                try await service.purchaseByAppID(id)
                service.log("App \(id) 许可证获取成功", type: .success)
            } catch {
                service.log("购买失败: \(error.localizedDescription)", type: .error)
            }
        }
    }

    private func downloadByAppID() {
        guard let id = appIdInt else { return }
        let app = AppInfo(
            id: id, bundleID: "", name: "App \(id)", version: "",
            price: 0, iconURL: nil, developer: nil, description: nil,
            fileSizeBytes: nil, trackViewURL: nil
        )
        service.enqueueDownload(app: app)
    }
}

// MARK: - 搜索结果卡片

fileprivate struct AppResultCard: View {
    let app: AppInfo
    let service: AppStoreService
    let onTap: () -> Void

    @State private var icon: AppIcon = .unloaded

    var body: some View {
        HStack(spacing: 14) {
            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .frame(width: 60, height: 60)
                AppImageView(icon: icon)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .onTapGesture { onTap() }

            // 信息
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .onTapGesture { onTap() }

                if let dev = app.developer, !dev.isEmpty {
                    Text(dev)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    SectionBadge(text: app.formattedPrice, tint: app.isFree ? .green : .orange)
                    SectionBadge(text: "v\(app.version)", tint: .appAccent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // 操作按钮
            VStack(spacing: 6) {
                Button {
                    service.enqueueDownload(app: app)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("加入下载队列")

                Button {
                    onTap()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("查看详情")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onTap() }
        .task { await loadIcon() }
    }

    private func loadIcon() async {
        guard let urlStr = app.iconURL, let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let nsImage = NSImage(data: data) {
                icon = .success(nsImage)
            }
        } catch {
            icon = .failed
        }
    }
}

// MARK: - 应用详情弹窗

struct AppDetailSheetView: View {
    @ObservedObject var service: AppStoreService
    let app: AppInfo
    @Environment(\.dismiss) private var dismiss

    @State private var icon: AppIcon = .unloaded
    @State private var detail: AppDetail?
    @State private var isLoadingDetail = true
    @State private var detailError: String?
    @State private var isPurchasing = false
    @State private var purchaseMessage: String?
    @State private var versions: [String] = []
    @State private var isLoadingVersions = false
    @State private var versionsError: String?
    @State private var selectedVersionID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──
            HStack(alignment: .top, spacing: 16) {
                AppImageView(icon: icon)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                    if let dev = app.developer, !dev.isEmpty {
                        Text(dev)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        SectionBadge(text: app.formattedPrice, tint: app.isFree ? .green : .orange)
                        SectionBadge(text: "v\(app.version)", tint: .appAccent)
                        if let rating = detail?.averageUserRating, rating > 0 {
                            SectionBadge(text: String(format: "%.1f ★", rating), tint: .yellow)
                        }
                    }
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Divider()
                .padding(.top, 16)

            // ── Body ──
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Loading / Error
                    if isLoadingDetail {
                        HStack {
                            Spacer()
                            ProgressView("加载详细信息...")
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if let detailError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(detailError)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.orange.opacity(0.08))
                        )
                    } else if let detail {
                        contentBody(detail)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            }

            Divider()

            // ── Footer ──
            HStack(spacing: 10) {
                if let url = app.trackViewURL {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("App Store")
                        }
                    }
                    .buttonStyle(SecondaryActionButtonStyle())
                }

                Button {
                    performPurchase()
                } label: {
                    HStack(spacing: 6) {
                        if isPurchasing {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "cart.badge.plus")
                        }
                        Text(isPurchasing ? "购买中..." : "购买许可证")
                    }
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(isPurchasing || !app.isFree)
                .help(app.isFree ? "获取免费应用许可证" : "暂不支持付费应用")

                Spacer()

                Button {
                    service.enqueueDownload(app: app, externalVersionID: selectedVersionID)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                        Text("加入下载队列")
                    }
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            if let purchaseMessage {
                Text(purchaseMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 520, idealWidth: 560)
        .task {
            await loadIcon()
            await loadDetail()
        }
    }

    // MARK: - Body Content

    @ViewBuilder
    private func contentBody(_ detail: AppDetail) -> some View {
        // 基本信息网格
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
            if let genre = detail.primaryGenreName {
                DetailCell(label: "类别", value: genre, icon: "tag")
            }
            if let seller = detail.sellerName {
                DetailCell(label: "开发商", value: seller, icon: "person")
            }
            if detail.fileSizeFormatted != "未知" {
                DetailCell(label: "大小", value: detail.fileSizeFormatted, icon: "internaldrive")
            }
            if let os = detail.minimumOsVersion {
                DetailCell(label: "最低系统", value: os, icon: "apple.logo")
            }
        }

        // 评分
        if let rating = detail.averageUserRating, rating > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Label("评分", systemImage: "star.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(detail.ratingStars)
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 14, weight: .medium))
                    if let count = detail.userRatingCount {
                        Text("(\(count.formatted()) 条评价)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
        }

        // 简介
        if let desc = detail.description, !desc.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("简介", systemImage: "text.alignleft")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(desc)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
            }
        }

        // 更新内容
        if let notes = detail.releaseNotes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("更新内容", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(notes)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
            }
        }

        // 支持语言
        if let langs = detail.languageCodesISO2A, !langs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("语言", systemImage: "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(langs.joined(separator: "、"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }

        // 版本列表
        versionsSection

        // 基本信息
        VStack(alignment: .leading, spacing: 8) {
            Label("基本信息", systemImage: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            InfoRow(label: "Bundle ID", value: app.bundleID)
            InfoRow(label: "Apple ID", value: "\(app.id)")
            if let sizeStr = app.fileSizeBytes, let bytes = Int64(sizeStr), bytes > 0 {
                InfoRow(label: "应用大小", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            if let date = detail.currentVersionReleaseDate {
                InfoRow(label: "更新日期", value: formatDate(date))
            }
            if let rating = detail.trackContentRating {
                InfoRow(label: "分级", value: rating)
            }
        }
    }

    @ViewBuilder
    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("可用版本", systemImage: "list.number")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await loadVersions() }
                } label: {
                    if isLoadingVersions {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .help("刷新版本列表")
            }

            if isLoadingVersions {
                Text("加载中...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let versionsError {
                Text(versionsError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if versions.isEmpty {
                Text("点击刷新按钮获取可用版本")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            selectedVersionID = nil
                        } label: {
                            Text("最新")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selectedVersionID == nil ? Color.appAccent.opacity(0.2) : Color.primary.opacity(0.05))
                                )
                                .foregroundStyle(selectedVersionID == nil ? Color.appAccent : .secondary)
                        }
                        .buttonStyle(.plain)

                        ForEach(versions, id: \.self) { vid in
                            Button {
                                selectedVersionID = vid
                            } label: {
                                Text(vid)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(selectedVersionID == vid ? Color.appAccent.opacity(0.2) : Color.primary.opacity(0.05))
                                    )
                                    .foregroundStyle(selectedVersionID == vid ? Color.appAccent : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("选中版本后点击「加入下载队列」将下载该版本")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func loadIcon() async {
        guard let urlStr = app.iconURL, let url = URL(string: urlStr) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let nsImage = NSImage(data: data) {
                icon = .success(nsImage)
            }
        } catch {
            icon = .failed
        }
    }

    private func loadDetail() async {
        isLoadingDetail = true
        do {
            let region = service.selectedAccount?.region ?? "CN"
            detail = try await service.lookup(appID: app.id, region: region)
        } catch {
            detailError = "无法加载详细信息"
        }
        isLoadingDetail = false
    }

    private func formatDate(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        if let date = formatter.date(from: dateStr) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return dateStr
    }

    private func performPurchase() {
        Task {
            isPurchasing = true
            purchaseMessage = nil
            do {
                try await service.purchase(app: app)
                purchaseMessage = "许可证获取成功，可以下载了"
            } catch {
                purchaseMessage = "购买失败: \(error.localizedDescription)"
            }
            isPurchasing = false
        }
    }

    private func loadVersions() async {
        isLoadingVersions = true
        versionsError = nil
        do {
            versions = try await service.listVersions(appID: app.id)
            if versions.isEmpty {
                versionsError = "未找到可用版本"
            }
        } catch {
            versionsError = "加载失败: \(error.localizedDescription)"
        }
        isLoadingVersions = false
    }
}

// MARK: - 详情网格单元格

private struct DetailCell: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.appAccent.opacity(0.1))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}