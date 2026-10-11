import AppKit
import Foundation
import IOKit
import IOKit.network

// MARK: - 防止自动跟随重定向的 Session 代理

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// App Store API 核心服务 — 支持多账号
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

    private let keychain = KeychainService.shared
    private var isProcessingQueue = false

    /// 普通网络请求 session（允许重定向）
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    /// 认证专用 session（禁止自动跟随 302 重定向）
    private let authSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    // MARK: - 常量

    private let iTunesAPIDomain = "itunes.apple.com"
    private let privateAppStoreDomain = "buy.itunes.apple.com"
    private let iTunesPathSearch = "/search"
    private let iTunesPathLookup = "/lookup"
    private let privatePurchasePath = "/WebObjects/MZFinance.woa/wa/buyProduct"
    private let privateDownloadPath = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"

    private let defaultAuthURL = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
    private let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

    /// 规范化 bag 返回的认证端点。
    /// Apple 当前的 native fast 端点在缺少尾部 `/` 时会出现额外重定向甚至认证失败；
    /// Go 版已做兼容，这里保持一致。
    private func normalizedAuthEndpoint(_ endpoint: String) -> String {
        guard !endpoint.isEmpty else { return endpoint }
        // 与上游一致：认证路径必须以 / 结尾，否则 Apple 返回 301 Moved Permanently
        if !endpoint.hasSuffix("/") {
            return endpoint + "/"
        }
        return endpoint
    }

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

    /// 发送 plist 请求并解析响应
    private func sendPlistRequest(_ request: URLRequest, payload: [String: Any]) async throws -> [String: Any] {
        var req = request
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let (data, _) = try await session.data(for: req)
        guard let dict = try parsePlist(from: data) as [String: Any]? else {
            throw AppStoreError.parseError("无法解析响应")
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

    init() {
        Task { await loadAccounts() }
        restoreDownloadDirectoryBookmark()
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
            if isStale {
                saveDownloadDirectoryBookmark(url: url)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: "downloadDirectoryBookmark")
        }
    }

    // MARK: - 账号管理

    func loadAccounts() async {
        do {
            accounts = try keychain.loadAllAccounts()
            if selectedAccount == nil {
                selectedAccount = accounts.first
            }
            log("已加载 \(accounts.count) 个账号")
        } catch {
            log("加载账号失败: \(error.localizedDescription)", type: .error)
        }
    }

    func login(email: String, password: String, authCode: String, region: String) async throws {
        isLoggingIn = true
        defer { isLoggingIn = false }

        log("正在获取认证端点...")
        let authEndpoint = await fetchBagEndpoint()

        log("正在登录 \(email) (\(RegionOption.displayName(for: region)))...")
        let guid = getGUID()

        var redirectURL: String?
        var redirectAttempt = 0
        var attempt = 0

        while attempt < 4 {
            attempt += 1
            let (result, redirect, error, retryDelay) = try await attemptLogin(
                email: email, password: password, authCode: authCode,
                guid: guid, endpoint: redirectURL ?? authEndpoint, attempt: attempt
            )

            if let error = error {
                if case .authCodeRequired = error {
                    log("需要两步验证码", type: .warning)
                    throw AppStoreError.authCodeRequired
                }
                if case .rateLimited = error {
                    let delay = retryDelay ?? 10
                    log("请求被限流，等待 \(Int(delay)) 秒后重试...", type: .warning)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt -= 1  // 不计入 attempt 计数
                    continue
                }
                throw error
            }

            if var acc = result {
                acc = Account(
                    email: acc.email, name: acc.name, region: region,
                    passwordToken: acc.passwordToken, directoryServicesID: acc.directoryServicesID,
                    storeFront: acc.storeFront, password: acc.password, pod: acc.pod
                )
                log("登录成功: \(acc.email) (\(acc.name)) | 地区: \(acc.regionDisplayName)")
                try keychain.saveAccount(acc)
                await loadAccounts()
                selectedAccount = acc
                return
            }

            if let redirect = redirect {
                redirectURL = redirect
                redirectAttempt += 1
                if redirectAttempt > 3 { throw AppStoreError.unknownError("重定向次数过多") }
                continue
            }

            // 无结果、无错误、无重定向（如 -5000 首次尝试），继续重试
        }

        throw AppStoreError.unknownError("登录失败")
    }

    func deleteAccount(_ account: Account) throws {
        try keychain.deleteAccount(id: account.id)
        if selectedAccount?.id == account.id {
            selectedAccount = accounts.first(where: { $0.id != account.id })
        }
        Task { await loadAccounts() }
    }

    // MARK: - Re-Login

    /// 凭证过期时自动重新登录（与 Go 版一致：用保存的密码自动刷新 token）
    private func relogin(account: Account) async throws -> Account {
        log("凭证已过期，正在自动重新登录...")
        let endpoint = await fetchBagEndpoint()

        let guid = getGUID()
        var redirectURL: String?
        var attempt = 0
        var redirectCount = 0

        while attempt < 4 {
            attempt += 1
            let (result, redirect, error, retryDelay) = try await attemptLogin(
                email: account.email, password: account.password, authCode: "",
                guid: guid, endpoint: redirectURL ?? endpoint, attempt: attempt
            )

            if let error {
                if case .rateLimited = error {
                    let delay = retryDelay ?? 10
                    log("重新登录被限流，等待 \(Int(delay)) 秒...", type: .warning)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt -= 1
                    continue
                }
                throw error
            }

            if var acc = result {
                acc = Account(
                    email: acc.email, name: acc.name, region: account.region,
                    passwordToken: acc.passwordToken, directoryServicesID: acc.directoryServicesID,
                    storeFront: acc.storeFront, password: account.password, pod: acc.pod
                )
                log("重新登录成功，token 已刷新")
                try keychain.saveAccount(acc)
                await loadAccounts()
                selectedAccount = acc
                return acc
            }

            if let redirect = redirect {
                redirectURL = redirect
                redirectCount += 1
                if redirectCount > 3 { throw AppStoreError.unknownError("重新登录重定向次数过多") }
                continue
            }

            // 无结果、无错误、无重定向，继续重试
        }

        throw AppStoreError.unknownError("重新登录失败")
    }

    // MARK: - Log

    func log(_ message: String, type: LogEntry.LogType = .info) {
        logMessages.append(LogEntry(message: message, type: type))
        print("[IPATool] \(message)")
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

    /// 使用 IOKit 获取稳定的硬件 MAC 地址（与上游一致）。
    /// 在 macOS 27 上 sysctl 返回的 MAC 可能被红化为 02:00:00:00:00:00，
    /// IOKit 的 IOMACAddress 属性能返回真实硬件地址。
    /// 优先 en0，其次其他物理接口，最后回退到接口上报的 link-layer 地址。
    private func getMACAddress() -> String? {
        var selected: (address: [UInt8], priority: Int)?

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var cursor = ifaddr
        while let addr = cursor {
            defer { cursor = addr.pointee.ifa_next }

            // 只关心 link-layer 接口，跳过 loopback / point-to-point
            guard let name = addr.pointee.ifa_name.map({ String(cString: $0) }),
                  addr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
                  (addr.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (addr.pointee.ifa_flags & UInt32(IFF_POINTOPOINT)) == 0
            else { continue }

            let isPrimary = name == "en0"
            var candidate: [UInt8]?

            // 1. 优先从 IOKit 读取真实硬件 MAC
            if let hw = hardwareMACAddress(forBSDName: name) {
                candidate = hw
            } else if let link = linkLayerMAC(from: addr.pointee.ifa_addr) {
                candidate = link
            }

            guard let mac = candidate, Self.isUsableMACAddress(mac) else { continue }

            let priority = isPrimary ? 0 : 1
            if selected == nil || priority < selected!.priority ||
                (priority == selected!.priority && mac.lexicographicallyPrecedes(selected!.address)) {
                selected = (mac, priority)
            }
        }

        return selected?.address.map { String(format: "%02X", $0) }.joined()
    }

    /// 从 IOService 注册表读取接口的真实硬件 MAC 地址（IOMACAddress）。
    private func hardwareMACAddress(forBSDName name: String) -> [UInt8]? {
        let matching = IOServiceNameMatching(name)
        var service: io_service_t = 0
        defer { if service != 0 { IOObjectRelease(service) } }

        // IOServiceGetMatchingService 会消耗 matching 字典
        service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }

        let key = "IOMACAddress" as CFString
        guard let property = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) else { return nil }

        // 确保是 CFData 且长度为 6 字节
        guard CFGetTypeID(property) == CFDataGetTypeID(),
              let data = property as? Data, data.count == 6
        else { return nil }

        return [UInt8](data)
    }

    /// 从 sockaddr_dl 提取 link-layer MAC 地址。
    private func linkLayerMAC(from sa: UnsafePointer<sockaddr>) -> [UInt8]? {
        return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
            let sdl = dl.pointee
            guard sdl.sdl_alen == 6 else { return nil }
            let offset = Int(sdl.sdl_nlen)
            return withUnsafePointer(to: sdl.sdl_data) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: Int(sdl.sdl_nlen) + Int(sdl.sdl_alen)) { bytes in
                    Array(UnsafeBufferPointer(start: bytes.advanced(by: offset), count: 6))
                }
            }
        }
    }

    /// 校验 MAC 地址有效性：6 字节、非全零、非 02:00:00:00:00:00、非多播/广播。
    private static func isUsableMACAddress(_ mac: [UInt8]) -> Bool {
        guard mac.count == 6 else { return false }
        let allZero = mac.allSatisfy { $0 == 0 }
        let redacted = mac == [0x02, 0x00, 0x00, 0x00, 0x00, 0x00]
        let multicast = (mac[0] & 0x01) != 0
        return !allZero && !redacted && !multicast
    }

    // MARK: - Login helpers

    /// 为中国大陆和印度的手机号 Apple ID 推导 Storefront 路由提示。
    /// 与上游一致：只影响路由头，不改变发送给 Apple 的 Apple ID。
    private func phoneNumberStorefront(_ appleID: String) -> String? {
        var number = appleID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        var international = false
        if number.hasPrefix("+") {
            international = true
            number.removeFirst()
        } else if number.hasPrefix("00") {
            international = true
            number.removeFirst(2)
        }

        // 必须全是数字
        guard number.allSatisfy({ $0.isNumber }) else { return nil }

        switch (number.count, number.prefix(3)) {
        case (13, "861"):
            return Storefront.storeFrontID(for: "CN")
        case (12, _) where number.hasPrefix("91"):
            number.removeFirst(2)
        case _ where international:
            return nil
        default:
            break
        }

        if number.count == 11, number.first == "1" {
            return Storefront.storeFrontID(for: "CN")
        }

        // 印度本地号码允许区号前缀 0
        if !international, number.count == 11, number.first == "0" {
            number.removeFirst()
        }

        if number.count == 10, let first = number.first, first >= "6", first <= "9" {
            return Storefront.storeFrontID(for: "IN")
        }

        return nil
    }

    /// 规范化两步验证码：去除空白和 bracketed-paste 标记，要求恰好 6 位数字。
    private func normalizeAuthCode(_ code: String) -> String? {
        guard !code.isEmpty else { return "" }
        var trimmed = code.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\u{1B}[200~"), trimmed.hasSuffix("\u{1B}[201~") {
            trimmed.removeFirst("\u{1B}[200~".count)
            trimmed.removeLast("\u{1B}[201~".count)
        }
        let digits = trimmed.filter { $0.isNumber }
        return digits.count == 6 ? digits : nil
    }

    /// 解析 Retry-After 头（秒数或 HTTP 日期），返回需要等待的秒数。
    private func retryAfterSeconds(headerValue: String?) -> Int? {
        guard let value = headerValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) {
            return min(seconds, 120) // 上限 120 秒
        }
        if let date = httpDateFormatter.date(from: value) {
            let interval = Int(date.timeIntervalSinceNow)
            return max(0, min(interval, 120))
        }
        return nil
    }

    private var httpDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    // MARK: - Bag

    private func fetchBagEndpoint() async -> String {
        let guid = getGUID()
        let urlString = "https://init.itunes.apple.com/bag.xml?guid=\(guid)"
        guard let url = URL(string: urlString) else { return defaultAuthURL }

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await session.data(for: request)
            guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
                let fallback = normalizedAuthEndpoint(defaultAuthURL)
                log("Bag 状态码异常，使用默认端点: \(fallback)", type: .warning)
                return fallback
            }

            let dict: [String: Any]? = try parsePlist(from: data)
            if let urlBag = dict?["urlBag"] as? [String: Any],
               let auth = urlBag["authenticateAccount"] as? String,
               !auth.isEmpty {
                return normalizedAuthEndpoint(auth)
            }
        } catch {
            // ignore
        }

        let fallback = normalizedAuthEndpoint(defaultAuthURL)
        log("Bag 解析失败，使用默认端点: \(fallback)", type: .warning)
        return fallback
    }

    // MARK: - Login attempt

    private func attemptLogin(
        email: String, password: String, authCode: String, guid: String,
        endpoint: String, attempt: Int
    ) async throws -> (Account?, String?, AppStoreError?, TimeInterval?) {
        let authEndpoint = normalizedAuthEndpoint(endpoint)
        guard let url = URL(string: authEndpoint) else { return (nil, nil, .invalidURL, nil) }

        guard let normalizedCode = normalizeAuthCode(authCode) else {
            return (nil, nil, .loginError("两步验证码必须是 6 位数字"), nil)
        }
        let fullPassword = password + normalizedCode

        // 使用 application/x-www-form-urlencoded 格式（与 Go ipatool 一致）
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "appleId", value: email),
            URLQueryItem(name: "attempt", value: String(attempt)),
            URLQueryItem(name: "guid", value: guid),
            URLQueryItem(name: "password", value: fullPassword),
            URLQueryItem(name: "rmp", value: "0"),
            URLQueryItem(name: "why", value: "signIn"),
        ]
        let bodyString = components.query ?? ""

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // 手机号 Apple ID 需要 Storefront 路由提示
        if let sf = phoneNumberStorefront(email) {
            request.setValue(sf, forHTTPHeaderField: "X-Apple-Store-Front")
        }
        request.httpBody = bodyString.data(using: .utf8)

        let (rawData, response) = try await authSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return (nil, nil, .httpError(0), nil)
        }

        log("认证响应: HTTP \(httpResponse.statusCode)")

        // 429 限流 — 尊重 Retry-After 头
        if httpResponse.statusCode == 429 {
            let delay = retryAfterSeconds(headerValue: httpResponse.value(forHTTPHeaderField: "Retry-After")).map { TimeInterval($0) } ?? 10
            return (nil, nil, .rateLimited, delay)
        }

        // 认证重定向（301/302/307/308）— 手动跟随，仅更换目标 URL，
        // 请求体（含 attempt 值）保持不变。303 要求 GET，不属于此流程。
        if [301, 302, 307, 308].contains(httpResponse.statusCode) {
            if let location = httpResponse.value(forHTTPHeaderField: "Location") {
                log("收到 \(httpResponse.statusCode) 重定向: \(location)")
                return (nil, location, nil, nil)
            }
            return (nil, nil, .unknownError("\(httpResponse.statusCode) 但无 Location 头"), nil)
        }

        // 非 200 状态码
        if httpResponse.statusCode != 200 {
            let body = String(data: rawData, encoding: .utf8)?.prefix(300) ?? "(空)"
            log("认证失败 HTTP \(httpResponse.statusCode): \(body)", type: .error)
            return (nil, nil, .loginError("服务器返回 HTTP \(httpResponse.statusCode)"), nil)
        }

        // 解析响应体: 提取 XML 中的 plist 片段
        let data = extractPlistData(from: rawData)
        guard let dict = try parsePlist(from: data) as [String: Any]? else {
            log("认证响应原始内容前 500 字: \(String(data: rawData, encoding: .utf8)?.prefix(500) ?? "(非文本)")", type: .warning)
            return (nil, nil, .parseError("无法解析登录响应"), nil)
        }

        let failureType = dict["failureType"] as? String
        let customerMessage = dict["customerMessage"] as? String

        // 首次尝试时 failureType == "-5000" 需要重试（与 Go 一致）
        if attempt == 1, failureType == "-5000" {
            return (nil, nil, nil, nil) // 触发重试
        }

        // 需要两步验证码
        if (failureType == nil || failureType?.isEmpty == true)
            && authCode.isEmpty
            && customerMessage == "MZFinance.BadLogin.Configurator_message" {
            return (nil, nil, .authCodeRequired, nil)
        }

        // 账号已禁用
        if customerMessage == "Your account is disabled." {
            return (nil, nil, .accountDisabled, nil)
        }

        // 通用失败
        if let failureType, !failureType.isEmpty {
            return (nil, nil, .loginError(customerMessage ?? failureType), nil)
        }

        // 提取账号信息
        guard let accountInfo = dict["accountInfo"] as? [String: Any],
              let appleId = accountInfo["appleId"] as? String,
              let passwordToken = dict["passwordToken"] as? String,
              let dsPersonId = dict["dsPersonId"] as? String else {
            let msg = customerMessage ?? "响应格式不完整"
            return (nil, nil, .parseError(msg), nil)
        }

        let address = accountInfo["address"] as? [String: Any] ?? [:]
        let firstName = address["firstName"] as? String ?? ""
        let lastName = address["lastName"] as? String ?? ""
        let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")

        let storeFront = httpResponse.value(forHTTPHeaderField: "x-set-apple-store-front")
            ?? "143465-29"
        let pod = httpResponse.value(forHTTPHeaderField: "pod") ?? ""

        let acc = Account(
            email: appleId, name: name.isEmpty ? appleId : name, region: "",
            passwordToken: passwordToken, directoryServicesID: dsPersonId,
            storeFront: storeFront, password: password, pod: pod
        )
        return (acc, nil, nil, nil)
    }

    // MARK: - Search

    func search(term: String, limit: Int = 25, platform: String? = nil) async throws -> [AppInfo] {
        guard let acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        isSearching = true
        defer { isSearching = false }

        let country = acc.countryCode ?? "CN"
        let termEncoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        // 默认搜索所有平台；可按 platform 过滤（iphone/ipad/appletv/macos）
        let entity: String
        switch platform {
        case "iphone": entity = "software"
        case "ipad": entity = "iPadSoftware"
        case "appletv": entity = "tvSoftware"
        case "macos": entity = "macSoftware"
        default: entity = "software,iPadSoftware,tvSoftware,macSoftware"
        }
        let urlString = "https://\(iTunesAPIDomain)\(iTunesPathSearch)?entity=\(entity)&limit=\(limit)&media=software&term=\(termEncoded)&country=\(country)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        log("搜索: \"\(term)\" (地区: \(acc.regionDisplayName))...")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let searchResponse = try JSONDecoder().decode(SearchResponse.self, from: data)
        log("找到 \(searchResponse.resultCount) 个结果")
        return searchResponse.results
    }

    /// 通过 iTunes Lookup API 获取应用详细信息
    func lookup(appID: Int64, region: String) async throws -> AppDetail {
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

    // MARK: - Purchase

    func purchase(app: AppInfo) async throws {
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

    /// 按 app ID 直接购买（无需先搜索），与上游 purchase --app-id 对齐
    func purchaseByAppID(_ appID: Int64) async throws {
        let app = AppInfo(
            id: appID, bundleID: "", name: "App \(appID)", version: "",
            price: 0, iconURL: nil, developer: nil, description: nil,
            fileSizeBytes: nil, trackViewURL: nil
        )
        try await purchase(app: app)
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

        let dict = try await sendPlistRequest(request, payload: payload)

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

    // MARK: - List Versions

    /// 列出应用的所有可用版本外部 ID（与上游 list-versions 对齐）
    func listVersions(appID: Int64) async throws -> [String] {
        guard var acc = selectedAccount else { throw AppStoreError.notLoggedIn }

        var maxRetries = 2
        while true {
            do {
                return try await listVersionsCore(appID: appID, account: acc)
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

    private func listVersionsCore(appID: Int64, account acc: Account) async throws -> [String] {
        let guid = getGUID()
        let host = acc.pod.isEmpty ? "p25-buy.itunes.apple.com" : "p\(acc.pod)-buy.itunes.apple.com"
        let urlString = "https://\(host)\(privateDownloadPath)"
        guard let url = URL(string: urlString) else { throw AppStoreError.invalidURL }

        let payload: [String: Any] = ["creditDisplay": "", "guid": guid, "salableAdamId": appID]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acc.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(acc.directoryServicesID, forHTTPHeaderField: "X-Dsid")

        let dict = try await sendPlistRequest(request, payload: payload)

        let failureType = dict["failureType"] as? String ?? ""
        if failureType == "2034" || failureType == "2042" { throw AppStoreError.passwordTokenExpired }
        if failureType == "9610" { throw AppStoreError.licenseRequired }
        if !failureType.isEmpty { throw AppStoreError.unknownError(failureType) }

        guard let songList = dict["songList"] as? [[String: Any]],
              let item = songList.first,
              let metadata = item["metadata"] as? [String: Any],
              let identifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any]
        else {
            throw AppStoreError.parseError("无法提取版本列表")
        }

        return identifiers.map { "\($0)" }
    }

    // MARK: - Download

    func download(app: AppInfo, externalVersionID: String? = nil, outputDirectory: URL? = nil, onProgress: ((Double) -> Void)? = nil) async throws -> DownloadResult {
        guard var acc = selectedAccount else { throw AppStoreError.notLoggedIn }
        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        var maxRetries = 2

        while true {
            do {
                return try await downloadCore(app: app, externalVersionID: externalVersionID, account: acc, outputDirectory: outputDirectory, onProgress: onProgress)
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

    private func downloadCore(app: AppInfo, externalVersionID: String? = nil, account acc: Account, outputDirectory: URL?, onProgress: ((Double) -> Void)?) async throws -> DownloadResult {

        let guid = getGUID()
        log("正在获取 \(app.name) 的下载信息...")

        // 按优先级尝试下载端点：账号 pod 优先，回退到通用 pod（与上游一致）
        let preferredPod = acc.pod.isEmpty ? "25" : acc.pod
        let fallbackPods = [preferredPod, "71", "70", "25"].filter { !$0.isEmpty }
        // 去重保持顺序
        var seen = Set<String>()
        let endpoints = fallbackPods.filter { seen.insert($0).inserted }
            .map { "p\($0)-buy.itunes.apple.com" }

        // appExtVrsId：iOS 默认为 0，其他平台/版本需指定外部版本 ID
        let appExtVrsId = externalVersionID ?? "0"
        let payload: [String: Any] = [
            "appExtVrsId": appExtVrsId,
            "creditDisplay": "", "guid": guid, "salableAdamId": app.id
        ]

        var dict: [String: Any]?
        var lastError: Error?

        for host in endpoints {
            let urlString = "https://\(host)\(privateDownloadPath)"
            guard let url = URL(string: urlString) else { continue }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(acc.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
            request.setValue(acc.directoryServicesID, forHTTPHeaderField: "X-Dsid")

            do {
                dict = try await sendPlistRequest(request, payload: payload)
                log("下载端点可用: \(host)")
                break
            } catch {
                lastError = error
                log("端点 \(host) 失败，尝试下一个...", type: .warning)
                continue
            }
        }

        guard let dict = dict else {
            if let lastError { throw lastError }
            throw AppStoreError.invalidURL
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
              let downloadURLString = item["URL"] as? String, let downloadURL = URL(string: downloadURLString) else {
            throw AppStoreError.parseError("下载响应中没有 URL")
        }

        let metadata = item["metadata"] as? [String: Any] ?? [:]
        let version = (metadata["bundleShortVersionString"] as? String) ?? "unknown"

        // 判断是否为 macOS 安装包（.pkg），由 kind 字段或 URL 后缀判定
        let kind = item["kind"] as? String ?? ""
        let isMacOSPackage = kind.contains("mac") || downloadURL.pathExtension.lowercased() == "pkg"
        let fileExt = isMacOSPackage ? "pkg" : "ipa"

        guard let destDir = outputDirectory else {
            throw AppStoreError.unknownError("未指定下载目录")
        }
        let fileName = "\(app.bundleID)_\(app.id)_\(version).\(fileExt)"
        let destPath = destDir.appendingPathComponent(fileName)
        let tmpPath = destDir.appendingPathComponent("\(fileName).tmp")

        log("正在下载 \(fileExt.uppercased()) (\(version))...")
        try await downloadFile(from: downloadURL, to: tmpPath) { [weak self] p in
            Task { @MainActor [weak self] in
                self?.downloadProgress = p
                onProgress?(p)
            }
        }

        if isMacOSPackage {
            // macOS .pkg 直接重命名，无需 IPA 处理
            if FileManager.default.fileExists(atPath: destPath.path) {
                try? FileManager.default.removeItem(at: destPath)
            }
            try FileManager.default.moveItem(at: tmpPath, to: destPath)
        } else {
            log("正在处理 IPA...")
            try await processIPA(src: tmpPath, dst: destPath, metadata: metadata, account: acc)
            try? FileManager.default.removeItem(at: tmpPath)
        }

        let result = DownloadResult(
            app: app, destinationPath: destPath,
            version: version, bundleID: app.bundleID, region: acc.region
        )
        log("下载完成: \(destPath.path)", type: .success)
        downloadResults.append(result)
        return result
    }

    private func downloadFile(from url: URL, to destination: URL, onProgress: @escaping (Double) -> Void) async throws {
        let caller = DownloadCompletionHandler(destination: destination, onProgress: onProgress)
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
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    private func processIPA(src: URL, dst: URL, metadata: [String: Any], account: Account) async throws {
        let metaData = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        let accCopy = account
        try await Task.detached(priority: .userInitiated) {
            try self.processIPASync(src: src, dst: dst, metadata: metaData, account: accCopy)
        }.value
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

    // MARK: - 下载队列

    /// 将应用加入下载队列
    func enqueueDownload(app: AppInfo, externalVersionID: String? = nil) {
        guard let acc = selectedAccount else {
            log("请先选择一个账号", type: .error)
            return
        }
        if downloadDirectory == nil {
            selectDownloadDirectory()
        }
        guard downloadDirectory != nil else { return }
        // 检查是否已在队列中
        guard !downloadQueue.contains(where: { $0.app.id == app.id && ($0.status == .waiting || $0.status == .purchasing || $0.status == .downloading || $0.status == .processing || $0.status == .completed) }) else {
            log("\"\(app.name)\" 已在下载队列中", type: .warning)
            return
        }
        let item = DownloadQueueItem(app: app, account: acc, externalVersionID: externalVersionID, addedAt: Date())
        downloadQueue.append(item)
        log("\"\(app.name)\" 已加入下载队列", type: .success)
        processQueue()
    }

    /// 取消下载任务（取消后自动从列表中移除）
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

    /// 重试下载任务
    func retryDownload(_ item: DownloadQueueItem) {
        guard let idx = downloadQueue.firstIndex(where: { $0.id == item.id }) else { return }
        downloadQueue[idx].status = .waiting
        downloadQueue[idx].error = nil
        downloadQueue[idx].progress = 0
        log("\"\(item.app.name)\" 已重新加入队列", type: .info)
        processQueue()
    }

    /// 删除已下载文件及记录
    func removeDownloadResult(_ result: DownloadResult) {
        if FileManager.default.fileExists(atPath: result.destinationPath.path) {
            try? FileManager.default.removeItem(at: result.destinationPath)
            log("已删除文件: \(result.destinationPath.lastPathComponent)", type: .info)
        }
        downloadResults.removeAll(where: { $0.id == result.id })
    }

    /// 从队列中移除已完成/已取消的任务
    func removeCompletedFromQueue() {
        downloadQueue.removeAll(where: { $0.status == .completed || $0.status == .cancelled })
    }

    /// 处理下载队列
    func processQueue() {
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

private final class DownloadCompletionHandler: @unchecked Sendable {
    let destination: URL
    let onProgress: (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var completed = false
    private let lock = NSLock()

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func handle(tmpURL: URL?, error: Error?) {
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
    let onProgress: (Double) -> Void
    let onComplete: (URL?, Error?) -> Void

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }
}

private final class DelegatingDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let delegate: ProgressDelegate
    init(delegate: ProgressDelegate) { self.delegate = delegate }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        delegate.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        delegate.onComplete(location, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            delegate.onComplete(nil, error)
        }
    }
}
