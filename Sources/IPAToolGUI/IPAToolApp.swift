import AppKit
import SwiftUI
import IPAToolCore

@main
struct IPAToolApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentSize)
    }
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    // Navigation
    @Published var selectedSection: AppSection? = .search

    // Accounts
    @Published var accounts: [AppAccount] = []
    @Published var activeAccount: AppAccount?

    // Search
    @Published var searchTerm = ""
    @Published var searchResults: [AppStoreApp] = []
    @Published var isSearching = false
    @Published var selectedApp: AppStoreApp?
    @Published var appVersions: [AppVersion] = []
    @Published var isLoadingVersions = false
    @Published var searchPlatform: Platform? = nil
    @Published var hasSearched = false

    // Purchased
    @Published var purchasedApps: [OwnedApp] = []
    @Published var isLoadingPurchased = false
    @Published var purchasedPlatform: Platform? = nil
    /// 已购应用的完整详情（含 artwork），key 为 trackId，供点击卡片打开详情页使用
    @Published var purchasedAppDetails: [Int: AppStoreApp] = [:]

    // Library / Downloads
    @Published var downloadTasks: [DownloadTask] = []

    // Settings
    @Published var settings: AppSettings = .default
    @Published var settingsDraft: AppSettings = .default

    // UI state
    @Published var popup: AppPopup?
    @Published var isAddAccountSheetPresented = false
    @Published var accountEditor = AccountEditorState()
    @Published var sapStatus: SAPStatus = .notReady
    @Published var removalRequest: DownloadRemovalRequest?

    // Services
    let client = AppStoreClient()
    private var signer: SAPSigner?
    private var sapConfig: SAPConfig?
    private var machineGUID: String?
    private var sapAssets: SAPAssets?

    private var popupDismissTask: Task<Void, Never>?

    // MARK: - Persistence

    private enum StorageKey {
        static let accounts = "ipatool.accounts"
        static let settings = "ipatool.settings"
        static let downloadTasks = "ipatool.downloadTasks"
    }

    private func loadPersistedData() {
        let defaults = UserDefaults.standard

        // 账号优先从 Keychain 读取，回退到 UserDefaults（兼容旧数据并迁移）
        if let data = KeychainStore.load(forKey: StorageKey.accounts),
           let decoded = try? JSONDecoder().decode([AppAccount].self, from: data) {
            accounts = decoded
            activeAccount = accounts.first { $0.isActive }
        } else if let data = defaults.data(forKey: StorageKey.accounts),
                  let decoded = try? JSONDecoder().decode([AppAccount].self, from: data) {
            accounts = decoded
            activeAccount = accounts.first { $0.isActive }
            // 迁移到 Keychain 后清除 UserDefaults 中的明文
            saveAccounts()
            defaults.removeObject(forKey: StorageKey.accounts)
        }

        if let data = defaults.data(forKey: StorageKey.settings),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            // 兼容旧数据：展开 ~ 为用户主目录
            var fixed = decoded
            fixed.downloadDirectory = (decoded.downloadDirectory as NSString).expandingTildeInPath
            settings = fixed
        }

        if let data = defaults.data(forKey: StorageKey.downloadTasks),
           let decoded = try? JSONDecoder().decode([DownloadTask].self, from: data) {
            downloadTasks = decoded
        }
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            KeychainStore.save(data, forKey: StorageKey.accounts)
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: StorageKey.settings)
        }
    }

    private func saveDownloadTasks() {
        if let data = try? JSONEncoder().encode(downloadTasks) {
            UserDefaults.standard.set(data, forKey: StorageKey.downloadTasks)
        }
    }

    /// 将当前活跃账号同步到 AppStoreClient，使搜索/购买等接口使用正确的 storefront
    private func syncClientAccount() {
        guard let acc = activeAccount else {
            client.account = nil
            return
        }
        client.account = AccountInfo(
            email: acc.email,
            name: acc.name,
            storeFront: acc.storeFront,
            passwordToken: acc.passwordToken,
            directoryServicesID: acc.dsid,
            pod: acc.pod
        )
    }

    // MARK: - Computed

    var configuredRegions: [RegionOption] {
        RegionOption.all.filter { region in
            accounts.contains { $0.region == region.code }
        }
    }

    /// 可用于新增账号的地区：全部地区（允许同一地区添加多个账号）
    var availableRegionsForAdd: [RegionOption] {
        RegionOption.all
    }

    var activeDownloads: Int {
        downloadTasks.filter { $0.status == .downloading }.count
    }

    var completedDownloads: Int {
        downloadTasks.filter { $0.status == .completed }.count
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        loadPersistedData()
        syncClientAccount()
        settingsDraft = settings
        showMessage("欢迎使用 IPATool", success: true)
        // 自动初始化 SAP 签名引擎
        await setupSAP()
    }

    // MARK: - Search

    func performSearch() async {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            showMessage("请输入搜索关键词", success: false)
            return
        }

        isSearching = true
        searchResults = []
        hasSearched = true

        do {
            let results = try await client.search(term: term, platform: searchPlatform)
            searchResults = results
            if results.isEmpty {
                showMessage("未找到匹配的应用", success: false)
            }
        } catch {
            showMessage("搜索失败：\(error.localizedDescription)", success: false)
        }

        isSearching = false
    }

    /// 重置搜索到初始状态
    func resetSearch() {
        searchTerm = ""
        searchResults = []
        hasSearched = false
    }

    // MARK: - Purchased Apps

    /// 执行需要鉴权的操作，失败时自动尝试刷新 token 并重试一次
    /// - Parameter operation: 需要执行的异步操作
    /// - Returns: 操作结果
    private func withTokenRefresh<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            // 操作失败，尝试用存储的密码自动刷新 token
            guard let account = activeAccount, !account.password.isEmpty, !account.needsReauth else {
                throw error
            }
            print("[withTokenRefresh] operation failed, attempting token refresh for \(account.email)...")
            let refreshed = await refreshToken(for: account)
            guard refreshed else {
                // token 刷新失败（通常遇到 2FA），直接抛出原错误
                throw error
            }
            // token 刷新成功，重试一次
            print("[withTokenRefresh] token refreshed, retrying operation...")
            return try await operation()
        }
    }

    func loadPurchasedApps() async {
        guard let signer = signer, let guid = machineGUID else {
            showMessage("SAP 引擎未就绪，请稍候重试", success: false)
            return
        }
        guard activeAccount != nil else {
            showMessage("请先登录一个 Apple ID 账号", success: false)
            return
        }

        isLoadingPurchased = true
        purchasedApps = []
        purchasedAppDetails = [:]

        do {
            let apps = try await withTokenRefresh {
                try await client.ownedApps(signer: signer, guid: guid)
            }
            purchasedApps = apps
            if purchasedApps.isEmpty {
                showMessage("未找到已购应用", success: false)
            } else {
                // 批量补全 artwork URL 与完整详情
                let ids = apps.map { $0.id }
                if let details = try? await client.lookupApps(byIDs: ids) {
                    purchasedAppDetails = details
                    // 将 artwork URL 合并回 purchasedApps
                    purchasedApps = apps.map { app in
                        var updated = app
                        updated.artworkUrl = details[app.id]?.artworkUrl
                        return updated
                    }
                }
            }
        } catch {
            showMessage("获取已购应用失败：\(error.localizedDescription)", success: false)
        }

        isLoadingPurchased = false
    }

    /// 下载已购应用（通过 trackId）
    func downloadOwnedApp(_ owned: OwnedApp) async {
        guard accounts.contains(where: { $0.isActive }) else {
            showMessage("请先登录一个 Apple ID 账号", success: false)
            selectedSection = .accounts
            return
        }

        // 构造一个 AppStoreApp 用于下载流程
        let app = AppStoreApp(
            trackId: owned.id,
            trackName: owned.name,
            bundleId: owned.bundleId,
            sellerName: "",
            version: owned.version,
            price: nil,
            artworkUrl: nil,
            platforms: owned.platforms
        )
        await downloadApp(app)
    }

    // MARK: - Downloads

    func downloadApp(_ app: AppStoreApp, externalVersionID: String? = nil) async {
        guard accounts.contains(where: { $0.isActive }) else {
            showMessage("请先登录一个 Apple ID 账号", success: false)
            selectedSection = .accounts
            return
        }

        let versionLabel = externalVersionID.map { "v\($0)" } ?? "最新版"

        // 避免重复下载
        if downloadTasks.contains(where: { $0.app.trackId == app.trackId && $0.status != .failed }) {
            showMessage("该应用已在下载队列中", success: false)
            return
        }

        var task = DownloadTask(app: app, status: .downloading)
        task.startedAt = Date()
        downloadTasks.insert(task, at: 0)

        print("[download] starting: \(app.trackName) (\(versionLabel)), appID=\(app.trackId)")

        do {
            // 1. 请求下载产品信息（token 失效时自动刷新重试）
            print("[download] requesting downloadProduct...")
            let dict = try await withTokenRefresh {
                try await client.downloadProduct(appID: app.trackId, externalVersionID: externalVersionID)
            }
            print("[download] downloadProduct response keys: \(dict.keys.sorted())")

            // 2. 提取下载 URL
            guard let url = client.extractDownloadURL(from: dict) else {
                throw AppStoreError.downloadFailed(message: "响应中没有下载链接")
            }
            print("[download] download URL: \(url.absoluteString)")

            // 3. 确定输出路径（展开 ~ 为用户主目录）
            let expandedDir = (settings.downloadDirectory as NSString).expandingTildeInPath
            let dir = URL(fileURLWithPath: expandedDir, isDirectory: true)

            // 文件名：应用名_版本号(版本序号兜底)_下载账号.ipa
            let safeName = app.trackName.replacingOccurrences(of: "/", with: "-")
            let versionPart: String = {
                if !app.version.isEmpty {
                    return app.version
                }
                if let vid = externalVersionID {
                    return "v\(vid)"
                }
                return "最新版"
            }()
            let accountPart: String = {
                if let acc = activeAccount {
                    let label = acc.name.isEmpty ? acc.email : acc.name
                    return label.replacingOccurrences(of: "/", with: "-")
                }
                return "unknown"
            }()
            let fileName = "\(safeName)_\(versionPart)_\(accountPart).ipa"
            let destination = dir.appendingPathComponent(fileName)
            print("[download] output: \(destination.path)")

            // 4. 下载文件（macOS 包需要解密）
            let dpInfo = client.extractDPInfo(from: dict)
            if let dpInfo = dpInfo {
                // macOS 加密包：下载后解密
                guard let assets = sapAssets else {
                    throw AppStoreError.downloadFailed(message: "SAP 引擎未就绪，无法解密 macOS 包")
                }
                let identity = try currentMachineIdentity()
                print("[download] macOS package detected, decrypting with dpInfo (\(dpInfo.count) bytes)")
                try await client.downloadMacPackage(
                    from: url, to: destination,
                    hardwareID: identity.hardwareID,
                    dpInfo: dpInfo,
                    assets: assets
                ) { p in
                    Task { @MainActor in
                        if let idx = self.downloadTasks.firstIndex(where: { $0.id == task.id }) {
                            self.downloadTasks[idx].progress = p
                        }
                    }
                }
            } else {
                // iOS 包：直接下载
                try await client.downloadFile(from: url, to: destination) { p in
                    Task { @MainActor in
                        if let idx = self.downloadTasks.firstIndex(where: { $0.id == task.id }) {
                            self.downloadTasks[idx].progress = p
                        }
                    }
                }
            }

            // 5. 完成
            if let idx = downloadTasks.firstIndex(where: { $0.id == task.id }) {
                downloadTasks[idx].status = .completed
                downloadTasks[idx].progress = 1.0
                downloadTasks[idx].outputURL = destination
                downloadTasks[idx].completedAt = Date()
            }
            showMessage("\(app.trackName) (\(versionLabel)) 下载完成", success: true)
            print("[download] complete: \(destination.path)")

        } catch {
            print("[download] ERROR: \(error)")
            if let idx = downloadTasks.firstIndex(where: { $0.id == task.id }) {
                downloadTasks[idx].status = .failed
                downloadTasks[idx].errorMessage = error.localizedDescription
            }
            showMessage("下载失败：\(error.localizedDescription)", success: false)
        }
        saveDownloadTasks()
    }

    /// 打开应用详情页并加载历史版本
    func openAppDetail(_ app: AppStoreApp) {
        selectedApp = app
        Task { await loadVersions(for: app) }
    }

    /// 打开已购应用的详情页（优先使用已缓存的完整信息，否则从 OwnedApp 构造）
    func openOwnedAppDetail(_ owned: OwnedApp) {
        if let app = purchasedAppDetails[owned.id] {
            openAppDetail(app)
        } else {
            let app = AppStoreApp(
                trackId: owned.id,
                trackName: owned.name,
                bundleId: owned.bundleId,
                sellerName: "",
                version: owned.version,
                price: nil,
                artworkUrl: owned.artworkUrl,
                platforms: owned.platforms
            )
            openAppDetail(app)
        }
    }

    func closeAppDetail() {
        selectedApp = nil
        appVersions = []
    }

    func loadVersions(for app: AppStoreApp) async {
        isLoadingVersions = true
        defer { isLoadingVersions = false }
        do {
            let versionIDs = try await client.listVersions(appID: app.trackId)
            // 第一个是最新版本
            appVersions = versionIDs.enumerated().map { index, id in
                AppVersion(externalVersionID: id, version: nil, releaseDate: nil, isLatest: index == 0)
            }
            print("[versions] loaded \(appVersions.count) version IDs (lazy metadata)")
        } catch {
            print("[versions] failed: \(error)")
            appVersions = []
        }
    }

    /// 懒加载：当某个版本行出现在屏幕上时，获取其元数据
    func fetchVersionMetadataIfNeeded(versionID: UUID, appID: Int) async {
        guard let index = appVersions.firstIndex(where: { $0.id == versionID }) else { return }
        // 已获取过则跳过
        guard appVersions[index].version == nil else { return }

        let externalID = appVersions[index].externalVersionID
        let meta = await client.getVersionMetadata(appID: appID, externalVersionID: externalID)

        // 再次确认索引未变
        if let idx = appVersions.firstIndex(where: { $0.id == versionID }) {
            appVersions[idx].version = meta.version
            appVersions[idx].releaseDate = meta.date
        }
    }

    func removeDownloadTask(_ task: DownloadTask) {
        removalRequest = .single(task)
    }

    func clearCompletedDownloads() {
        let completed = downloadTasks.filter { $0.status == .completed }
        guard !completed.isEmpty else { return }
        removalRequest = .clearCompleted(completed)
    }

    /// 执行移除操作，deleteFiles 为 true 时同时删除本地文件
    func confirmRemoval(deleteFiles: Bool) {
        guard let request = removalRequest else { return }
        let tasks = request.tasks

        if deleteFiles {
            for task in tasks {
                if let url = task.outputURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        let ids = Set(tasks.map { $0.id })
        downloadTasks.removeAll { ids.contains($0.id) }
        saveDownloadTasks()

        let count = tasks.count
        let fileMsg = deleteFiles ? "并已删除对应文件" : "已保留本地文件"
        showMessage("已移除 \(count) 条下载记录，\(fileMsg)", success: true)
        removalRequest = nil
    }

    func cancelRemoval() {
        removalRequest = nil
    }

    func openDownloadLocation(_ task: DownloadTask) {
        guard let url = task.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Accounts

    func addAccountFromEditor() async -> BasicMessage {
        let region = accountEditor.region
        let email = accountEditor.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = accountEditor.password
        let code = accountEditor.code.isEmpty ? nil : accountEditor.code

        guard !region.isEmpty, !email.isEmpty, !password.isEmpty else {
            return BasicMessage(success: false, message: "请填写地区、邮箱和密码")
        }

        guard let signer = signer, let sapConfig = sapConfig, let guid = machineGUID else {
            return BasicMessage(success: false, message: "SAP 引擎未就绪，请稍候重试")
        }

        do {
            let info = try await client.login(
                email: email,
                password: password,
                code: code,
                signer: signer,
                authEndpoint: sapConfig.authEndpoint,
                guid: guid
            )
            let account = AppAccount(
                email: email,
                dsid: info.directoryServicesID,
                name: info.name,
                region: region,
                isActive: accounts.isEmpty,
                createdAt: Date(),
                storeFront: info.storeFront,
                passwordToken: info.passwordToken,
                pod: info.pod,
                password: password
            )
            accounts.append(account)
            if account.isActive {
                activeAccount = account
                syncClientAccount()
            }
            saveAccounts()
            return BasicMessage(success: true, message: "账号 \(email) 登录成功")
        } catch AppStoreError.requires2FA {
            accountEditor.awaiting2FA = true
            return BasicMessage(success: false, message: "请输入双重认证验证码")
        } catch {
            return BasicMessage(success: false, message: "登录失败：\(error.localizedDescription)")
        }
    }

    func deleteAccount(_ account: AppAccount) {
        accounts.removeAll { $0.id == account.id }
        if activeAccount?.id == account.id {
            activeAccount = accounts.first
            accounts.indices.forEach { accounts[$0].isActive = (accounts[$0].id == activeAccount?.id) }
        }
        syncClientAccount()
        saveAccounts()
        showMessage("已删除账号 \(account.email)", success: true)
    }

    func setActiveAccount(_ account: AppAccount) {
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == account.id)
        }
        activeAccount = account
        syncClientAccount()
        saveAccounts()
        showMessage("已切换到账号 \(account.email)", success: true)
        // 切换账号后自动刷新已购应用列表
        Task { await loadPurchasedApps() }
    }

    /// 使用存储的密码自动重新登录，刷新 passwordToken
    /// - Returns: true 表示刷新成功；false 表示需要用户重新登录（遇到 2FA 或密码错误）
    @discardableResult
    func refreshToken(for account: AppAccount) async -> Bool {
        guard !account.password.isEmpty else { return false }
        guard let signer = signer, let sapConfig = sapConfig, let guid = machineGUID else { return false }

        do {
            let info = try await client.login(
                email: account.email,
                password: account.password,
                code: nil,
                signer: signer,
                authEndpoint: sapConfig.authEndpoint,
                guid: guid
            )
            // 更新 token
            if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[idx].passwordToken = info.passwordToken
                accounts[idx].needsReauth = false
                if accounts[idx].isActive {
                    activeAccount = accounts[idx]
                    syncClientAccount()
                }
                saveAccounts()
            }
            print("[refreshToken] success for \(account.email)")
            return true
        } catch AppStoreError.requires2FA {
            // 自动重登遇到 2FA，无法自动完成，标记账号需要重新登录
            print("[refreshToken] requires 2FA for \(account.email), marking needsReauth")
            markAccountNeedsReauth(account)
            showMessage("账号 \(account.email) 需要重新验证，请重新登录", success: false)
            return false
        } catch {
            print("[refreshToken] failed for \(account.email): \(error)")
            markAccountNeedsReauth(account)
            return false
        }
    }

    /// 标记账号 token 已失效，清除 token 并设置 needsReauth
    private func markAccountNeedsReauth(_ account: AppAccount) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx].passwordToken = ""
            accounts[idx].needsReauth = true
            if accounts[idx].isActive {
                activeAccount = accounts[idx]
                syncClientAccount()
            }
            saveAccounts()
        }
    }

    func prepareAccountEditor() {
        accountEditor = AccountEditorState(region: availableRegionsForAdd.first?.code ?? "")
    }

    func clearAccountEditor() {
        accountEditor = AccountEditorState()
    }

    // MARK: - Settings

    func saveSettings(_ newSettings: AppSettings) async -> BasicMessage {
        settings = newSettings
        settingsDraft = newSettings
        saveSettings()
        return BasicMessage(success: true, message: "设置已保存")
    }

    func resetSettings() async -> BasicMessage {
        settings = .default
        settingsDraft = .default
        saveSettings()
        return BasicMessage(success: true, message: "设置已重置")
    }

    // MARK: - SAP

    func setupSAP() async {
        guard signer == nil else {
            sapStatus = .ready
            return
        }
        sapStatus = .loading
        do {
            // 1. 获取 App Store bag，提取 SAP 配置
            let config = try await client.fetchBag()

            // 2. 创建签名器并初始化
            let assets = SAPAssets(directory: SAPAssets.defaultCacheDirectory)
            let s = SAPSigner(assets: assets)
            let identity = try currentMachineIdentity()

            try await s.setup(
                hardwareID: identity.hardwareID,
                version: config.version,
                certificateURL: config.certificateURL,
                setupURL: config.setupURL
            )
            signer = s
            sapAssets = assets
            sapConfig = config
            machineGUID = identity.guid
            sapStatus = .ready
            showMessage("SAP 签名引擎已就绪", success: true)
        } catch {
            sapStatus = .failed
            showMessage("SAP 初始化失败：\(error.localizedDescription)", success: false)
        }
    }

    // MARK: - Popup

    func showMessage(_ message: String, success: Bool, duration: TimeInterval = 3.0) {
        let level: PopupLevel = success ? .success : .error
        popup = AppPopup(level: level, title: success ? "操作成功" : "操作失败", message: message)

        popupDismissTask?.cancel()
        popupDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run { dismissPopup() }
        }
    }

    func dismissPopup() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            popup = nil
        }
    }
}

// MARK: - SAP Status

enum SAPStatus {
    case notReady
    case loading
    case ready
    case failed

    var label: String {
        switch self {
        case .notReady: return "未初始化"
        case .loading: return "初始化中"
        case .ready: return "已就绪"
        case .failed: return "初始化失败"
        }
    }

    var tint: Color {
        switch self {
        case .notReady: return .orange
        case .loading: return .blue
        case .ready: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Account Editor State

struct AccountEditorState {
    var region: String = ""
    var email: String = ""
    var password: String = ""
    var code: String = ""
    var awaiting2FA: Bool = false
}
