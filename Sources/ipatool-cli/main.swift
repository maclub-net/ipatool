import ArgumentParser
import Foundation
import IPAToolKit

// MARK: - Output Format

enum OutputFormat: String, ExpressibleByArgument {
    case table, json
}

// MARK: - CLI Helpers

/// 选择账号：若指定 --account 则匹配，否则用 selectedAccount
@MainActor
func selectAccount(service: AppStoreService, accountEmail: String?) throws -> Account {
    if let email = accountEmail {
        guard let acc = service.accounts.first(where: { $0.email.lowercased() == email.lowercased() }) else {
            throw ValidationError("未找到账号: \(email)。已保存的账号: \(service.accounts.map(\.email).joined(separator: ", "))")
        }
        service.selectedAccount = acc
        return acc
    }
    guard let acc = service.selectedAccount ?? service.accounts.first else {
        throw ValidationError("未登录。请先运行: ipatool auth login")
    }
    return acc
}

/// 打印进度条到 stderr
func printProgress(_ progress: Double) {
    let width = 30
    let filled = Int(progress * Double(width))
    let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: max(0, width - filled))
    let percent = Int(progress * 100)
    FileHandle.standardError.write(Data("\r[\(bar)] \(percent)%".utf8))
    if progress >= 1.0 {
        FileHandle.standardError.write(Data("\n".utf8))
    }
}

/// 获取账号地区代码
func accountRegion(_ acc: Account) -> String {
    acc.countryCode ?? "US"
}

// MARK: - Root Command

@main
struct IPAToolCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ipatool",
        abstract: "App Store IPA 下载工具",
        version: "1.0.1",
        subcommands: [
            AuthCommand.self,
            SearchCommand.self,
            DownloadCommand.self,
            PurchaseCommand.self,
            ListVersionsCommand.self,
            GetVersionMetadataCommand.self,
            ListPurchasesCommand.self,
            MCPCommand.self,
        ]
    )
}

// MARK: - Auth Command

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "账号认证管理",
        subcommands: [AuthLogin.self, AuthLogout.self, AuthInfo.self]
    )

    struct AuthLogin: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "登录 Apple ID（通过 ipatool-go 完成 SAP 签名）"
        )

        @Option(name: .long, help: "Apple ID 邮箱或手机号")
        var email: String?

        @Option(name: .long, help: "密码")
        var password: String?

        @Option(name: .long, help: "两步验证码（首次登录时可留空，会提示输入）")
        var authCode: String?

        @Option(name: .long, help: "地区代码（如 CN, US, JP），默认 US")
        var region: String = "US"

        @Option(name: .long, help: "输出格式: table 或 json")
        var format: OutputFormat = .table

        @MainActor
        func run() async throws {
            let service = AppStoreService()
            service.logToStderr = (format == .json)
            await service.loadAccounts()

            // 交互式获取 email/password
            let userEmail = email ?? {
                print("Apple ID: ", terminator: "")
                return readLine() ?? ""
            }()

            let userPassword = password ?? {
                print("密码: ", terminator: "")
                return readLine() ?? ""
            }()

            guard !userEmail.isEmpty, !userPassword.isEmpty else {
                throw ValidationError("邮箱和密码不能为空")
            }

            var currentAuthCode = authCode ?? ""

            // 首次尝试登录
            do {
                try await service.login(email: userEmail, password: userPassword, authCode: currentAuthCode, region: region)
                printAuthSuccess(service: service, format: format)
            } catch let error as AppStoreError {
                if case .authCodeRequired = error {
                    // 提示输入验证码并重试
                    print("需要两步验证码，请输入验证码: ", terminator: "")
                    currentAuthCode = readLine() ?? ""
                    guard !currentAuthCode.isEmpty else {
                        throw ValidationError("验证码不能为空")
                    }
                    try await service.login(email: userEmail, password: userPassword, authCode: currentAuthCode, region: region)
                    printAuthSuccess(service: service, format: format)
                } else {
                    throw error
                }
            }
        }

        @MainActor
        private func printAuthSuccess(service: AppStoreService, format: OutputFormat) {
            switch format {
            case .json:
                let accountsData = service.accounts.map { acc in
                    [
                        "email": acc.email,
                        "name": acc.name,
                        "region": acc.region,
                        "region_display": acc.regionDisplayName,
                    ]
                }
                let json: [String: Any] = ["status": "success", "accounts": accountsData]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            case .table:
                print("登录成功")
                for acc in service.accounts {
                    print("  \(acc.email) | \(acc.name) | \(acc.regionDisplayName)")
                }
            }
        }
    }

    struct AuthLogout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "logout",
            abstract: "退出登录并删除凭据"
        )

        @Option(name: .long, help: "指定要退出的账号邮箱（不指定则退出当前选中账号）")
        var account: String?

        @Option(name: .long, help: "输出格式: table 或 json")
        var format: OutputFormat = .table

        @MainActor
        func run() async throws {
            let service = AppStoreService()
            service.logToStderr = (format == .json)
            await service.loadAccounts()

            let acc = try selectAccount(service: service, accountEmail: account)
            try await service.logout(account: acc)

            switch format {
            case .json:
                let json: [String: Any] = ["status": "success", "message": "已退出登录: \(acc.email)"]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            case .table:
                print("已退出登录: \(acc.email)")
            }
        }
    }

    struct AuthInfo: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "显示已登录的账号信息"
        )

        @Option(name: .long, help: "输出格式: table 或 json")
        var format: OutputFormat = .table

        @MainActor
        func run() async throws {
            let service = AppStoreService()
            service.logToStderr = (format == .json)
            await service.loadAccounts()

            if service.accounts.isEmpty {
                switch format {
                case .json:
                    print("{\"status\":\"empty\",\"accounts\":[]}")
                case .table:
                    print("尚未登录任何账号。请运行: ipatool auth login")
                }
                return
            }

            switch format {
            case .json:
                let accountsData = service.accounts.map { acc in
                    [
                        "email": acc.email,
                        "name": acc.name,
                        "region": acc.region,
                        "region_display": acc.regionDisplayName,
                        "is_selected": acc.id == service.selectedAccount?.id,
                    ] as [String: Any]
                }
                let json: [String: Any] = ["accounts": accountsData]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            case .table:
                print("已登录账号 (\(service.accounts.count) 个):")
                print(String(format: "%-30s %-20s %-12s %s", "邮箱", "名称", "地区", "选中"))
                print(String(repeating: "-", count: 75))
                for acc in service.accounts {
                    let selected = acc.id == service.selectedAccount?.id ? "*" : " "
                    print(String(format: "%-30s %-20s %-12s %s", acc.email, acc.name, acc.regionDisplayName, selected))
                }
            }
        }
    }
}

// MARK: - Search Command

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "搜索 App Store 应用"
    )

    @Argument(help: "搜索关键词")
    var term: String

    @Option(name: .long, help: "平台过滤（ios, macos, tvos, visionos, watchos）")
    var platform: String?

    @Option(name: .long, help: "结果数量上限（默认 25）")
    var limit: Int = 25

    @Option(name: .long, help: "指定账号（使用其地区搜索）")
    var account: String?

    @Option(name: .long, help: "输出格式: table 或 json")
    var format: OutputFormat = .table

    @MainActor
    func run() async throws {
        let service = AppStoreService()
        service.logToStderr = (format == .json)
        await service.loadAccounts()

        let acc = try selectAccount(service: service, accountEmail: account)
        service.selectedAccount = acc

        let resolvedPlatform = Platform.parse(platform)
        let results = try await service.search(term: term, limit: limit, platform: resolvedPlatform)

        if results.isEmpty {
            switch format {
            case .json:
                print("{\"results\":[]}")
            case .table:
                print("未找到匹配的应用")
            }
            return
        }

        switch format {
        case .json:
            let resultsData = results.map { app in
                [
                    "id": app.id,
                    "bundle_id": app.bundleID,
                    "name": app.name,
                    "version": app.version,
                    "price": app.price,
                    "developer": app.developer ?? "",
                    "icon_url": app.iconURL ?? "",
                    "is_free": app.isFree,
                    "platforms": app.platforms.map(\.rawValue),
                ] as [String: Any]
            }
            let json: [String: Any] = ["result_count": results.count, "results": resultsData]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        case .table:
            print("搜索 \"\(term)\" — 找到 \(results.count) 个结果:")
            print(String(format: "%-12s %-35s %-25s %-10s %-8s %-10s", "ID", "Bundle ID", "名称", "版本", "价格", "平台"))
            print(String(repeating: "-", count: 105))
            for app in results {
                let platforms = app.platforms.map(\.displayName).joined(separator: ",")
                print(String(format: "%-12d %-35.35s %-25.25s %-10s %-8s %-10s", app.id, app.bundleID, app.name, app.version, app.formattedPrice, platforms))
            }
        }
    }
}

// MARK: - Download Command

struct DownloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "下载应用 IPA（自动获取许可证）"
    )

    @Option(name: [.customShort("b"), .long], help: "应用 Bundle ID")
    var bundleID: String?

    @Option(name: .long, help: "应用 ID（track ID，可替代 bundle ID）")
    var appID: Int64?

    @Option(name: .long, help: "外部版本 ID（指定历史版本，S6 功能）")
    var externalVersionID: String?

    @Option(name: .long, help: "平台（ios, macos, tvos, visionos, watchos）")
    var platform: String?

    @Option(name: [.customShort("o"), .long], help: "输出目录（默认当前目录）")
    var outputDir: String?

    @Option(name: .long, help: "指定账号")
    var account: String?

    @Option(name: .long, help: "输出格式: table 或 json")
    var format: OutputFormat = .table

    @MainActor
    func run() async throws {
        guard bundleID != nil || appID != nil else {
            throw ValidationError("必须指定 --bundle-id (-b) 或 --app-id")
        }

        let service = AppStoreService()
        service.logToStderr = (format == .json)
        await service.loadAccounts()

        let acc = try selectAccount(service: service, accountEmail: account)
        service.selectedAccount = acc
        let region = accountRegion(acc)

        // 查找应用
        var app: AppInfo?
        if let appID = appID {
            app = try await service.lookupApp(appID: appID, region: region)
        } else if let bundleID = bundleID {
            app = try await service.lookupApp(bundleID: bundleID, region: region)
        }

        guard let appInfo = app else {
            throw ValidationError("未找到应用。请检查 Bundle ID / App ID 和地区设置。")
        }

        // 获取许可证
        do {
            try await service.purchase(app: appInfo)
        } catch let error as AppStoreError {
            if case .licenseAlreadyExists = error {
                // 许可证已存在，可继续下载
            } else if case .paidAppNotSupported = error {
                throw ValidationError("付费应用暂不支持，请使用免费应用")
            } else {
                throw error
            }
        }

        // 设置下载目录
        let outDir = outputDir ?? FileManager.default.currentDirectoryPath
        let outURL = URL(fileURLWithPath: outDir)

        let resolvedPlatform = Platform.parse(platform)

        // 下载（支持断点续传 + 版本指定 + 平台）
        let result = try await service.download(
            app: appInfo,
            externalVersionID: externalVersionID,
            platform: resolvedPlatform,
            outputDirectory: outURL
        ) { progress in
            printProgress(progress)
        }

        switch format {
        case .json:
            let json: [String: Any] = [
                "status": "success",
                "app_id": appInfo.id,
                "bundle_id": appInfo.bundleID,
                "name": appInfo.name,
                "version": result.version,
                "path": result.destinationPath.path,
                "region": result.region,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        case .table:
            print("下载完成: \(result.destinationPath.path)")
            print("  应用: \(appInfo.name) v\(result.version)")
            print("  地区: \(result.regionDisplayName)")
        }
    }
}

// MARK: - Purchase Command

struct PurchaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purchase",
        abstract: "获取应用许可证（不下载）"
    )

    @Option(name: [.customShort("b"), .long], help: "应用 Bundle ID")
    var bundleID: String?

    @Option(name: .long, help: "应用 ID")
    var appID: Int64?

    @Option(name: .long, help: "指定账号")
    var account: String?

    @Option(name: .long, help: "输出格式: table 或 json")
    var format: OutputFormat = .table

    @MainActor
    func run() async throws {
        guard bundleID != nil || appID != nil else {
            throw ValidationError("必须指定 --bundle-id (-b) 或 --app-id")
        }

        let service = AppStoreService()
        service.logToStderr = (format == .json)
        await service.loadAccounts()

        let acc = try selectAccount(service: service, accountEmail: account)
        service.selectedAccount = acc
        let region = accountRegion(acc)

        var app: AppInfo?
        if let appID = appID {
            app = try await service.lookupApp(appID: appID, region: region)
        } else if let bundleID = bundleID {
            app = try await service.lookupApp(bundleID: bundleID, region: region)
        }

        guard let appInfo = app else {
            throw ValidationError("未找到应用。")
        }

        do {
            try await service.purchase(app: appInfo)
            switch format {
            case .json:
                let json: [String: Any] = ["status": "success", "app_id": appInfo.id, "bundle_id": appInfo.bundleID, "name": appInfo.name]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            case .table:
                print("许可证获取成功: \(appInfo.name) (\(appInfo.bundleID))")
            }
        } catch let error as AppStoreError {
            if case .licenseAlreadyExists = error {
                switch format {
                case .json:
                    print("{\"status\":\"already_exists\"}")
                case .table:
                    print("许可证已存在: \(appInfo.name)")
                }
            } else {
                throw error
            }
        }
    }
}

// MARK: - List Versions Command (S6)

struct ListVersionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-versions",
        abstract: "列出应用的历史版本"
    )

    @Option(name: [.customShort("b"), .long], help: "应用 Bundle ID")
    var bundleID: String

    @Option(name: .long, help: "平台（ios, macos, tvos, visionos, watchos）")
    var platform: String?

    @Option(name: .long, help: "指定账号")
    var account: String?

    @Option(name: .long, help: "输出格式: table 或 json")
    var format: OutputFormat = .table

    @MainActor
    func run() async throws {
        let service = AppStoreService()
        service.logToStderr = (format == .json)
        await service.loadAccounts()

        let acc = try selectAccount(service: service, accountEmail: account)
        service.selectedAccount = acc
        let region = accountRegion(acc)

        guard let app = try await service.lookupApp(bundleID: bundleID, region: region) else {
            throw ValidationError("未找到应用: \(bundleID)")
        }

        let resolvedPlatform = Platform.parse(platform)
        let versions = try await service.listVersions(app: app, platform: resolvedPlatform)

        switch format {
        case .json:
            let versionsData = versions.map { v in
                ["external_version_id": v.externalVersionID, "is_latest": v.isLatest] as [String: Any]
            }
            let json: [String: Any] = ["count": versions.count, "versions": versionsData]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        case .table:
            print("找到 \(versions.count) 个历史版本:")
            for (i, v) in versions.enumerated() {
                let mark = v.isLatest ? " (最新)" : ""
                print("  \(i + 1). \(v.externalVersionID)\(mark)")
            }
        }
    }
}

// MARK: - Get Version Metadata Command (S6)

struct GetVersionMetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-version-metadata",
        abstract: "获取指定版本的元数据"
    )

    @Option(name: [.customShort("b"), .long], help: "应用 Bundle ID")
    var bundleID: String

    @Option(name: .long, help: "外部版本 ID")
    var externalVersionID: String

    @Option(name: .long, help: "平台（ios, macos, tvos, visionos, watchos）")
    var platform: String?

    @Option(name: .long, help: "指定账号")
    var account: String?

    @Option(name: .long, help: "输出格式: table 或 json")
    var format: OutputFormat = .table

    @MainActor
    func run() async throws {
        let service = AppStoreService()
        service.logToStderr = (format == .json)
        await service.loadAccounts()

        let acc = try selectAccount(service: service, accountEmail: account)
        service.selectedAccount = acc
        let region = accountRegion(acc)

        guard let app = try await service.lookupApp(bundleID: bundleID, region: region) else {
            throw ValidationError("未找到应用: \(bundleID)")
        }

        let resolvedPlatform = Platform.parse(platform)
        let metadata = try await service.getVersionMetadata(
            app: app, externalVersionID: externalVersionID, platform: resolvedPlatform
        )

        switch format {
        case .json:
            let json: [String: Any] = [
                "display_version": metadata.displayVersion,
                "release_date": metadata.releaseDate ?? "",
                "bundle_version": metadata.bundleVersion ?? "",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        case .table:
            print("版本元数据:")
            print("  显示版本: \(metadata.displayVersion)")
            if let date = metadata.releaseDate { print("  发布日期: \(date)") }
            if let bv = metadata.bundleVersion { print("  Bundle 版本: \(bv)") }
        }
    }
}

// MARK: - List Purchases Command (S7)

struct ListPurchasesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-purchases",
        abstract: "浏览已购应用"
    )

    @Option(name: .long, help: "平台过滤（ios, macos, tvos, visionos, watchos）")
    var platform: String?

    @Option(name: .long, help: "结果数量上限（默认 50）")
    var limit: Int = 50

    @Option(name: .long, help: "指定账号")
    var account: String?

    @Option(name: .long, help: "输出格式: table 或 json")
    var format: OutputFormat = .table

    @MainActor
    func run() async throws {
        let service = AppStoreService()
        service.logToStderr = (format == .json)
        await service.loadAccounts()

        let acc = try selectAccount(service: service, accountEmail: account)
        service.selectedAccount = acc

        let resolvedPlatform = Platform.parse(platform)
        let apps = try await service.listPurchases(limit: limit, platform: resolvedPlatform)

        switch format {
        case .json:
            let appsData = apps.map { app in
                [
                    "id": app.appID,
                    "bundle_id": app.bundleID,
                    "name": app.name,
                    "version": app.version,
                    "platforms": app.platforms.map(\.rawValue),
                ] as [String: Any]
            }
            let json: [String: Any] = ["count": apps.count, "purchases": appsData]
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        case .table:
            print("已购应用 (\(apps.count) 个):")
            print(String(format: "%-12s %-35s %-25s %-10s %s", "ID", "Bundle ID", "名称", "版本", "平台"))
            print(String(repeating: "-", count: 95))
            for app in apps {
                let platforms = app.platforms.map(\.displayName).joined(separator: ",")
                print(String(format: "%-12d %-35.35s %-25.25s %-10s %s", app.appID, app.bundleID, app.name, app.version, platforms))
            }
        }
    }
}

// MARK: - MCP Command (S-M2 占位)

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "MCP Server 管理",
        subcommands: [MCPServe.self]
    )

    struct MCPServe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "serve",
            abstract: "启动 MCP Server（stdio JSON-RPC），可注册到 Claude/Cursor 等客户端"
        )

        @MainActor
        func run() async throws {
            let server = MCPServer()
            try await server.run()
        }
    }
}
