import AppKit
import Foundation

/// App Store UI 服务 — 所有 App Store 逻辑由打包的 ipatool 二进制接管。
/// 本类仅负责：调用 CLI、解析 JSON、更新 UI 状态、管理下载队列。
@MainActor
final class AppStoreService: ObservableObject {

    @Published var accounts: [Account] = []
    @Published var selectedAccount: Account?
    @Published var isLoggingIn = false
    @Published var isSearching = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var logMessages: [LogEntry] = []
    @Published var downloadResults: [DownloadResult] = []
    @Published var downloadQueue: [DownloadQueueItem] = []
    @Published var downloadDirectory: URL? = nil

    var configuredRegions: [RegionOption] {
        let codes = Set(accounts.map(\.region))
        return RegionOption.all.filter { codes.contains($0.code) }
    }

    var availableRegions: [RegionOption] {
        let codes = Set(accounts.map(\.region))
        return RegionOption.all.filter { !codes.contains($0.code) }
    }

    private let cli = IPAToolCLI.shared
    private var isProcessingQueue = false

    init() {
        Task { await loadAccounts() }
        restoreDownloadDirectoryBookmark()
    }

    // MARK: - 日志

    func log(_ message: String, type: LogEntry.LogType = .info) {
        logMessages.append(LogEntry(message: message, type: type))
        if logMessages.count > 500 { logMessages.removeFirst(logMessages.count - 500) }
    }

    // MARK: - 下载目录管理

    func selectDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "选择下载目录"
        panel.message = "选择 IPA 文件的保存位置"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            downloadDirectory = url
            saveDownloadDirectoryBookmark(url: url)
            log("下载目录已切换: \(url.path)", type: .info)
        }
    }

    private func saveDownloadDirectoryBookmark(url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "downloadDirectoryBookmark")
        } catch {
            log("保存目录书签失败: \(error.localizedDescription)", type: .error)
        }
    }

    private func restoreDownloadDirectoryBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "downloadDirectoryBookmark") else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            downloadDirectory = url
            if isStale { saveDownloadDirectoryBookmark(url: url) }
        } catch {
            UserDefaults.standard.removeObject(forKey: "downloadDirectoryBookmark")
        }
    }

    private func ensureDownloadDirExists() {
        guard let dir = downloadDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - 账号

    func loadAccounts() async {
        do {
            let json = try await cli.listAccounts()
            let activeKey = (json["activeAccount"] as? String)?.lowercased() ?? ""
            let records = (json["accounts"] as? [[String: Any]]) ?? []

            var loaded: [Account] = []
            for rec in records {
                let key = (rec["key"] as? String) ?? ""
                let email = (rec["email"] as? String) ?? ""
                let name = (rec["name"] as? String) ?? ""
                let storeFront = (rec["storeFront"] as? String) ?? ""
                // 从 storefront 推导地区代码（如 "143441-1,13" → "US"）
                let region = Storefront.countryCode(for: storeFront) ?? ""
                // 忽略空 key 的残留记录
                guard !key.isEmpty || !email.isEmpty else { continue }
                let acc = Account(
                    email: email, name: name, region: region,
                    passwordToken: "", directoryServicesID: "",
                    storeFront: storeFront, password: "", pod: ""
                )
                loaded.append(acc)
                if key.lowercased() == activeKey || email.lowercased() == activeKey {
                    selectedAccount = acc
                }
            }
            accounts = loaded
            if selectedAccount == nil { selectedAccount = accounts.first }
            log("已加载 \(accounts.count) 个账号", type: .info)
        } catch {
            log("加载账号失败: \(error.localizedDescription)", type: .error)
        }
    }

    func login(email: String, password: String, authCode: String, region: String) async throws {
        isLoggingIn = true
        defer { isLoggingIn = false }

        log("正在登录 \(email)...")
        let json: [String: Any]
        do {
            json = try await cli.login(email: email, password: password, authCode: authCode.isEmpty ? nil : authCode)
        } catch {
            log("登录失败: \(error.localizedDescription)", type: .error)
            throw error
        }

        // 二进制在需要 2FA 时不报错，只输出提示消息
        let msg = (json["message"] as? String) ?? ""
        if msg.contains("2FA") || msg.contains("auth-code") || msg.contains("verification") {
            log("需要两步验证码", type: .warning)
            throw AppStoreError.authCodeRequired
        }

        let success = json["success"] as? Bool ?? false
        if !success {
            let errMsg = (json["error"] as? String) ?? msg
            throw AppStoreError.loginError(errMsg)
        }

        log("登录成功: \(email)", type: .success)
        await loadAccounts()
    }

    func revoke() async {
        guard let acc = selectedAccount else { return }
        do {
            _ = try await cli.revoke(account: acc.email)
            log("已撤销 \(acc.email) 的凭证", type: .success)
            accounts.removeAll { $0.email == acc.email }
            selectedAccount = accounts.first
        } catch {
            log("撤销失败: \(error.localizedDescription)", type: .error)
        }
    }

    /// 删除指定账号（调用 auth revoke）
    func deleteAccount(_ account: Account) throws {
        Task {
            do {
                _ = try await cli.revoke(account: account.email)
                log("已删除账号 \(account.email)", type: .success)
                accounts.removeAll { $0.email == account.email }
                if selectedAccount?.email == account.email {
                    selectedAccount = accounts.first
                }
            } catch {
                log("删除账号失败: \(error.localizedDescription)", type: .error)
            }
        }
    }

    // MARK: - 搜索

    func search(term: String, limit: Int = 25, platform: String? = nil) async throws -> [AppInfo] {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        isSearching = true
        defer { isSearching = false }

        log("正在搜索 \"\(term)\"...")
        let json = try await cli.search(term: term, limit: limit, platform: platform, account: acc.email)
        let apps = (json["apps"] as? [[String: Any]]) ?? []

        var results: [AppInfo] = []
        for a in apps {
            let id = (a["id"] as? Int64) ?? 0
            let bundleID = (a["bundleID"] as? String) ?? ""
            let name = (a["name"] as? String) ?? ""
            let version = (a["version"] as? String) ?? ""
            let price = (a["price"] as? Double) ?? 0
            let iconURL = a["artworkUrl512"] as? String
            let developer = a["artistName"] as? String
            let description = a["description"] as? String
            let fileSizeBytes = a["fileSizeBytes"] as? String
            let trackViewURL = (a["trackViewUrl"] as? String).flatMap(URL.init(string:))

            results.append(AppInfo(
                id: id, bundleID: bundleID, name: name, version: version, price: price,
                iconURL: iconURL, developer: developer, description: description,
                fileSizeBytes: fileSizeBytes, trackViewURL: trackViewURL
            ))
        }
        log("搜索完成，共 \(results.count) 个结果", type: .success)
        return results
    }

    // MARK: - 版本列表

    func listVersions(appID: Int64) async throws -> [String] {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        let json = try await cli.listVersions(appID: appID, account: acc.email)
        let ids = (json["externalVersionIdentifiers"] as? [String]) ?? []
        return ids
    }

    // MARK: - 购买

    func purchase(app: AppInfo) async throws {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        log("正在获取 \(app.name) 的许可证...")
        _ = try await cli.purchase(appID: app.id, account: acc.email)
        log("\(app.name) 许可证获取成功", type: .success)
    }

    /// 按 App ID 直接购买（无需先搜索）
    func purchaseByAppID(_ appID: Int64) async throws {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        _ = try await cli.purchase(appID: appID, account: acc.email)
    }

    /// iTunes Lookup API（公开接口，无需认证）— 获取应用详情
    func lookup(appID: Int64, region: String) async throws -> AppDetail {
        let countryCode = region.isEmpty ? "us" : region.lowercased()
        let urlStr = "https://itunes.apple.com/lookup?id=\(appID)&country=\(countryCode)"
        guard let url = URL(string: urlStr) else { throw AppStoreError.unknownError("无效 URL") }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let detail = response.results.first else { throw AppStoreError.appNotFound }
        return detail
    }

    // MARK: - 下载

    func download(app: AppInfo, externalVersionID: String? = nil, outputDirectory: URL? = nil, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> DownloadResult {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        let dir = outputDirectory ?? downloadDirectory
        guard let dir else { throw AppStoreError.unknownError("未选择下载目录") }

        let didStart = dir.startAccessingSecurityScopedResource()
        defer { if didStart { dir.stopAccessingSecurityScopedResource() } }
        ensureDownloadDirExists()

        let outputPath = dir.appendingPathComponent("\(app.bundleID)_\(app.id).ipa").path

        log("正在下载 \(app.name)...")
        onProgress?(0.05)

        let json = try await cli.download(
            appID: app.id, output: outputPath,
            externalVersionID: externalVersionID, account: acc.email
        )

        onProgress?(1.0)
        let destPath = (json["output"] as? String).map(URL.init(fileURLWithPath:)) ?? URL(fileURLWithPath: outputPath)
        let result = DownloadResult(app: app, destinationPath: destPath, version: app.version, bundleID: app.bundleID, region: acc.region)
        downloadResults.insert(result, at: 0)
        log("\(app.name) 下载完成: \(destPath.lastPathComponent)", type: .success)
        return result
    }

    // MARK: - 下载队列

    func enqueueDownload(app: AppInfo, externalVersionID: String? = nil) {
        guard let acc = selectedAccount else {
            log("请先选择一个账号", type: .error)
            return
        }
        if downloadDirectory == nil { selectDownloadDirectory() }
        guard downloadDirectory != nil else { return }

        guard !downloadQueue.contains(where: { $0.app.id == app.id && ($0.status == .waiting || $0.status == .purchasing || $0.status == .downloading || $0.status == .processing || $0.status == .completed) }) else {
            log("\"\(app.name)\" 已在下载队列中", type: .warning)
            return
        }
        let item = DownloadQueueItem(app: app, account: acc, externalVersionID: externalVersionID, addedAt: Date())
        downloadQueue.append(item)
        log("\"\(app.name)\" 已加入下载队列", type: .success)
        processQueue()
    }

    func cancelDownload(_ item: DownloadQueueItem) {
        guard let idx = downloadQueue.firstIndex(where: { $0.id == item.id }) else { return }
        let status = downloadQueue[idx].status
        if status == .waiting || status == .failed || status == .purchasing || status == .downloading || status == .processing {
            downloadQueue[idx].status = .cancelled
            log("\"\(item.app.name)\" 已取消", type: .info)
            let itemID = item.id
            Task { @MainActor [weak self] in
                self?.downloadQueue.removeAll(where: { $0.id == itemID })
            }
        }
    }

    func retryDownload(_ item: DownloadQueueItem) {
        guard let idx = downloadQueue.firstIndex(where: { $0.id == item.id }) else { return }
        downloadQueue[idx].status = .waiting
        downloadQueue[idx].error = nil
        downloadQueue[idx].progress = 0
        log("\"\(item.app.name)\" 已重新加入队列", type: .info)
        processQueue()
    }

    func removeDownloadResult(_ result: DownloadResult) {
        if FileManager.default.fileExists(atPath: result.destinationPath.path) {
            try? FileManager.default.removeItem(at: result.destinationPath)
            log("已删除文件: \(result.destinationPath.lastPathComponent)", type: .info)
        }
        downloadResults.removeAll(where: { $0.id == result.id })
    }

    func removeCompletedFromQueue() {
        downloadQueue.removeAll(where: { $0.status == .completed || $0.status == .cancelled })
    }

    func processQueue() {
        guard !isProcessingQueue else { return }
        Task { await processNextItem() }
    }

    private func processNextItem() async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        guard let index = downloadQueue.firstIndex(where: { $0.status == .waiting }) else { return }

        let item = downloadQueue[index]
        guard let dlDir = downloadDirectory else {
            downloadQueue[index].status = .failed
            downloadQueue[index].error = "未选择下载目录"
            log("下载失败: 未选择下载目录，请先在「下载」页面设置", type: .error)
            Task { @MainActor [weak self] in self?.processQueue() }
            return
        }

        let didStart = dlDir.startAccessingSecurityScopedResource()
        defer { if didStart { dlDir.stopAccessingSecurityScopedResource() } }
        ensureDownloadDirExists()

        // 二进制的 download 命令自带 --purchase，会自动获取许可
        downloadQueue[index].status = .downloading
        do {
            let result = try await download(app: item.app, externalVersionID: item.externalVersionID, outputDirectory: downloadDirectory) { [weak self] p in
                Task { @MainActor [weak self] in
                    if let i = self?.downloadQueue.firstIndex(where: { $0.id == item.id }) {
                        self?.downloadQueue[i].progress = p
                    }
                }
            }
            downloadQueue[index].status = .completed
            downloadQueue[index].progress = 1.0
            log("\"\(item.app.name)\" 下载完成: \(result.destinationPath.lastPathComponent)", type: .success)
            downloadQueue.removeAll(where: { $0.id == item.id })
        } catch {
            downloadQueue[index].status = .failed
            downloadQueue[index].error = error.localizedDescription
            log("\"\(item.app.name)\" 下载失败: \(error.localizedDescription)", type: .error)
        }

        Task { @MainActor [weak self] in self?.processQueue() }
    }
}
