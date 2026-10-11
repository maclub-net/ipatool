import Foundation

/// 封装打包进 app bundle 的 ipatool 二进制调用，统一 JSON 输出解析。
/// 所有 App Store 逻辑由二进制接管，Swift 侧仅负责 UI 与参数传递。
final class IPAToolCLI: Sendable {

    static let shared = IPAToolCLI()

    /// 二进制路径（app bundle Resources 目录）
    private var executableURL: URL? {
        Bundle.main.url(forResource: "ipatool", withExtension: nil)
    }

    /// 二进制是否可执行（首次启动时校验）
    let isAvailable: Bool

    private init() {
        if let url = Bundle.main.url(forResource: "ipatool", withExtension: nil) {
            self.isAvailable = FileManager.default.isExecutableFile(atPath: url.path)
        } else {
            self.isAvailable = false
        }
    }

    // MARK: - 核心调用

    /// 执行 ipatool 命令，返回解析后的 JSON 字典。
    /// - Parameters:
    ///   - args: 命令参数（不含二进制路径），如 `["auth", "list", "--format", "json"]`
    ///   - account: 指定账号（追加 `--account` 参数）
    func run(_ args: [String], account: String? = nil) async throws -> [String: Any] {
        guard let url = executableURL else {
            throw CLIError.binaryNotFound
        }

        var fullArgs = args
        // 强制 JSON 输出 + 非交互模式
        if !fullArgs.contains("--format") {
            fullArgs.append("--format"); fullArgs.append("json")
        }
        if !fullArgs.contains("--non-interactive") {
            fullArgs.append("--non-interactive")
        }
        if let account = account, !account.isEmpty {
            fullArgs.append("--account"); fullArgs.append(account)
        }

        let process = Process()
        process.executableURL = url
        process.arguments = fullArgs

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw CLIError.executionFailed(error.localizedDescription)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: stdoutData, encoding: .utf8) ?? ""
        let errOutput = String(data: stderrData, encoding: .utf8) ?? ""

        // 取最后一行 JSON（日志可能有多行）
        let jsonLine = output.split(separator: "\n")
            .map(String.init)
            .last(where: { $0.hasPrefix("{") }) ?? output

        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let msg = errOutput.isEmpty ? output : errOutput
            throw CLIError.parseFailure(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 检查 success 字段
        if let success = json["success"] as? Bool, !success {
            let errorMsg = (json["error"] as? String) ?? "unknown error"
            throw CLIError.commandFailed(errorMsg)
        }

        if process.terminationStatus != 0 {
            let errorMsg = (json["error"] as? String) ?? errOutput
            throw CLIError.commandFailed(errorMsg.isEmpty ? "exit code \(process.terminationStatus)" : errorMsg)
        }

        return json
    }

    // MARK: - 便捷方法

    /// auth list — 返回所有账号
    func listAccounts() async throws -> [String: Any] {
        try await run(["auth", "list"])
    }

    /// auth login
    func login(email: String, password: String, authCode: String?) async throws -> [String: Any] {
        var args = ["auth", "login", "--email", email, "--password", password]
        if let code = authCode, !code.isEmpty {
            args.append(contentsOf: ["--auth-code", code])
        }
        return try await run(args)
    }

    /// auth use <account>
    func useAccount(_ account: String) async throws -> [String: Any] {
        try await run(["auth", "use", account])
    }

    /// auth revoke
    func revoke(account: String) async throws -> [String: Any] {
        try await run(["auth", "revoke"], account: account)
    }

    /// search
    func search(term: String, limit: Int = 25, platform: String? = nil, account: String) async throws -> [String: Any] {
        var args = ["search", term, "--limit", "\(limit)"]
        if let p = platform, !p.isEmpty {
            args.append(contentsOf: ["--platform", p])
        }
        return try await run(args, account: account)
    }

    /// list-versions
    func listVersions(appID: Int64, account: String) async throws -> [String: Any] {
        try await run(["list-versions", "--app-id", "\(appID)"], account: account)
    }

    /// purchase
    func purchase(appID: Int64, account: String) async throws -> [String: Any] {
        try await run(["purchase", "--app-id", "\(appID)"], account: account)
    }

    /// download — 同步等待完成，返回 output 路径
    func download(appID: Int64, output: String, externalVersionID: String? = nil,
                  platform: String? = nil, account: String) async throws -> [String: Any] {
        var args = ["download", "--app-id", "\(appID)", "--output", output, "--purchase"]
        if let vid = externalVersionID, !vid.isEmpty {
            args.append(contentsOf: ["--external-version-id", vid])
        }
        if let p = platform, !p.isEmpty {
            args.append(contentsOf: ["--platform", p])
        }
        return try await run(args, account: account)
    }

    // MARK: - Errors

    enum CLIError: Error, LocalizedError {
        case binaryNotFound
        case executionFailed(String)
        case parseFailure(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "ipatool 二进制未找到"
            case .executionFailed(let m): return "执行失败: \(m)"
            case .parseFailure(let m): return "输出解析失败: \(m)"
            case .commandFailed(let m): return m
            }
        }
    }
}
