import Foundation
import IPAToolKit

// MARK: - MCP Error

enum MCPError: Error, CustomStringConvertible {
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)

    var code: Int {
        switch self {
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .internalError: return -32603
        }
    }

    var description: String {
        switch self {
        case .methodNotFound(let m): return "Method not found: \(m)"
        case .invalidParams(let m): return "Invalid params: \(m)"
        case .internalError(let m): return m
        }
    }
}

// MARK: - MCP Server

/// 手写 MCP stdio JSON-RPC Server
///
/// 协议子集（MCP 2025-06-18）：
/// - initialize / notifications/initialized
/// - tools/list / tools/call
/// - notifications/progress（下载进度推送）
///
/// 零外部依赖，纯 Foundation JSONSerialization 实现。
@MainActor
final class MCPServer {

    private let service: AppStoreService

    init() {
        service = AppStoreService()
        service.logToStderr = true
    }

    // MARK: - Run

    func run() async throws {
        await service.loadAccounts()

        while let line = readLine() {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendError(id: NSNull(), code: -32700, message: "Parse error")
                continue
            }

            guard let method = json["method"] as? String else {
                if let id = json["id"] {
                    sendError(id: id, code: -32600, message: "Invalid request: missing method")
                }
                continue
            }

            let id = json["id"]
            let params = (json["params"] as? [String: Any]) ?? [:]

            do {
                let result = try await handle(method: method, params: params)
                if id != nil {
                    sendResponse(id: id!, result: result)
                }
            } catch let error as MCPError {
                if id != nil {
                    sendError(id: id!, code: error.code, message: error.description)
                }
            } catch {
                if id != nil {
                    sendError(id: id!, code: -32603, message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Message Dispatch

    private func handle(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            return handleInitialize()
        case "notifications/initialized":
            return [:]
        case "tools/list":
            return handleToolsList()
        case "tools/call":
            return try await handleToolsCall(params: params)
        case "ping":
            return [:]
        default:
            throw MCPError.methodNotFound(method)
        }
    }

    // MARK: - Initialize

    private func handleInitialize() -> [String: Any] {
        [
            "protocolVersion": "2025-06-18",
            "capabilities": [
                "tools": [
                    "listChanged": false,
                ],
            ],
            "serverInfo": [
                "name": "ipatool",
                "version": "1.0.1",
            ],
        ]
    }

    // MARK: - Tools List

    private func handleToolsList() -> [String: Any] {
        ["tools": toolDefinitions]
    }

    private var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "search",
                "description": "Search for apps on the App Store by keyword",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "term": ["type": "string", "description": "Search keyword"],
                        "limit": ["type": "integer", "description": "Max results (default 25)"],
                        "platform": ["type": "string", "description": "Platform filter: ios, macos, tvos, visionos, watchos"],
                    ],
                    "required": ["term"],
                ] as [String: Any],
            ],
            [
                "name": "download",
                "description": "Download an app IPA file (auto-purchases license if needed). Progress is reported via notifications.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App Bundle ID (e.g. com.example.app)"],
                        "app_id": ["type": "integer", "description": "App track ID (alternative to bundle_id)"],
                        "output_dir": ["type": "string", "description": "Output directory (default: current directory)"],
                        "external_version_id": ["type": "string", "description": "Specific version to download (from list-versions)"],
                        "platform": ["type": "string", "description": "Platform: ios, macos, tvos, visionos, watchos"],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "purchase",
                "description": "Acquire a license for an app (without downloading)",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App Bundle ID"],
                        "app_id": ["type": "integer", "description": "App track ID"],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "list-versions",
                "description": "List available historical versions of an app",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App Bundle ID"],
                        "platform": ["type": "string", "description": "Platform: ios, macos, tvos, visionos, watchos"],
                    ],
                    "required": ["bundle_id"],
                ] as [String: Any],
            ],
            [
                "name": "get-version-metadata",
                "description": "Get metadata for a specific app version",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "bundle_id": ["type": "string", "description": "App Bundle ID"],
                        "external_version_id": ["type": "string", "description": "External version ID"],
                        "platform": ["type": "string", "description": "Platform: ios, macos, tvos, visionos, watchos"],
                    ],
                    "required": ["bundle_id", "external_version_id"],
                ] as [String: Any],
            ],
            [
                "name": "list-purchases",
                "description": "List purchased apps for the logged-in account",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max results (default 50)"],
                        "platform": ["type": "string", "description": "Platform filter: ios, macos, tvos, visionos, watchos"],
                    ],
                ] as [String: Any],
            ],
        ]
    }

    // MARK: - Tools Call

    private func handleToolsCall(params: [String: Any]) async throws -> [String: Any] {
        guard let name = params["name"] as? String else {
            throw MCPError.invalidParams("Missing tool name")
        }
        let args = (params["arguments"] as? [String: Any]) ?? [:]
        let progressToken = (params["_meta"] as? [String: Any])?["progressToken"]

        switch name {
        case "search":
            return try await toolSearch(args: args)
        case "download":
            return try await toolDownload(args: args, progressToken: progressToken)
        case "purchase":
            return try await toolPurchase(args: args)
        case "list-versions":
            return try await toolListVersions(args: args)
        case "get-version-metadata":
            return try await toolGetVersionMetadata(args: args)
        case "list-purchases":
            return try await toolListPurchases(args: args)
        default:
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
    }

    // MARK: - Tool: Search

    private func toolSearch(args: [String: Any]) async throws -> [String: Any] {
        guard let term = args["term"] as? String else {
            throw MCPError.invalidParams("Missing 'term' parameter")
        }
        let limit = args["limit"] as? Int ?? 25
        let platform = Platform.parse(args["platform"] as? String)

        let results = try await service.search(term: term, limit: limit, platform: platform)

        let resultsArray = results.map { app -> [String: Any] in
            [
                "id": app.id,
                "bundle_id": app.bundleID,
                "name": app.name,
                "version": app.version,
                "price": app.price,
                "is_free": app.isFree,
                "developer": app.developer ?? "",
                "icon_url": app.iconURL ?? "",
                "platforms": app.platforms.map(\.rawValue),
            ]
        }

        let text = results.enumerated().map { (i, app) in
            "\(i + 1). \(app.name) v\(app.version) (\(app.bundleID)) — \(app.formattedPrice)"
        }.joined(separator: "\n")

        return [
            "content": [
                ["type": "text", "text": text.isEmpty ? "No results found" : text] as [String: Any],
            ],
            "structured": ["result_count": results.count, "results": resultsArray] as [String: Any],
        ]
    }

    // MARK: - Tool: Download

    private func toolDownload(args: [String: Any], progressToken: Any?) async throws -> [String: Any] {
        let bundleID = args["bundle_id"] as? String
        let appID = args["app_id"] as? Int64 ?? (args["app_id"] as? Int).map(Int64.init)
        let outputDir = args["output_dir"] as? String
        let externalVersionID = args["external_version_id"] as? String
        let platform = Platform.parse(args["platform"] as? String)

        guard bundleID != nil || appID != nil else {
            throw MCPError.invalidParams("Must provide bundle_id or app_id")
        }

        guard let acc = service.selectedAccount ?? service.accounts.first else {
            throw MCPError.invalidParams("No account logged in. Please login first via: ipatool auth login")
        }
        service.selectedAccount = acc
        let region = acc.countryCode ?? "US"

        var app: AppInfo?
        if let appID = appID {
            app = try await service.lookupApp(appID: appID, region: region)
        } else if let bundleID = bundleID {
            app = try await service.lookupApp(bundleID: bundleID, region: region)
        }

        guard let appInfo = app else {
            throw MCPError.invalidParams("App not found")
        }

        // Purchase license
        do {
            try await service.purchase(app: appInfo)
        } catch let error as AppStoreError {
            if case .licenseAlreadyExists = error {
                // OK, continue to download
            } else {
                throw MCPError.internalError(error.localizedDescription)
            }
        }

        // Download
        let outDir = outputDir ?? FileManager.default.currentDirectoryPath
        let outURL = URL(fileURLWithPath: outDir)

        let result = try await service.download(
            app: appInfo, externalVersionID: externalVersionID, platform: platform,
            outputDirectory: outURL
        ) { [progressToken, self] progress in
            if let token = progressToken {
                self.sendProgress(token: token, progress: progress, message: "Downloading \(appInfo.name)...")
            }
        }

        let text = "Download complete: \(result.destinationPath.lastPathComponent)\nApp: \(appInfo.name) v\(result.version)\nRegion: \(result.regionDisplayName)"

        return [
            "content": [
                ["type": "text", "text": text] as [String: Any],
            ],
            "structured": [
                "bundle_id": appInfo.bundleID,
                "app_id": appInfo.id,
                "version": result.version,
                "path": result.destinationPath.path,
                "region": result.region,
            ] as [String: Any],
        ]
    }

    // MARK: - Tool: Purchase

    private func toolPurchase(args: [String: Any]) async throws -> [String: Any] {
        let bundleID = args["bundle_id"] as? String
        let appID = args["app_id"] as? Int64 ?? (args["app_id"] as? Int).map(Int64.init)

        guard bundleID != nil || appID != nil else {
            throw MCPError.invalidParams("Must provide bundle_id or app_id")
        }

        guard let acc = service.selectedAccount ?? service.accounts.first else {
            throw MCPError.invalidParams("No account logged in")
        }
        service.selectedAccount = acc
        let region = acc.countryCode ?? "US"

        var app: AppInfo?
        if let appID = appID {
            app = try await service.lookupApp(appID: appID, region: region)
        } else if let bundleID = bundleID {
            app = try await service.lookupApp(bundleID: bundleID, region: region)
        }

        guard let appInfo = app else {
            throw MCPError.invalidParams("App not found")
        }

        do {
            try await service.purchase(app: appInfo)
            let text = "License acquired: \(appInfo.name) (\(appInfo.bundleID))"
            return [
                "content": [["type": "text", "text": text] as [String: Any]],
                "structured": ["status": "success", "app_id": appInfo.id, "bundle_id": appInfo.bundleID] as [String: Any],
            ]
        } catch let error as AppStoreError {
            if case .licenseAlreadyExists = error {
                let text = "License already exists: \(appInfo.name)"
                return [
                    "content": [["type": "text", "text": text] as [String: Any]],
                    "structured": ["status": "already_exists", "app_id": appInfo.id] as [String: Any],
                ]
            }
            throw MCPError.internalError(error.localizedDescription)
        }
    }

    // MARK: - Tool: List Versions (S6)

    private func toolListVersions(args: [String: Any]) async throws -> [String: Any] {
        guard let bundleID = args["bundle_id"] as? String else {
            throw MCPError.invalidParams("Missing 'bundle_id' parameter")
        }

        guard let acc = service.selectedAccount ?? service.accounts.first else {
            throw MCPError.invalidParams("No account logged in")
        }
        service.selectedAccount = acc
        let region = acc.countryCode ?? "US"

        guard let app = try await service.lookupApp(bundleID: bundleID, region: region) else {
            throw MCPError.invalidParams("App not found")
        }

        let platform = Platform.parse(args["platform"] as? String)
        let versions = try await service.listVersions(app: app, platform: platform)

        let versionsArray = versions.map { v -> [String: Any] in
            ["external_version_id": v.externalVersionID, "is_latest": v.isLatest]
        }

        let text = versions.enumerated().map { (i, v) in
            "\(i + 1). \(v.externalVersionID)\(v.isLatest ? " (latest)" : "")"
        }.joined(separator: "\n")

        return [
            "content": [
                ["type": "text", "text": text.isEmpty ? "No versions found" : text] as [String: Any],
            ],
            "structured": ["count": versions.count, "versions": versionsArray] as [String: Any],
        ]
    }

    // MARK: - Tool: Get Version Metadata (S6)

    private func toolGetVersionMetadata(args: [String: Any]) async throws -> [String: Any] {
        guard let bundleID = args["bundle_id"] as? String,
              let externalVersionID = args["external_version_id"] as? String else {
            throw MCPError.invalidParams("Missing 'bundle_id' or 'external_version_id' parameter")
        }

        guard let acc = service.selectedAccount ?? service.accounts.first else {
            throw MCPError.invalidParams("No account logged in")
        }
        service.selectedAccount = acc
        let region = acc.countryCode ?? "US"

        guard let app = try await service.lookupApp(bundleID: bundleID, region: region) else {
            throw MCPError.invalidParams("App not found")
        }

        let platform = Platform.parse(args["platform"] as? String)
        let metadata = try await service.getVersionMetadata(
            app: app, externalVersionID: externalVersionID, platform: platform
        )

        let text = "Version: \(metadata.displayVersion)\nRelease date: \(metadata.releaseDate ?? "N/A")"

        return [
            "content": [
                ["type": "text", "text": text] as [String: Any],
            ],
            "structured": [
                "display_version": metadata.displayVersion,
                "release_date": metadata.releaseDate ?? "",
                "bundle_version": metadata.bundleVersion ?? "",
            ] as [String: Any],
        ]
    }

    // MARK: - Tool: List Purchases (S7)

    private func toolListPurchases(args: [String: Any]) async throws -> [String: Any] {
        let limit = args["limit"] as? Int ?? 50
        let platform = Platform.parse(args["platform"] as? String)

        guard let acc = service.selectedAccount ?? service.accounts.first else {
            throw MCPError.invalidParams("No account logged in")
        }
        service.selectedAccount = acc

        let apps = try await service.listPurchases(limit: limit, platform: platform)

        let appsArray = apps.map { app -> [String: Any] in
            [
                "id": app.appID,
                "bundle_id": app.bundleID,
                "name": app.name,
                "version": app.version,
                "platforms": app.platforms.map(\.rawValue),
            ]
        }

        let text = apps.enumerated().map { (i, app) in
            "\(i + 1). \(app.name) v\(app.version) (\(app.bundleID))"
        }.joined(separator: "\n")

        return [
            "content": [
                ["type": "text", "text": text.isEmpty ? "No purchases found" : text] as [String: Any],
            ],
            "structured": ["count": apps.count, "purchases": appsArray] as [String: Any],
        ]
    }

    // MARK: - JSON-RPC I/O

    private func sendResponse(id: Any, result: [String: Any]) {
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        send(msg)
    }

    private func sendError(id: Any, code: Int, message: String) {
        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message] as [String: Any],
        ]
        send(msg)
    }

    private func sendProgress(token: Any, progress: Double, message: String) {
        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/progress",
            "params": [
                "progressToken": token,
                "progress": progress,
                "message": message,
            ] as [String: Any],
        ]
        send(msg)
    }

    private func send(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              var str = String(data: data, encoding: .utf8) else { return }
        str += "\n"
        FileHandle.standardOutput.write(Data(str.utf8))
    }
}
