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
        } else if let data = defaults.data(forKey: StorageKey.accounts),
                  let decoded = try? JSONDecoder().decode([AppAccount].self, from: data) {
            accounts = decoded
            // 迁移到 Keychain 后清除 UserDefaults 中的明文
            saveAccounts()
            defaults.removeObject(forKey: StorageKey.accounts)
        }
        activateDefaultAccountIfNeeded()

        if let data = defaults.data(forKey: StorageKey.settings),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            // 兼容旧数据：展开 ~ 为真实用户主目录
            var fixed = decoded
            fixed.downloadDirectory = expandTildeInPath(decoded.downloadDirectory)
            // 迁移：旧版本在沙盒下把默认目录展开到了容器内，改回真实主目录
            let containerDefault = ("~/IPATool/downloads" as NSString).expandingTildeInPath
            if fixed.downloadDirectory == containerDefault,
               containerDefault.contains("/Library/Containers/") {
                fixed.downloadDirectory = AppSettings.default.downloadDirectory
            }
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

    /// 默认账号策略：始终以「最早添加且凭据有效」的账号为默认执行账号。
    /// 新添加的账号不会自动成为默认账号，仅在没有任何可用账号时兜底激活。
    /// 用户仍可通过账号列表的「切换」按钮手动指定当前账号。
    private func activateDefaultAccountIfNeeded() {
        // 清理异常状态：isActive 标记落在不存在或需重新登录的账号上
        if let active = accounts.first(where: { $0.isActive }), !active.needsReauth {
            activeAccount = active
            return
        }
        // 无可用激活账号时，回退到最早添加的有效账号
        let fallback = accounts
            .filter { !$0.needsReauth && !$0.passwordToken.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
            .first
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == fallback?.id)
        }
        activeAccount = fallback
    }

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
        showMessage(String(localized: "Welcome to IPATool", table: "Messages"), success: true)
        // 自动初始化 SAP 签名引擎
        await setupSAP()
    }

    // MARK: - Search

    func performSearch() async {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            showMessage(String(localized: "Please enter a search keyword", table: "Messages"), success: false)
            return
        }

        isSearching = true
        searchResults = []
        hasSearched = true

        do {
            let results = try await client.search(term: term, platform: searchPlatform)
            searchResults = results
            if results.isEmpty {
                showMessage(String(localized: "No matching apps found", table: "Messages"), success: false)
            }
        } catch {
            showMessage(String(localized: "Search failed: \(error.localizedDescription)", table: "Messages"), success: false)
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

    /// 执行需要鉴权的操作，失败时自动尝试刷新 token 并重试一次。
    /// 仅对未登录（token 过期）错误触发刷新；下载/购买等业务错误不重试。
    /// - Parameter operation: 需要执行的异步操作
    /// - Returns: 操作结果
    private func withTokenRefresh<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard case AppStoreError.notAuthenticated = error else {
                throw error
            }
            // token 过期，尝试用存储的密码自动刷新 token
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
            showMessage(String(localized: "The SAP engine is not ready. Please try again later.", table: "Messages"), success: false)
            return
        }
        guard activeAccount != nil else {
            showMessage(String(localized: "Please sign in with an Apple ID first", table: "Messages"), success: false)
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
                showMessage(String(localized: "No purchased apps found", table: "Messages"), success: false)
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
            showMessage(String(localized: "Failed to load purchased apps: \(error.localizedDescription)", table: "Messages"), success: false)
        }

        isLoadingPurchased = false
    }

    /// 下载已购应用（通过 trackId）
    func downloadOwnedApp(_ owned: OwnedApp) async {
        guard accounts.contains(where: { $0.isActive }) else {
            showMessage(String(localized: "Please sign in with an Apple ID first", table: "Messages"), success: false)
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
            artworkUrl: owned.artworkUrl,
            platforms: owned.platforms
        )
        await downloadApp(app)
    }

    // MARK: - Downloads

    func downloadApp(_ app: AppStoreApp, externalVersionID: String? = nil) async {
        guard accounts.contains(where: { $0.isActive }) else {
            showMessage(String(localized: "Please sign in with an Apple ID first", table: "Messages"), success: false)
            selectedSection = .accounts
            return
        }

        let versionLabel = externalVersionID.map { "v\($0)" } ?? String(localized: "Latest", table: "Messages")

        // 避免重复下载
        if downloadTasks.contains(where: { $0.app.trackId == app.trackId && $0.status != .failed }) {
            showMessage(String(localized: "This app is already in the download queue", table: "Messages"), success: false)
            return
        }

        var task = DownloadTask(app: app, status: .downloading)
        task.startedAt = Date()
        downloadTasks.insert(task, at: 0)
        showMessage(String(localized: "Added to download queue: \(app.trackName) (\(versionLabel))", table: "Messages"), success: true)

        print("[download] starting: \(app.trackName) (\(versionLabel)), appID=\(app.trackId)")

        do {
            // 1. 先自动执行购买，确保当前账号已获得该应用授权
            // 已购买的应用会返回 license already exists，IPAToolKit 内部视为成功，可安全重复调用
            // 历史版本下载同样需要授权，统一在此处处理
            print("[download] purchasing first: appID=\(app.trackId)")
            try await withTokenRefresh {
                try await client.purchase(appID: app.trackId)
            }

            // 2. 请求下载产品信息（token 失效时自动刷新重试）
            print("[download] requesting downloadProduct...")
            let dict = try await withTokenRefresh {
                try await client.downloadProduct(appID: app.trackId, externalVersionID: externalVersionID)
            }
            print("[download] downloadProduct response keys: \(dict.keys.sorted())")

            // 3. 提取下载 URL
            guard let url = client.extractDownloadURL(from: dict) else {
                throw AppStoreError.downloadFailed(message: String(localized: "No download URL in the response", table: "Messages"))
            }
            print("[download] download URL: \(url.absoluteString)")

            // 4. 确定输出路径（展开 ~ 为真实用户主目录；沙盒下优先用安全作用域书签恢复授权）
            let expandedDir = expandTildeInPath(settings.downloadDirectory)
            var dir = URL(fileURLWithPath: expandedDir, isDirectory: true)
            var scopedURL: URL?
            if let bookmark = settings.downloadBookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark,
                                      options: .withSecurityScope,
                                      bookmarkDataIsStale: &stale) {
                    dir = url
                    if url.startAccessingSecurityScopedResource() {
                        scopedURL = url
                    }
                }
            }
            defer { scopedURL?.stopAccessingSecurityScopedResource() }

            // 下载前探测目录可写性（沙盒对容器外路径需用户授权），
            // 避免大文件下载完成后才因无权限失败
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let probe = dir.appendingPathComponent(".ipatool-write-test")
                try Data().write(to: probe)
                try FileManager.default.removeItem(at: probe)
            } catch {
                throw AppStoreError.downloadFailed(message: String(localized: "The download folder is not writable: \(dir.path). Please choose and authorize it again via \"Choose Folder\" in Settings.", table: "Messages"))
            }

            // 文件名：应用名_版本号(版本序号兜底)_下载账号.ipa
            let safeName = app.trackName.replacingOccurrences(of: "/", with: "-")
            let versionPart: String = {
                if !app.version.isEmpty {
                    return app.version
                }
                if let vid = externalVersionID {
                    return "v\(vid)"
                }
                return String(localized: "Latest", table: "Messages")
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

            // 5. 下载文件（macOS 包需要解密）
            let dpInfo = client.extractDPInfo(from: dict)
            if let dpInfo = dpInfo {
                // macOS 加密包：下载后解密
                guard let assets = sapAssets else {
                    throw AppStoreError.downloadFailed(message: String(localized: "The SAP engine is not ready; cannot decrypt the macOS package", table: "Messages"))
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

                // 注入 FairPlay sinf 和 iTunesMetadata.plist（对齐 ipadecrypt 的 applyPatches）
                // Apple CDN 返回的 IPA 不含 sinf，侧载安装后 SpringBoard 会因缺少 FairPlay 解密密钥拒绝启动
                if let patchInfo = client.extractSinfPatchInfo(from: dict) {
                    print("[download] injecting FairPlay sinf...")
                    try await SinfInjector.inject(into: destination, patchInfo: patchInfo)
                } else {
                    print("[download] no sinf found in response, skipping injection")
                }
            }

            // 6. 完成
            if let idx = downloadTasks.firstIndex(where: { $0.id == task.id }) {
                downloadTasks[idx].status = .completed
                downloadTasks[idx].progress = 1.0
                downloadTasks[idx].outputURL = destination
                downloadTasks[idx].completedAt = Date()
            }
            showMessage(String(localized: "Download completed: \(app.trackName) (\(versionLabel))", table: "Messages"), success: true)
            print("[download] complete: \(destination.path)")

        } catch {
            print("[download] ERROR: \(error)")
            if let idx = downloadTasks.firstIndex(where: { $0.id == task.id }) {
                downloadTasks[idx].status = .failed
                downloadTasks[idx].errorMessage = error.localizedDescription
            }
            showMessage(String(localized: "Download failed: \(error.localizedDescription)", table: "Messages"), success: false)
        }
        saveDownloadTasks()
    }

    /// 购买（获取）应用，使当前账号获得该应用的下载授权
    func purchaseApp(_ app: AppStoreApp) async {
        guard activeAccount != nil else {
            showMessage(String(localized: "Please sign in with an Apple ID first", table: "Messages"), success: false)
            selectedSection = .accounts
            return
        }
        do {
            try await withTokenRefresh {
                try await client.purchase(appID: app.trackId)
            }
            showMessage(String(localized: "Acquired \(app.trackName). You can start downloading now.", table: "Messages"), success: true)
        } catch {
            showMessage(String(localized: "Purchase failed: \(error.localizedDescription)", table: "Messages"), success: false)
        }
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
            // 历史版本接口要求账号已持有该应用许可证，先自动购买获取授权
            // 已购买的应用会返回 license already exists，视为成功；购买失败不阻断，继续尝试拉取版本列表
            if activeAccount != nil {
                do {
                    try await withTokenRefresh {
                        try await client.purchase(appID: app.trackId)
                    }
                } catch {
                    print("[versions] purchase failed (continuing): \(error.localizedDescription)")
                }
            }
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
        if deleteFiles {
            showMessage(String(localized: "Removed \(count) download records and deleted the corresponding files", table: "Messages"), success: true)
        } else {
            showMessage(String(localized: "Removed \(count) download records; local files were kept", table: "Messages"), success: true)
        }
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
            return BasicMessage(success: false, message: String(localized: "Please fill in region, email, and password", table: "Messages"))
        }

        guard let signer = signer, let sapConfig = sapConfig, let guid = machineGUID else {
            return BasicMessage(success: false, message: String(localized: "The SAP engine is not ready. Please try again later.", table: "Messages"))
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
                // 新账号默认不激活：仅在当前没有任何可用账号时才成为默认账号，
                // 避免新添加的账号静默顶替用户正在使用的账号
                isActive: false,
                createdAt: Date(),
                storeFront: info.storeFront,
                passwordToken: info.passwordToken,
                pod: info.pod,
                password: password
            )
            accounts.append(account)
            activateDefaultAccountIfNeeded()
            syncClientAccount()
            saveAccounts()
            return BasicMessage(success: true, message: String(localized: "Signed in as \(email)", table: "Messages"))
        } catch AppStoreError.requires2FA {
            accountEditor.awaiting2FA = true
            return BasicMessage(success: false, message: String(localized: "Please enter the two-factor authentication code", table: "Messages"))
        } catch {
            return BasicMessage(success: false, message: String(localized: "Sign-in failed: \(error.localizedDescription)", table: "Messages"))
        }
    }

    func deleteAccount(_ account: AppAccount) {
        accounts.removeAll { $0.id == account.id }
        activateDefaultAccountIfNeeded()
        syncClientAccount()
        saveAccounts()
        showMessage(String(localized: "Deleted account \(account.email)", table: "Messages"), success: true)
    }

    func setActiveAccount(_ account: AppAccount) {
        for i in accounts.indices {
            accounts[i].isActive = (accounts[i].id == account.id)
        }
        activeAccount = account
        syncClientAccount()
        saveAccounts()
        showMessage(String(localized: "Switched to account \(account.email)", table: "Messages"), success: true)
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
            showMessage(String(localized: "Account \(account.email) requires re-authentication. Please sign in again.", table: "Messages"), success: false)
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

    /// 沙盒（App Store/Release）版本首次启动时引导用户授权下载目录。
    /// 沙盒对容器外路径无默认写权限，必须通过「选择目录」获得安全作用域授权；
    /// LocalRelease 无沙盒，默认目录直接可写，无需提示。
    func promptForDownloadDirectoryAuthorizationIfNeeded() {
        let promptedKey = "hasPromptedDownloadDirectoryAuth"
        guard !UserDefaults.standard.bool(forKey: promptedKey) else { return }
        // 运行期判断是否沙盒：沙盒应用的主目录被重定向到容器
        guard NSHomeDirectory().contains("/Library/Containers/"),
              settings.downloadBookmark == nil else { return }
        UserDefaults.standard.set(true, forKey: promptedKey)

        let alert = NSAlert()
        alert.messageText = String(localized: "Choose a Download Folder", table: "Messages")
        alert.informativeText = String(localized: "This version is restricted by the system sandbox. You need to choose and authorize a folder so downloaded IPA files can be saved properly.", table: "Messages")
        alert.addButton(withTitle: String(localized: "Choose Folder", table: "Messages"))
        alert.addButton(withTitle: String(localized: "Later", table: "Messages"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose", table: "Messages")
        panel.message = String(localized: "Choose a folder to save downloaded IPA files", table: "Messages")
        panel.directoryURL = URL(fileURLWithPath: expandTildeInPath(settings.downloadDirectory), isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var updated = settings
        updated.downloadDirectory = url.path
        updated.downloadBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        settings = updated
        settingsDraft = updated
        saveSettings()
    }

    func saveSettings(_ newSettings: AppSettings) async -> BasicMessage {
        settings = newSettings
        settingsDraft = newSettings
        saveSettings()
        return BasicMessage(success: true, message: String(localized: "Settings saved", table: "Messages"))
    }

    func resetSettings() async -> BasicMessage {
        settings = .default
        settingsDraft = .default
        saveSettings()
        return BasicMessage(success: true, message: String(localized: "Settings reset", table: "Messages"))
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
            showMessage(String(localized: "SAP signing engine is ready", table: "Messages"), success: true)
        } catch {
            // 失败时清理，确保可以重试
            signer = nil
            sapStatus = .failed
            print("[SAP] setup failed: \(error)")
            showMessage(String(localized: "SAP initialization failed: \(error.localizedDescription)", table: "Messages"), success: false)
        }
    }

    /// 重置 SAP 状态到未初始化，允许重新初始化
    func resetSAP() {
        signer?.close()
        signer = nil
        sapAssets = nil
        sapConfig = nil
        machineGUID = nil
        sapStatus = .notReady
    }

    // MARK: - Popup

    func showMessage(_ message: String, success: Bool, duration: TimeInterval = 3.0) {
        let level: PopupLevel = success ? .success : .error
        popup = AppPopup(level: level, title: success ? String(localized: "Success", table: "Messages") : String(localized: "Failed", table: "Messages"), message: message)

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
        case .notReady: return String(localized: "Not initialized", table: "Messages")
        case .loading: return String(localized: "Initializing", table: "Messages")
        case .ready: return String(localized: "Ready", table: "Messages")
        case .failed: return String(localized: "Initialization failed", table: "Messages")
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

// MARK: - Sinf 注入器

/// 使用系统 zip 命令向 IPA 注入 FairPlay sinf 和 iTunesMetadata.plist。
///
/// 对齐 ipadecrypt 的 `applyPatches`（internal/appstore/download.go）：
/// 1. 解压 IPA 到临时目录
/// 2. 读取 SC_Info/Manifest.plist 获取 sinf 目标路径
/// 3. 若无 Manifest 则回退到 SC_Info/<可执行文件名>.sinf
/// 4. 写入 sinf 文件和 iTunesMetadata.plist
/// 5. 重新打包为 IPA
enum SinfInjector {
    static func inject(into ipaPath: URL, patchInfo: AppStoreClient.SinfPatchInfo) async throws {
        let fm = FileManager.default
        let workDir = ipaPath.deletingLastPathComponent()
            .appendingPathComponent("_sinf_inject_\(UUID().uuidString.prefix(8))")

        defer { try? fm.removeItem(at: workDir) }

        // 1. 解压 IPA
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try await runProcess(launchPath: "/usr/bin/unzip", arguments: ["-o", ipaPath.path, "-d", workDir.path])

        // 2. 找到 .app 目录
        let payloadDir = workDir.appendingPathComponent("Payload")
        guard let appDirs = try? fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil),
              let appDir = appDirs.first(where: { $0.pathExtension == "app" }) else {
            throw AppStoreError.downloadFailed(message: String(localized: "No .app directory found in the IPA", table: "Messages"))
        }

        // 3. 读取 Manifest.plist 和 Info.plist
        let manifestPath = appDir.appendingPathComponent("SC_Info/Manifest.plist")
        let infoPath = appDir.appendingPathComponent("Info.plist")

        var sinfPaths: [String]? = nil
        var bundleExecutable: String? = nil

        if let data = try? Data(contentsOf: manifestPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            sinfPaths = plist["SinfPaths"] as? [String]
        }

        if let data = try? Data(contentsOf: infoPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            bundleExecutable = plist["CFBundleExecutable"] as? String
        }

        // 4. 写入 sinf 文件
        let sinfs = patchInfo.sinfs
        if let paths = sinfPaths, paths.count == sinfs.count {
            // 有 Manifest.plist，按指定路径写入
            for (i, path) in paths.enumerated() {
                let dest = appDir.appendingPathComponent(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try sinfs[i].data.write(to: dest)
            }
        } else {
            // 回退到 SC_Info/<executable>.sinf
            let execName = bundleExecutable ?? appDir.lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let scInfoDir = appDir.appendingPathComponent("SC_Info")
            try fm.createDirectory(at: scInfoDir, withIntermediateDirectories: true)
            try sinfs[0].data.write(to: scInfoDir.appendingPathComponent("\(execName).sinf"))
        }

        // 5. 写入 iTunesMetadata.plist
        var meta = patchInfo.metadata ?? [:]
        meta["apple-id"] = patchInfo.account.email
        meta["userName"] = patchInfo.account.email
        let metaPlistData = try PropertyListSerialization.data(fromPropertyList: meta, format: .binary, options: 0)
        try metaPlistData.write(to: workDir.appendingPathComponent("iTunesMetadata.plist"))

        // 6. 重新打包 IPA
        let tmpIPA = ipaPath.appendingPathExtension("sinf-tmp")
        defer { try? fm.removeItem(at: tmpIPA) }
        try await runProcess(launchPath: "/usr/bin/zip", arguments: ["-r", "-X", tmpIPA.path, "Payload", "iTunesMetadata.plist"], currentDirectory: workDir)

        try fm.removeItem(at: ipaPath)
        try fm.moveItem(at: tmpIPA, to: ipaPath)
    }

    private static func runProcess(launchPath: String, arguments: [String], currentDirectory: URL? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd = currentDirectory {
            process.currentDirectoryURL = cwd
        }
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = try stderr.fileHandleForReading.readToEnd() ?? Data()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
            throw AppStoreError.downloadFailed(message: "\(launchPath) exit \(process.terminationStatus): \(errMsg)")
        }
    }
}
