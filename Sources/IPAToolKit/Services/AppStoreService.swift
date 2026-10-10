import Foundation

/// App Store API 核心服务 — 支持多账号
///
/// 登录流程委托给 ipatool-go 二进制（SAP 签名），
/// 搜索/购买/下载等操作在 Swift 端直接实现。
@MainActor
public final class AppStoreService: ObservableObject {

    @Published public var accounts: [Account] = []
    @Published public var selectedAccount: Account?
    @Published public var isLoggingIn = false
    @Published public var isSearching = false
    @Published public var isDownloading = false
    @Published public var downloadProgress: Double = 0
    @Published public var logMessages: [LogEntry] = []
    @Published public var downloadResults: [DownloadResult] = []
    @Published public var downloadQueue: [DownloadQueueItem] = []
    @Published public var downloadDirectory: URL? = nil
    @Published public var purchases: [PurchasedApp] = []

    /// 由 GUI target 设置；当下载目录未设置时触发目录选择 UI（CLI/MCP 不设置此回调）
    public var onDirectorySelectionNeeded: (() -> Void)?

    /// CLI/MCP 模式下将日志输出到 stderr，保持 stdout 干净用于结构化输出
    public var logToStderr: Bool = false

    public var configuredRegions: [RegionOption] {
        let codes = Set(accounts.map(\.region))
        return RegionOption.all.filter { codes.contains($0.code) }
    }

    public var availableRegions: [RegionOption] {
        let codes = Set(accounts.map(\.region))
        return RegionOption.all.filter { !codes.contains($0.code) }
    }

    private let keychain = KeychainService.shared
    private var isProcessingQueue = false

    /// 普通网络请求 session（允许重定向）
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    // MARK: - 常量

    private let iTunesAPIDomain = "itunes.apple.com"
    private let privateAppStoreDomain = "buy.itunes.apple.com"
    private let iTunesPathSearch = "/search"
    private let iTunesPathLookup = "/lookup"
    private let privatePurchasePath = "/WebObjects/MZFinance.woa/wa/buyProduct"
    private let privateDownloadPath = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"

    private let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    /// 从非标准 XML 中提取 <plist>...</plist> 片段
    /// Bag 响应格式: <Document><Protocol><plist>...</plist></Protocol></Document>
    private func extractPlistData(from data: Data) -> Data {
        guard let xml = String(data: data, encoding: .utf8),
              let startRange = xml.range(of: "<plist"),
              let endRange = xml.range(of: "</plist>") else {
            return data
        }
        return Data(xml[startRange.lowerBound ..< endRange.upperBound].utf8)
    }

    /// 解析 plist 数据，支持非标准 XML
    private func parsePlist<T>(from data: Data) throws -> T? {
        if let result = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? T {
            return result
        }
        let extracted = extractPlistData(from: data)
        return try PropertyListSerialization.propertyList(from: extracted, options: [], format: nil) as? T
    }

    /// 发送 plist 请求并解析响应（带 429/5xx 检测）
    private func sendPlistRequest(_ request: URLRequest, payload: [String: Any]) async throws -> [String: Any] {
        var req = request
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let (data, resp) = try await session.data(for: req)
        guard let httpResp = resp as? HTTPURLResponse else {
            throw AppStoreError.httpError(0)
        }

        // 429 限流
        if httpResp.statusCode == 429 {
            let retryAfter = httpResp.value(forHTTPHeaderField: "Retry-After")
            log("请求被限流 (429)\(retryAfter != nil ? "，Retry-After: \(retryAfter!)" : "")", type: .warning)
            throw AppStoreError.rateLimited
        }

        // 5xx 服务器错误
        if httpResp.statusCode >= 500 {
            throw AppStoreError.httpError(httpResp.statusCode)
        }

        guard let dict = try parsePlist(from: data) as [String: Any]? else {
            throw AppStoreError.parseError("无法解析响应 (HTTP \(httpResp.statusCode))")
        }
        return dict
    }

    /// 发送 plist 请求，返回原始 Data 和 HTTPURLResponse
    private func sendPlistData(_ request: URLRequest, payload: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let (data, resp) = try await session.data(for: req)
        guard let httpResp = resp as? HTTPURLResponse else {
            throw AppStoreError.httpError(0)
        }
        return (extractPlistData(from: data), httpResp)
    }

    // MARK: - Retry Middleware

    /// 指数退避重试（用于 purchase/download 等非认证请求）
    /// - 检测 429 限流和 5xx 服务器错误
    /// - 退避序列：10s → 20s → 30s（与 Go 版一致）
    /// - 尊重 Retry-After 头
    private func withRetry<T>(
        maxAttempts: Int = 3,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch let error as AppStoreError {
                lastError = error

                if case .rateLimited = error {
                    if attempt < maxAttempts {
                        let delay = min(UInt64(10_000_000_000 << (attempt - 1)), 30_000_000_000)
                        log("等待 \(delay / 1_000_000_000) 秒后重试 (\(attempt)/\(maxAttempts))...", type: .warning)
                        try await Task.sleep(nanoseconds: delay)
                        continue
                    }
                }

                if case .httpError(let code) = error, code >= 500 {
                    if attempt < maxAttempts {
                        let delay = min(UInt64(10_000_000_000 << (attempt - 1)), 30_000_000_000)
                        log("服务器错误 (\(code))，等待 \(delay / 1_000_000_000) 秒后重试 (\(attempt)/\(maxAttempts))...", type: .warning)
                        try await Task.sleep(nanoseconds: delay)
                        continue
                    }
                }

                throw error
            }
        }
        throw lastError ?? AppStoreError.unknownError("重试耗尽")
    }

    public init() {
        Task { await loadAccounts() }
        restoreDownloadDirectoryBookmark()
    }

    // MARK: - 下载目录管理

    /// 设置下载目录并保存书签（GUI 调用此方法后更新 UI）
    public func setDownloadDirectory(_ url: URL) {
        downloadDirectory = url
        saveDownloadDirectoryBookmark(url: url)
        log("下载目录已切换: \(url.path)", type: .info)
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
            if isStale {
                saveDownloadDirectoryBookmark(url: url)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: "downloadDirectoryBookmark")
        }
    }

    // MARK: - 账号管理

    public func loadAccounts() async {
        // 先从 Swift Keychain 加载
        var loadedAccounts: [Account] = []
        do {
            loadedAccounts = try keychain.loadAllAccounts()
        } catch {
            log("加载 Swift Keychain 账号失败: \(error.localizedDescription)", type: .error)
        }

        // 从 Go Keychain 同步（ipatool-go 登录的账号）
        let goAccounts = IPAToolGoBridge.shared.loadAllAccounts()
        let existingKeys = Set(loadedAccounts.map(\.id))
        for goAcc in goAccounts {
            if !existingKeys.contains(goAcc.id) {
                try? keychain.saveAccount(goAcc)
                loadedAccounts.append(goAcc)
            }
        }

        accounts = loadedAccounts
        if selectedAccount == nil {
            selectedAccount = accounts.first
        }
        log("已加载 \(accounts.count) 个账号")
    }

    public func login(email: String, password: String, authCode: String, region: String) async throws {
        isLoggingIn = true
        defer { isLoggingIn = false }

        log("正在通过 ipatool-go 登录 \(email) (\(RegionOption.displayName(for: region)))...")

        do {
            let result = try await IPAToolGoBridge.shared.authLogin(
                email: email,
                password: password,
                authCode: authCode.isEmpty ? nil : authCode
            )

            switch result {
            case .success(let account):
                let finalAccount = Account(
                    email: account.email, name: account.name, region: region,
                    passwordToken: account.passwordToken, directoryServicesID: account.directoryServicesID,
                    storeFront: account.storeFront, password: account.password, pod: account.pod
                )
                log("登录成功: \(finalAccount.email) (\(finalAccount.name)) | 地区: \(finalAccount.regionDisplayName)")
                try keychain.saveAccount(finalAccount)
                await loadAccounts()
                selectedAccount = finalAccount
            case .authCodeRequired:
                log("需要两步验证码", type: .warning)
                throw AppStoreError.authCodeRequired
            }
        } catch let error as GoBridgeError {
            if case .authCodeRequired = error {
                throw AppStoreError.authCodeRequired
            }
            log("ipatool-go 登录失败: \(error.description)", type: .error)
            throw AppStoreError.loginError(error.description)
        }
    }

    public func deleteAccount(_ account: Account) throws {
        try keychain.deleteAccount(id: account.id)
        if selectedAccount?.id == account.id {
            selectedAccount = accounts.first(where: { $0.id != account.id })
        }
        Task { await loadAccounts() }
    }

    /// 退出登录：删除 Swift Keychain 凭据 + 撤销 Go Keychain 凭据
    public func logout(account: Account) async throws {
        try keychain.deleteAccount(id: account.id)
        try? await IPAToolGoBridge.shared.revoke(accountKey: account.email)
        await loadAccounts()
        log("已退出登录: \(account.email)")
    }

    // MARK: - Re-Login

    /// 凭证过期时自动重新登录（通过 ipatool-go 二进制用保存的密码刷新 token）
    private func relogin(account: Account) async throws -> Account {
        log("凭证已过期，正在通过 ipatool-go 自动重新登录...")

        do {
            let result = try await IPAToolGoBridge.shared.authLogin(
                email: account.email,
                password: account.password,
                authCode: nil
            )

            switch result {
            case .success(let newAccount):
                let finalAccount = Account(
                    email: newAccount.email, name: newAccount.name, region: account.region,
                    passwordToken: newAccount.passwordToken, directoryServicesID: newAccount.directoryServicesID,
                    storeFront: newAccount.storeFront, password: newAccount.password, pod: newAccount.pod
                )
                log("重新登录成功，token 已刷新")
                try keychain.saveAccount(finalAccount)
                await loadAccounts()
                selectedAccount = finalAccount
                return finalAccount
            case .authCodeRequired:
                throw AppStoreError.passwordTokenExpired
            }
        } catch let error as GoBridgeError {
            log("ipatool-go 重新登录失败: \(error.description)", type: .error)
            throw AppStoreError.passwordTokenExpired
        }
    }

    // MARK: - Log

    public func log(_ message: String, type: LogEntry.LogType = .info) {
        logMessages.append(LogEntry(message: message, type: type))
        let line = "[IPATool] \(message)\n"
        if logToStderr {
            FileHandle.standardError.write(Data(line.utf8))
        } else {
            print(line, terminator: "")
        }
    }

    // MARK: - GUID

    /// 获取持久化的设备 GUID（MAC 地址，12 个大写 hex 字符）
    private func getGUID() -> String {
        if let cached = UserDefaults.standard.string(forKey: "ipatool_device_guid"), !cached.isEmpty {
            return cached
        }
        let guid: String
        if let mac = getMACAddress() {
            guid = mac
        } else {
            guid = String((0..<12).compactMap { _ in "0123456789ABCDEF".randomElement() })
        }
        UserDefaults.standard.set(guid, forKey: "ipatool_device_guid")
        log("设备 GUID: \(guid)")
        return guid
    }

    /// 使用 sysctl 获取 en0 的 MAC 地址（与 ApplePackage 的 DeviceIdentifier.system() 一致）
    private func getMACAddress() -> String? {
        let bsds = ["en0", "en1"]
        for bsd in bsds {
            let index = Int32(if_nametoindex(bsd))
            guard index != 0 else { continue }

            var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, AF_LINK, NET_RT_IFLIST, index]
            var len: size_t = 0
            guard sysctl(&mib, 6, nil, &len, nil, 0) >= 0, len > 0 else { continue }

            var buffer = [UInt8](repeating: 0, count: len)
            guard sysctl(&mib, 6, &buffer, &len, nil, 0) >= 0 else { continue }

            let infoData = Data(buffer)
            let bsdData = Data(bsd.utf8)
            guard let bsdRange = infoData.range(of: bsdData) else { continue }

            let lower = bsdRange.upperBound
            let upper = lower + 6
            guard upper <= infoData.count else { continue }

            let mac = infoData[lower..<upper].map { String(format: "%02X", $0) }.joined()
            if !mac.isEmpty { return mac }
        }
        return nil
    }

    // MARK: - Search (S8: 平台支持 + 平台字段)

    /// 搜索 App Store 应用
    /// - Parameters:
    ///   - term: 搜索关键词
    ///   - limit: 结果上限
    ///   - platform: 平台过滤（S9）
    public func search(term: String, limit: Int = 25, platform: Platform? = nil) async throws -> [AppInfo] {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        isSearching = true
        defer { isSearching = false }

        let country = acc.countryCode ?? "CN"
        let entity = platform?.searchEntity ?? "software,iPadSoftware"
        let termEncoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let urlString = "https://\(iTunesAPIDomain)\(iTunesPathSearch)?entity=\(entity)&limit=\(limit)&media=software&term=\(termEncoded)&country=\(country)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        log("搜索: \"\(term)\" (地区: \(acc.regionDisplayName)\(platform.map { "，平台: \($0.displayName)" } ?? ""))...")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)

        // S9: watchOS 平台过滤（watch 应用与 iOS 共享目录，需按 supportedDevices 过滤）
        var results = searchResponse.results
        if platform == .watchos {
            results = results.filter { $0.platforms.contains(.watchos) }
        }

        log("找到 \(results.count) 个结果")
        return results
    }

    /// 通过 iTunes Lookup API 获取应用详细信息
    public func lookup(appID: Int64, region: String) async throws -> AppDetail {
        let urlString = "https://itunes.apple.com/\(region)/lookup?id=\(appID)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let lookupResponse = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let detail = lookupResponse.results.first else {
            throw AppStoreError.unknownError("未找到应用详情")
        }
        return detail
    }

    /// 通过 Bundle ID 查找应用（CLI download/purchase 命令使用）
    public func lookupApp(bundleID: String, region: String) async throws -> AppInfo? {
        let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
        let urlString = "https://\(iTunesAPIDomain)/\(region)/lookup?bundleId=\(encoded)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
        return searchResponse.results.first
    }

    /// 通过 App ID 查找应用（CLI download/purchase 命令使用）
    public func lookupApp(appID: Int64, region: String) async throws -> AppInfo? {
        let urlString = "https://\(iTunesAPIDomain)/\(region)/lookup?id=\(appID)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
        return searchResponse.results.first
    }

    // MARK: - Purchase

    public func purchase(app: AppInfo) async throws {
        guard var acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        guard app.isFree else { throw AppStoreError.paidAppNotSupported }

        var maxRetries = 2

        while true {
            do {
                try await purchaseCore(app: app, account: acc)
                return
            } catch let error as AppStoreError {
                if case .passwordTokenExpired = error, maxRetries > 0 {
                    maxRetries -= 1
                    acc = try await relogin(account: acc)
                    continue
                }
                throw error
            }
        }
    }

    private func purchaseCore(app: AppInfo, account acc: Account) async throws {
        let guid = getGUID()
        log("正在获取 \(app.name) 的许可证...")

        do {
            try await purchaseWithParams(account: acc, app: app, guid: guid, pricing: "STDQ")
            log("许可证获取成功 (STDQ)")
        } catch let error as AppStoreError {
            if case .licenseAlreadyExists = error {
                log("许可证已存在，可直接下载")
                return
            }
            if case .temporarilyUnavailable = error {
                log("STDQ 不可用，尝试 GAME...")
                try await purchaseWithParams(account: acc, app: app, guid: guid, pricing: "GAME")
                log("许可证获取成功 (GAME)")
                return
            }
            throw error
        }
    }

    private func purchaseWithParams(account: Account, app: AppInfo, guid: String, pricing: String) async throws {
        let host = account.pod.isEmpty ? "buy.itunes.apple.com" : "p\(account.pod)-buy.itunes.apple.com"
        let urlString = "https://\(host)\(privatePurchasePath)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }

        let payload: [String: Any] = [
            "appExtVrsId": "0", "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true", "hasDoneAgeCheck": "true",
            "guid": guid, "needDiv": "0", "origPage": "Software-\(app.id)",
            "origPageLocation": "Buy", "price": "0", "pricingParameters": pricing,
            "productType": "C", "salableAdamId": app.id,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")
        request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")

        let dict = try await withRetry {
            try await sendPlistRequest(request, payload: payload)
        }

        if let action = dict["action"] as? [String: Any],
           let urlString = (action["url"] as? String) ?? (action["URL"] as? String),
           urlString.hasSuffix("termsPage") {
            throw AppStoreError.unknownError("需要接受条款: \(urlString)")
        }

        let failureType = dict["failureType"] as? String ?? ""
        let customerMessage = dict["customerMessage"] as? String ?? ""

        if failureType == "2059" { throw AppStoreError.temporarilyUnavailable }
        if failureType == "2034" || failureType == "2042" || failureType == "1008"
            || customerMessage == "Your password has changed." {
            throw AppStoreError.passwordTokenExpired
        }
        if customerMessage == "Subscription Required" { throw AppStoreError.subscriptionRequired }
        if failureType == "5002" { throw AppStoreError.licenseAlreadyExists }
        if !failureType.isEmpty && !customerMessage.isEmpty { throw AppStoreError.unknownError(customerMessage) }
        if !failureType.isEmpty { throw AppStoreError.unknownError(failureType) }

        let jingleDocType = dict["jingleDocType"] as? String ?? ""
        let status = dict["status"] as? Int ?? -1
        if jingleDocType != "purchaseSuccess" || status != 0 {
            throw AppStoreError.unknownError("购买失败: \(jingleDocType) status=\(status)")
        }
    }

    // MARK: - Download (S5: 断点续传 + S9: 多平台)

    public func download(app: AppInfo, outputDirectory: URL? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> DownloadResult {
        guard var acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        var maxRetries = 2

        while true {
            do {
                return try await downloadCore(app: app, account: acc, outputDirectory: outputDirectory, onProgress: onProgress)
            } catch let error as AppStoreError {
                if case .passwordTokenExpired = error, maxRetries > 0 {
                    maxRetries -= 1
                    acc = try await relogin(account: acc)
                    continue
                }
                throw error
            }
        }
    }

    /// 带版本 ID 和平台参数的下载（S6/S9）
    public func download(app: AppInfo, externalVersionID: String? = nil, platform: Platform? = nil,
                         outputDirectory: URL? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> DownloadResult {
        guard var acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        var maxRetries = 2

        while true {
            do {
                return try await downloadCore(app: app, account: acc, externalVersionID: externalVersionID,
                                              platform: platform, outputDirectory: outputDirectory, onProgress: onProgress)
            } catch let error as AppStoreError {
                if case .passwordTokenExpired = error, maxRetries > 0 {
                    maxRetries -= 1
                    acc = try await relogin(account: acc)
                    continue
                }
                throw error
            }
        }
    }

    private func downloadCore(app: AppInfo, account acc: Account, externalVersionID: String? = nil,
                              platform: Platform? = nil, outputDirectory: URL?,
                              onProgress: ((Double) -> Void)?) async throws -> DownloadResult {

        let guid = getGUID()
        log("正在获取 \(app.name) 的下载信息...")

        let host = acc.pod.isEmpty ? "p25-buy.itunes.apple.com" : "p\(acc.pod)-buy.itunes.apple.com"
        let urlString = "https://\(host)\(privateDownloadPath)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }

        // S6/S9: 支持 externalVersionID 参数
        var payload: [String: Any] = ["creditDisplay": "", "guid": guid, "salableAdamId": app.id, "serialNumber": "0"]
        if let vID = externalVersionID, !vID.isEmpty {
            payload["externalVersionId"] = vID
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acc.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(acc.directoryServicesID, forHTTPHeaderField: "X-Dsid")

        let dict = try await withRetry {
            try await sendPlistRequest(request, payload: payload)
        }

        let failureType = dict["failureType"] as? String ?? ""
        let customerMessage = dict["customerMessage"] as? String ?? ""
        if failureType == "2034" || failureType == "2042" || customerMessage == "Your password has changed." {
            throw AppStoreError.passwordTokenExpired
        }
        if failureType == "9610" { throw AppStoreError.licenseRequired }
        if !failureType.isEmpty {
            throw AppStoreError.unknownError(customerMessage.isEmpty ? failureType : customerMessage)
        }

        guard let songList = dict["songList"] as? [[String: Any]], let item = songList.first,
              item["URL"] as? String != nil else {
            throw AppStoreError.parseError("下载响应中没有 URL")
        }

        // S4: endpoint fallback — 收集所有可用的下载 URL
        let downloadURLs: [URL] = songList.compactMap {
            guard let urlStr = $0["URL"] as? String else { return nil }
            return URL(string: urlStr)
        }

        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let sinfs = item["sinfs"] as? [[String: Any]] ?? []
        let version = (metadata["bundleShortVersionString"] as? String) ?? "unknown"

        guard let destDir = outputDirectory else {
            throw AppStoreError.unknownError("未指定下载目录")
        }
        let fileExt = platform?.fileExtension ?? "ipa"
        let fileName = "\(app.bundleID)_\(app.id)_\(version).\(fileExt)"
        let destPath = destDir.appendingPathComponent(fileName)
        let tmpPath = destDir.appendingPathComponent("\(fileName).tmp")

        // S5: 断点续传 — 检查已有临时文件大小
        let existingSize = getExistingFileSize(at: tmpPath)

        // S4: 下载重试 — 依次尝试 endpoint fallback URL，每次最多 2 次网络重试
        log("正在下载 \(fileExt.uppercased()) (\(version))\(existingSize > 0 ? " [续传: \(formatBytes(existingSize))]" : "")...")
        var downloadSuccess = false
        var downloadError: Error?

        for (idx, url) in downloadURLs.enumerated() {
            if idx > 0 { log("主下载 URL 失败，尝试备用 endpoint #\(idx + 1)...", type: .warning) }
            for attempt in 1...2 {
                do {
                    try await downloadFile(from: url, to: tmpPath, existingSize: existingSize) { [weak self] p in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress = p
                            onProgress?(p)
                        }
                    }
                    downloadSuccess = true
                    break
                } catch {
                    downloadError = error
                    if attempt < 2 {
                        log("下载失败 (attempt \(attempt)): \(error.localizedDescription)，重试...", type: .warning)
                        try? FileManager.default.removeItem(at: tmpPath)
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
            }
            if downloadSuccess { break }
        }

        guard downloadSuccess else {
            throw downloadError ?? AppStoreError.unknownError("下载失败")
        }

        log("正在处理 \(fileExt.uppercased())...")
        try await processIPA(src: tmpPath, dst: destPath, metadata: metadata, sinfs: sinfs, account: acc)
        try? FileManager.default.removeItem(at: tmpPath)

        let result = DownloadResult(
            app: app, destinationPath: destPath,
            version: version, bundleID: app.bundleID, region: acc.region
        )
        log("下载完成: \(destPath.path)", type: .success)
        downloadResults.append(result)
        return result
    }

    // MARK: - S5: 断点续传支持

    /// 获取已存在的临时文件大小（用于断点续传）
    private func getExistingFileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 下载文件（支持 Range 头续传）
    private func downloadFile(from url: URL, to destination: URL, existingSize: Int64 = 0,
                              onProgress: @escaping (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // S5: 断点续传 — 如果已有部分文件，发送 Range 请求
        if existingSize > 0 {
            request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
        }

        let caller = ResumableDownloadHandler(destination: destination, existingSize: existingSize, onProgress: onProgress)
        return try await withCheckedThrowingContinuation { continuation in
            caller.continuation = continuation
            let delegate = ProgressDelegate(onProgress: onProgress) { tmpURL, error in
                caller.handle(tmpURL: tmpURL, error: error)
            }
            let session = URLSession(
                configuration: .default,
                delegate: DelegatingDownloader(delegate: delegate),
                delegateQueue: nil
            )
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    private func processIPA(src: URL, dst: URL, metadata: [String: Any], sinfs: [[String: Any]], account: Account) async throws {
        let metaData = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        let accCopy = account
        try await Task.detached(priority: .userInitiated) {
            try self.processIPASync(src: src, dst: dst, metadata: metaData, account: accCopy)
        }.value

        // SINF 复制（通过 ipatool-go 二进制，DRM 应用必需）
        if !sinfs.isEmpty {
            log("正在注入 SINF（通过 ipatool-go）...")
            do {
                try await IPAToolGoBridge.shared.replicateSinf(
                    packagePath: dst.path,
                    sinfsData: try PropertyListSerialization.data(
                        fromPropertyList: ["sinfs": sinfs], format: .binary, options: 0
                    ),
                    accountKey: account.email
                )
                log("SINF 注入完成")
            } catch let error as GoBridgeError {
                log("SINF 注入失败: \(error.description)（非 DRM 应用可忽略）", type: .warning)
            }
        }
    }

    private nonisolated func processIPASync(src: URL, dst: URL, metadata metaData: Data, account: Account) throws {
        let metadata = try PropertyListSerialization.propertyList(from: metaData, options: [], format: nil) as? [String: Any] ?? [:]

        let fm = FileManager.default
        let srcData = try Data(contentsOf: src)
        let entries = try ZipArchive.readEntries(from: srcData)

        var zipEntries: [(name: String, data: Data)] = entries.map { ($0.name, $0.data) }

        var metaWithAccount = metadata
        metaWithAccount["apple-id"] = account.email
        metaWithAccount["userName"] = account.email
        let plistData = try PropertyListSerialization.data(fromPropertyList: metaWithAccount, format: .binary, options: 0)
        zipEntries.append(("iTunesMetadata.plist", plistData))

        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        let outputData = try ZipArchive.createZip(entries: zipEntries)
        try outputData.write(to: dst)
    }

    // MARK: - S6: 历史版本

    /// 列出应用的所有历史版本 ID
    public func listVersions(app: AppInfo, platform: Platform? = nil) async throws -> [AppVersion] {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        let guid = getGUID()
        let resolvedPlatform = platform ?? .iphone

        log("正在获取 \(app.name) 的版本列表 (\(resolvedPlatform.displayName))...")

        let host = acc.pod.isEmpty ? "p25-buy.itunes.apple.com" : "p\(acc.pod)-buy.itunes.apple.com"
        let urlString = "https://\(host)\(privateDownloadPath)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }

        let payload: [String: Any] = ["creditDisplay": "", "guid": guid, "salableAdamId": app.id, "serialNumber": "0"]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acc.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(acc.directoryServicesID, forHTTPHeaderField: "X-Dsid")

        let dict = try await withRetry {
            try await sendPlistRequest(request, payload: payload)
        }

        let failureType = dict["failureType"] as? String ?? ""
        if failureType == "2034" || failureType == "2042" { throw AppStoreError.passwordTokenExpired }
        if failureType == "9610" { throw AppStoreError.licenseRequired }
        if !failureType.isEmpty {
            let msg = dict["customerMessage"] as? String ?? failureType
            throw AppStoreError.unknownError(msg)
        }

        guard let songList = dict["songList"] as? [[String: Any]], let item = songList.first else {
            throw AppStoreError.parseError("版本列表响应无效")
        }

        let metadata = item["metadata"] as? [String: Any] ?? [:]

        // softwareVersionExternalIdentifiers: 所有历史版本 ID 列表
        guard let rawIdentifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any] else {
            throw AppStoreError.parseError("未找到版本标识列表")
        }

        let versionIDs = rawIdentifiers.map { String(describing: $0) }

        // 最新版本 ID
        let latestID = metadata["softwareVersionExternalIdentifier"].map { String(describing: $0) }

        let versions = versionIDs.map { vID in
            AppVersion(externalVersionID: vID, isLatest: vID == latestID)
        }

        log("找到 \(versions.count) 个历史版本")
        return versions
    }

    /// 获取指定版本的元数据
    public func getVersionMetadata(app: AppInfo, externalVersionID: String, platform: Platform? = nil) async throws -> VersionMetadata {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        let guid = getGUID()

        log("正在获取版本 \(externalVersionID) 的元数据...")

        let host = acc.pod.isEmpty ? "p25-buy.itunes.apple.com" : "p\(acc.pod)-buy.itunes.apple.com"
        let urlString = "https://\(host)\(privateDownloadPath)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }

        let payload: [String: Any] = [
            "creditDisplay": "", "guid": guid, "salableAdamId": app.id,
            "serialNumber": "0", "externalVersionId": externalVersionID,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acc.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(acc.directoryServicesID, forHTTPHeaderField: "X-Dsid")

        let dict = try await withRetry {
            try await sendPlistRequest(request, payload: payload)
        }

        let failureType = dict["failureType"] as? String ?? ""
        if !failureType.isEmpty {
            let msg = dict["customerMessage"] as? String ?? failureType
            throw AppStoreError.unknownError(msg)
        }

        guard let songList = dict["songList"] as? [[String: Any]], let item = songList.first else {
            throw AppStoreError.parseError("版本元数据响应无效")
        }

        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let displayVersion = (metadata["bundleShortVersionString"] as? String) ?? "unknown"
        let releaseDate = metadata["releaseDate"] as? String
        let bundleVersion = metadata["bundleVersion"] as? String

        return VersionMetadata(displayVersion: displayVersion, releaseDate: releaseDate, bundleVersion: bundleVersion)
    }

    // MARK: - S7: 已购应用浏览

    /// 获取已购应用列表
    /// 通过 ipatool-go 二进制桥接（DMAP 协议复杂，直接复用 Go 实现）
    public func listPurchases(limit: Int = 50, platform: Platform? = nil) async throws -> [PurchasedApp] {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }

        log("正在获取已购应用列表...")

        do {
            let result = try await IPAToolGoBridge.shared.listPurchases(
                accountKey: acc.email,
                limit: limit,
                platform: platform?.rawValue
            )
            let apps = result.map { item in
                PurchasedApp(
                    appID: item.appID,
                    bundleID: item.bundleID,
                    name: item.name,
                    version: item.version,
                    purchaseDate: item.purchaseDate,
                    platforms: item.platforms.compactMap { Platform(rawValue: $0) }
                )
            }
            purchases = apps
            log("获取到 \(apps.count) 个已购应用")
            return apps
        } catch let error as GoBridgeError {
            log("获取已购应用失败: \(error.description)", type: .error)
            throw AppStoreError.unknownError(error.description)
        }
    }

    // MARK: - 下载队列

    /// 将应用加入下载队列
    public func enqueueDownload(app: AppInfo) {
        guard let acc = selectedAccount else {
            log("请先选择一个账号", type: .error)
            return
        }
        if downloadDirectory == nil {
            onDirectorySelectionNeeded?()
        }
        guard downloadDirectory != nil else { return }
        // 检查是否已在队列中
        guard !downloadQueue.contains(where: { $0.app.id == app.id && ($0.status == .waiting || $0.status == .purchasing || $0.status == .downloading || $0.status == .processing || $0.status == .completed || $0.status == .paused) }) else {
            log("\"\(app.name)\" 已在下载队列中", type: .warning)
            return
        }
        let item = DownloadQueueItem(app: app, account: acc, addedAt: Date())
        downloadQueue.append(item)
        log("\"\(app.name)\" 已加入下载队列", type: .success)
        processQueue()
    }

    /// 取消下载任务（取消后自动从列表中移除）
    public func cancelDownload(_ item: DownloadQueueItem) {
        guard let idx = downloadQueue.firstIndex(where: { $0.id == item.id }) else { return }
        let status = downloadQueue[idx].status
        if status == .waiting || status == .failed || status == .purchasing || status == .downloading || status == .processing || status == .paused {
            downloadQueue[idx].status = .cancelled
            log("\"\(item.app.name)\" 已取消", type: .info)
            let itemID = item.id
            Task { @MainActor [weak self] in
                self?.downloadQueue.removeAll(where: { $0.id == itemID })
            }
        }
    }

    // S5: 暂停下载
    public func pauseDownload(_ item: DownloadQueueItem) {
        guard let idx = downloadQueue.firstIndex(where: { $0.id == item.id }) else { return }
        if downloadQueue[idx].status == .downloading {
            downloadQueue[idx].status = .paused
            log("\"\(item.app.name)\" 已暂停", type: .info)
        }
    }

    // S5: 恢复下载
    public func resumeDownload(_ item: DownloadQueueItem) {
        guard let idx = downloadQueue.firstIndex(where: { $0.id == item.id }) else { return }
        if downloadQueue[idx].status == .paused {
            downloadQueue[idx].status = .waiting
            log("\"\(item.app.name)\" 已恢复", type: .info)
            processQueue()
        }
    }

    /// 重试下载任务
    public func retryDownload(_ item: DownloadQueueItem) {
        guard let idx = downloadQueue.firstIndex(where: { $0.id == item.id }) else { return }
        downloadQueue[idx].status = .waiting
        downloadQueue[idx].error = nil
        downloadQueue[idx].progress = 0
        log("\"\(item.app.name)\" 已重新加入队列", type: .info)
        processQueue()
    }

    /// 删除已下载文件及记录
    public func removeDownloadResult(_ result: DownloadResult) {
        if FileManager.default.fileExists(atPath: result.destinationPath.path) {
            try? FileManager.default.removeItem(at: result.destinationPath)
            log("已删除文件: \(result.destinationPath.lastPathComponent)", type: .info)
        }
        downloadResults.removeAll(where: { $0.id == result.id })
    }

    /// 从队列中移除已完成/已取消的任务
    public func removeCompletedFromQueue() {
        downloadQueue.removeAll(where: { $0.status == .completed || $0.status == .cancelled })
    }

    /// 处理下载队列
    public func processQueue() {
        guard !isProcessingQueue else { return }
        Task {
            await processNextItem()
        }
    }

    private func processNextItem() async {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        // 找到下一个等待中的任务
        guard let index = downloadQueue.firstIndex(where: { $0.status == .waiting }) else { return }

        let item = downloadQueue[index]

        guard let dlDir = downloadDirectory else {
            downloadQueue[index].status = .failed
            downloadQueue[index].error = "未选择下载目录"
            log("下载失败: 未选择下载目录，请先在「下载」页面设置", type: .error)
            Task { @MainActor [weak self] in self?.processQueue() }
            return
        }

        let didStartAccessing = dlDir.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                dlDir.stopAccessingSecurityScopedResource()
            }
        }

        // 确保目录存在
        ensureDownloadDirExists()

        // 购买
        downloadQueue[index].status = .purchasing
        do {
            try await purchase(app: item.app)
        } catch let error as AppStoreError {
            if case .passwordTokenExpired = error {
                downloadQueue[index].status = .failed
                downloadQueue[index].error = "登录凭证已过期，请重新登录"
                log("\"\(item.app.name)\" 下载失败: 凭证过期", type: .error)
                Task { @MainActor [weak self] in self?.processQueue() }
                return
            } else if case .licenseAlreadyExists = error {
                // 许可证已存在，直接下载
            } else {
                downloadQueue[index].status = .failed
                downloadQueue[index].error = error.localizedDescription
                log("\"\(item.app.name)\" 获取许可失败: \(error.localizedDescription)", type: .error)
                Task { @MainActor [weak self] in self?.processQueue() }
                return
            }
        } catch {
            downloadQueue[index].status = .failed
            downloadQueue[index].error = error.localizedDescription
            log("\"\(item.app.name)\" 获取许可失败: \(error.localizedDescription)", type: .error)
            Task { @MainActor [weak self] in self?.processQueue() }
            return
        }

        // 下载
        downloadQueue[index].status = .downloading
        do {
            let result = try await download(app: item.app, outputDirectory: downloadDirectory) { [weak self] p in
                Task { @MainActor [weak self] in
                    if let i = self?.downloadQueue.firstIndex(where: { $0.id == item.id }) {
                        self?.downloadQueue[i].progress = p
                    }
                }
            }
            downloadQueue[index].status = .completed
            downloadQueue[index].progress = 1.0
            log("\"\(item.app.name)\" 下载完成: \(result.destinationPath.lastPathComponent)", type: .success)
            // 完成后从队列列表中移除
            downloadQueue.removeAll(where: { $0.id == item.id })
        } catch {
            downloadQueue[index].status = .failed
            downloadQueue[index].error = error.localizedDescription
            log("\"\(item.app.name)\" 下载失败: \(error.localizedDescription)", type: .error)
        }

        // 继续下一个
        Task { @MainActor [weak self] in
            self?.processQueue()
        }
    }

    private func ensureDownloadDirExists() {
        guard let dir = downloadDirectory else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - 下载完成处理

private final class ResumableDownloadHandler: @unchecked Sendable {
    public let destination: URL
    public let existingSize: Int64
    public let onProgress: (Double) -> Void
    public var continuation: CheckedContinuation<Void, Error>?
    private var completed = false
    private let lock = NSLock()

    public init(destination: URL, existingSize: Int64 = 0, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.existingSize = existingSize
        self.onProgress = onProgress
    }

    public func handle(tmpURL: URL?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true

        if let error {
            continuation?.resume(throwing: error)
        } else if let tmpURL {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tmpURL, to: destination)
                DispatchQueue.main.async { [onProgress] in
                    onProgress(1.0)
                }
                continuation?.resume()
            } catch {
                continuation?.resume(throwing: error)
            }
        }
    }
}

// MARK: - 下载进度代理

private final class ProgressDelegate: @unchecked Sendable {
    public let onProgress: (Double) -> Void
    public let onComplete: (URL?, Error?) -> Void

    public init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }
}

private final class DelegatingDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let delegate: ProgressDelegate
    public init(delegate: ProgressDelegate) { self.delegate = delegate }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        delegate.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        delegate.onComplete(location, nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            delegate.onComplete(nil, error)
        }
    }
}
