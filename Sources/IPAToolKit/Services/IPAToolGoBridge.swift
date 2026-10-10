import Foundation
import Security

// MARK: - Go Account (ipatool-go 的 JSON 结构)

/// ipatool-go 存入 Keychain 的账号 JSON 结构
/// 注意：Go 的 JSON tag 与 Swift Account 的字段名不同
struct GoAccount: Decodable {
    let email: String
    let passwordToken: String?
    let directoryServicesIdentifier: String?
    let name: String?
    let storeFront: String?
    let password: String?
    let pod: String?
}

// MARK: - Bridge Error

public enum GoBridgeError: Error, CustomStringConvertible {
    case binaryNotFound
    case executionFailed(exitCode: Int32, stderr: String)
    case authCodeRequired
    case loginFailed(String)
    case parseError(String)
    case keychainReadFailed(String)

    public var description: String {
        switch self {
        case .binaryNotFound:
            return "未找到 ipatool-go 二进制。请先构建：cd ~/code/maclub-net/ipatool-go && go build -o ~/.local/bin/ipatool-go ."
        case .executionFailed(let code, let stderr):
            return "ipatool-go 执行失败 (退出码 \(code)): \(stderr)"
        case .authCodeRequired:
            return "需要两步验证码"
        case .loginFailed(let msg):
            return "登录失败: \(msg)"
        case .parseError(let msg):
            return "解析 ipatool-go 输出失败: \(msg)"
        case .keychainReadFailed(let msg):
            return "读取 Keychain 失败: \(msg)"
        }
    }
}

// MARK: - Auth Result

public enum GoAuthResult {
    case success(account: Account)
    case authCodeRequired
}

// MARK: - IPAToolGoBridge

/// ipatool-go 二进制桥接服务
///
/// 调用 ipatool-go 二进制处理需要 SAP 签名的操作（登录、SINF 复制），
/// 避免 Swift 端移植 Unicorn CPU 模拟器。
///
/// - 登录流程：调用 `ipatool-go auth login` → 解析 zerolog JSON → 从 macOS Keychain 读取账号数据
/// - Keychain 位置：service=`ipatool-auth.service`，key=`account:<email>`
public final class IPAToolGoBridge {

    public nonisolated(unsafe) static let shared = IPAToolGoBridge()

    /// ipatool-go Keychain service name（与 Go 端常量一致）
    private let goKeychainService = "ipatool-auth.service"

    /// 二进制路径缓存
    private var cachedBinaryPath: String?

    private init() {}

    // MARK: - Binary Location

    /// 查找 ipatool-go 二进制路径
    /// 搜索顺序：UserDefaults 自定义路径 → PATH → 常见安装位置
    public func locateBinary() throws -> String {
        if let cached = cachedBinaryPath, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        let candidates: [String] = [
            UserDefaults.standard.string(forKey: "ipatoolGoPath") ?? "",
            "/usr/local/bin/ipatool-go",
            "/opt/homebrew/bin/ipatool-go",
            NSHomeDirectory() + "/.local/bin/ipatool-go",
            NSHomeDirectory() + "/go/bin/ipatool-go",
        ].filter { !$0.isEmpty }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedBinaryPath = path
                return path
            }
        }

        // 尝试 `which ipatool-go`
        let whichTask = Process()
        whichTask.launchPath = "/usr/bin/which"
        whichTask.arguments = ["ipatool-go"]
        let pipe = Pipe()
        whichTask.standardOutput = pipe
        whichTask.standardError = Pipe()
        if (try? whichTask.run()) != nil {
            whichTask.waitUntilExit()
            if whichTask.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                    cachedBinaryPath = path
                    return path
                }
            }
        }

        throw GoBridgeError.binaryNotFound
    }

    // MARK: - Auth Login

    /// 调用 ipatool-go 进行 SAP 签名登录
    ///
    /// - Parameters:
    ///   - email: Apple ID 邮箱或手机号
    ///   - password: 密码
    ///   - authCode: 2FA 验证码（可选，首次登录为 nil）
    ///   - accountKey: 账号标识（用于多账号，默认为 email）
    /// - Returns: 成功返回账号信息，需要 2FA 返回 .authCodeRequired
    public func authLogin(
        email: String,
        password: String,
        authCode: String?,
        accountKey: String? = nil
    ) async throws -> GoAuthResult {
        let binary = try locateBinary()
        let key = (accountKey ?? email).lowercased().trimmingCharacters(in: .whitespaces)

        var args = [
            "auth", "login",
            "--email", email,
            "--password", password,
            "--non-interactive",
            "--format", "json",
            "--account", key,
        ]
        if let code = authCode, !code.isEmpty {
            args.append(contentsOf: ["--auth-code", code])
        }

        let result = try execute(binary: binary, arguments: args)

        // 退出码非 0 → 解析错误
        if result.exitCode != 0 {
            let errorMsg = parseErrorFromJSON(result.stdout) ?? result.stderr
            if errorMsg.contains("auth code is required") || errorMsg.lowercased().contains("2fa") {
                throw GoBridgeError.authCodeRequired
            }
            throw GoBridgeError.executionFailed(exitCode: result.exitCode, stderr: errorMsg)
        }

        // 退出码 0 → 解析 stdout JSON 判断成功还是需要 2FA
        let parsed = try parseAuthOutput(result.stdout)

        switch parsed {
        case .success:
            // 从 macOS Keychain 读取 Go 存储的账号数据
            let account = try readAccountFromKeychain(key: "account:\(key)")
            return .success(account: account)
        case .authCodeRequired:
            return .authCodeRequired
        }
    }

    // MARK: - Revoke

    /// 调用 ipatool-go 撤销凭据
    public func revoke(accountKey: String) async throws {
        let binary = try locateBinary()
        let key = accountKey.lowercased().trimmingCharacters(in: .whitespaces)
        let result = try execute(
            binary: binary,
            arguments: ["auth", "revoke", "--non-interactive", "--format", "json", "--account", key]
        )
        if result.exitCode != 0 {
            throw GoBridgeError.executionFailed(
                exitCode: result.exitCode,
                stderr: parseErrorFromJSON(result.stdout) ?? result.stderr
            )
        }
    }

    // MARK: - Process Execution

    private struct ExecutionResult {
        let stdout: Data
        let stderr: String
        let exitCode: Int32
    }

    private func execute(binary: String, arguments: [String]) throws -> ExecutionResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()
        } catch {
            throw GoBridgeError.executionFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        task.waitUntilExit()

        return ExecutionResult(
            stdout: stdoutData,
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: task.terminationStatus
        )
    }

    // MARK: - Output Parsing

    /// 解析 zerolog JSON 输出
    private enum ParsedAuthOutput {
        case success
        case authCodeRequired
    }

    private func parseAuthOutput(_ data: Data) throws -> ParsedAuthOutput {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw GoBridgeError.parseError("无输出")
        }

        // zerolog 每行一个 JSON 对象，逐行解析
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var found2FA = false
        var foundSuccess = false

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // 检查 authCodeRequired（非交互模式 2FA 需求时 Go 返回 nil error 但记录此标记）
            if json["authCodeRequired"] as? Bool == true {
                found2FA = true
                continue
            }

            // 检查 success
            if json["success"] as? Bool == true {
                foundSuccess = true
                continue
            }

            // 检查 error 级别
            if json["level"] as? String == "error" {
                let errorMsg = json["error"] as? String ?? "未知错误"
                throw GoBridgeError.loginFailed(errorMsg)
            }
        }

        if found2FA {
            return .authCodeRequired
        }
        if foundSuccess {
            return .success
        }

        throw GoBridgeError.parseError("无法从输出中确定登录状态: \(text)")
    }

    /// 从 JSON 输出中提取错误信息
    private func parseErrorFromJSON(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if json["level"] as? String == "error" {
                return json["error"] as? String
            }
        }
        return nil
    }

    // MARK: - Keychain Reading

    /// 从 macOS Keychain 读取 ipatool-go 存储的账号数据
    /// - service: `ipatool-auth.service`
    /// - key: `account:<email>`
    private func readAccountFromKeychain(key: String) throws -> Account {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: goKeychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw GoBridgeError.keychainReadFailed("Keychain 查询失败 (OSStatus: \(status))")
        }

        guard let data = result as? Data else {
            throw GoBridgeError.keychainReadFailed("Keychain 数据类型错误")
        }

        return try mapGoAccountToSwift(data)
    }

    /// 将 Go Account JSON 映射为 Swift Account
    private func mapGoAccountToSwift(_ data: Data) throws -> Account {
        let goAccount = try JSONDecoder().decode(GoAccount.self, from: data)

        let storeFront = goAccount.storeFront ?? ""
        let region = Storefront.countryCode(for: storeFront) ?? "US"

        return Account(
            email: goAccount.email,
            name: goAccount.name ?? "",
            region: region,
            passwordToken: goAccount.passwordToken ?? "",
            directoryServicesID: goAccount.directoryServicesIdentifier ?? "",
            storeFront: storeFront,
            password: goAccount.password ?? "",
            pod: goAccount.pod ?? ""
        )
    }

    // MARK: - SINF Replication

    /// 调用 ipatool-go 将 SINF 数据注入 IPA（DRM 应用必需）
    ///
    /// - Parameters:
    ///   - packagePath: IPA 文件路径
    ///   - sinfsData: 从下载响应提取的 SINF 数据（plist 编码的 `["sinfs": [...]]`）
    ///   - accountKey: 账号标识
    /// - Note: ipatool-go 需要添加 `replicate-sinf` 子命令
    public func replicateSinf(
        packagePath: String,
        sinfsData: Data,
        accountKey: String
    ) async throws {
        guard !sinfsData.isEmpty else { return }

        let binary = try locateBinary()
        let key = accountKey.lowercased().trimmingCharacters(in: .whitespaces)

        // 将 sinfs 写入临时 plist 文件
        let tmpDir = NSTemporaryDirectory()
        let sinfsPath = "\(tmpDir)ipatool-sinfs-\(UUID().uuidString).plist"
        defer { try? FileManager.default.removeItem(atPath: sinfsPath) }

        try sinfsData.write(to: URL(fileURLWithPath: sinfsPath))

        let result = try execute(
            binary: binary,
            arguments: [
                "replicate-sinf",
                "--package", packagePath,
                "--sinfs-file", sinfsPath,
                "--non-interactive",
                "--format", "json",
                "--account", key,
            ]
        )

        if result.exitCode != 0 {
            throw GoBridgeError.executionFailed(
                exitCode: result.exitCode,
                stderr: parseErrorFromJSON(result.stdout) ?? result.stderr
            )
        }
    }

    // MARK: - S7: List Purchases

    /// ipatool-go list-purchases 输出中的应用结构
    public struct PurchasedAppResult {
        public let appID: Int64
        public let bundleID: String
        public let name: String
        public let version: String
        public let purchaseDate: Date?
        public let platforms: [String]
    }

    /// 调用 ipatool-go 获取已购应用列表
    /// - Parameters:
    ///   - accountKey: 账号标识
    ///   - limit: 结果上限
    ///   - platform: 平台过滤（可选）
    public func listPurchases(
        accountKey: String,
        limit: Int = 50,
        platform: String? = nil
    ) async throws -> [PurchasedAppResult] {
        let binary = try locateBinary()
        let key = accountKey.lowercased().trimmingCharacters(in: .whitespaces)

        var args = [
            "list-purchases",
            "--non-interactive",
            "--format", "json",
            "--account", key,
            "--limit", String(limit),
        ]
        if let platform, !platform.isEmpty {
            args.append(contentsOf: ["--platform", platform])
        }

        let result = try execute(binary: binary, arguments: args)

        if result.exitCode != 0 {
            throw GoBridgeError.executionFailed(
                exitCode: result.exitCode,
                stderr: parseErrorFromJSON(result.stdout) ?? result.stderr
            )
        }

        return try parsePurchasesOutput(result.stdout)
    }

    /// 解析 ipatool-go list-purchases 的 JSON 输出
    private func parsePurchasesOutput(_ data: Data) throws -> [PurchasedAppResult] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        // 逐行解析 zerolog JSON，找最后一行包含结果数据的
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var results: [PurchasedAppResult] = []

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // 找到包含 owned_apps 的行
            if let apps = json["owned_apps"] as? [[String: Any]] {
                for app in apps {
                    let appID = (app["id"] as? Int64) ?? (app["id"] as? Int).map(Int64.init) ?? 0
                    let bundleID = app["bundle_id"] as? String ?? ""
                    let name = app["name"] as? String ?? ""
                    let version = app["version"] as? String ?? ""
                    let platforms = (app["platforms"] as? [String]) ?? []
                    let dateStr = app["purchase_date"] as? String
                    let purchaseDate = dateStr.flatMap { parseDate($0) }

                    results.append(PurchasedAppResult(
                        appID: appID, bundleID: bundleID, name: name,
                        version: version, purchaseDate: purchaseDate, platforms: platforms
                    ))
                }
                break
            }
        }

        return results
    }

    private func parseDate(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Keychain Listing (for loading all accounts)

    /// 列出 ipatool-go Keychain 中所有账号的 key
    public func listGoAccountKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: goKeychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            (item[kSecAttrAccount as String] as? String).flatMap { key in
                key.hasPrefix("account:") ? String(key.dropFirst("account:".count)) : nil
            }
        }
    }

    /// 从 Go Keychain 加载所有账号为 Swift Account
    public func loadAllAccounts() -> [Account] {
        listGoAccountKeys().compactMap { key in
            try? readAccountFromKeychain(key: "account:\(key)")
        }
    }
}
