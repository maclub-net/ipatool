import Foundation

/// 搜索响应
public struct SearchResponse: Codable {
    public let resultCount: Int
    public let results: [AppInfo]
}

/// App Store 搜索结果中的 App 信息
public struct AppInfo: Codable, Identifiable, Hashable {
    public let id: Int64
    public let bundleID: String
    public let name: String
    public let version: String
    public let price: Double
    public let iconURL: String?
    public let developer: String?
    public let description: String?
    public let fileSizeBytes: String?
    public let trackViewURL: URL?
    public let kind: String?
    public let supportedDevices: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "trackId"
        case bundleID = "bundleId"
        case name = "trackName"
        case version
        case price
        case iconURL = "artworkUrl512"
        case developer = "artistName"
        case description
        case fileSizeBytes
        case trackViewURL = "trackViewUrl"
        case kind
        case supportedDevices
    }

    public var isFree: Bool { price == 0 }
    public var formattedPrice: String { price == 0 ? "免费" : "$\(price)" }

    /// 从 kind 和 supportedDevices 推断支持的平台
    public var platforms: [Platform] {
        var result = Platform.fromSupportedDevices(supportedDevices ?? [])
        if kind == "mac-software" && !result.contains(.macos) {
            result.append(.macos)
        }
        return result.isEmpty ? [.iphone] : result
    }

    /// 从原始 JSON 解码时附带平台推断（用于搜索结果）
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        price = try container.decodeIfPresent(Double.self, forKey: .price) ?? 0
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        developer = try container.decodeIfPresent(String.self, forKey: .developer)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        fileSizeBytes = try container.decodeIfPresent(String.self, forKey: .fileSizeBytes)
        trackViewURL = try container.decodeIfPresent(URL.self, forKey: .trackViewURL)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        supportedDevices = try container.decodeIfPresent([String].self, forKey: .supportedDevices)
    }

    /// 直接构造（用于 listPurchases 等非搜索 API）
    public init(id: Int64, bundleID: String, name: String, version: String, price: Double = 0,
                iconURL: String? = nil, developer: String? = nil, description: String? = nil,
                fileSizeBytes: String? = nil, trackViewURL: URL? = nil,
                kind: String? = nil, supportedDevices: [String]? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.price = price
        self.iconURL = iconURL
        self.developer = developer
        self.description = description
        self.fileSizeBytes = fileSizeBytes
        self.trackViewURL = trackViewURL
        self.kind = kind
        self.supportedDevices = supportedDevices
    }
}

/// iTunes Lookup API 返回的详细应用信息
public struct AppDetail: Codable {
    public let description: String?
    public let screenshotUrls: [String]?
    public let primaryGenreName: String?
    public let genres: [String]?
    public let trackContentRating: String?
    public let averageUserRating: Double?
    public let userRatingCount: Int?
    public let releaseNotes: String?
    public let releaseDate: String?
    public let currentVersionReleaseDate: String?
    public let minimumOsVersion: String?
    public let sellerName: String?
    public let languageCodesISO2A: [String]?
    public let fileSizeBytes: String?

    public var fileSizeFormatted: String {
        guard let sizeStr = fileSizeBytes, let bytes = Int64(sizeStr), bytes > 0 else { return "未知" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public var ratingStars: String {
        guard let rating = averageUserRating, rating > 0 else { return "" }
        let full = Int(rating)
        let half = (rating - Double(full)) >= 0.5
        return String(repeating: "★", count: full) + (half ? "½" : "") + String(repeating: "☆", count: max(0, 5 - full - (half ? 1 : 0)))
    }
}

/// Lookup API 响应
public struct LookupResponse: Codable {
    public let resultCount: Int
    public let results: [AppDetail]
}

/// 下载结果
public struct DownloadResult: Identifiable {
    public let id = UUID()
    public let app: AppInfo
    public let destinationPath: URL
    public let version: String
    public let bundleID: String
    public let region: String
    public let completedAt: Date

    public var regionDisplayName: String { RegionOption.displayName(for: region) }

    public init(app: AppInfo, destinationPath: URL, version: String, bundleID: String, region: String) {
        self.app = app
        self.destinationPath = destinationPath
        self.version = version
        self.bundleID = bundleID
        self.region = region
        self.completedAt = Date()
    }
}

/// 历史版本信息
public struct AppVersion: Identifiable, Hashable {
    public let id = UUID()
    public let externalVersionID: String
    public let isLatest: Bool

    public init(externalVersionID: String, isLatest: Bool = false) {
        self.externalVersionID = externalVersionID
        self.isLatest = isLatest
    }
}

/// 版本元数据
public struct VersionMetadata {
    public let displayVersion: String
    public let releaseDate: String?
    public let bundleVersion: String?

    public init(displayVersion: String, releaseDate: String? = nil, bundleVersion: String? = nil) {
        self.displayVersion = displayVersion
        self.releaseDate = releaseDate
        self.bundleVersion = bundleVersion
    }
}

/// 已购应用信息
public struct PurchasedApp: Identifiable, Hashable {
    public let id = UUID()
    public let appID: Int64
    public let bundleID: String
    public let name: String
    public let version: String
    public let purchaseDate: Date?
    public let platforms: [Platform]

    public init(appID: Int64, bundleID: String, name: String, version: String,
                purchaseDate: Date? = nil, platforms: [Platform] = []) {
        self.appID = appID
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.purchaseDate = purchaseDate
        self.platforms = platforms
    }

    /// 转换为 AppInfo（用于下载）
    public var asAppInfo: AppInfo {
        AppInfo(id: appID, bundleID: bundleID, name: name, version: version)
    }
}

/// 下载队列任务
public struct DownloadQueueItem: Identifiable {
    public let id = UUID()
    public let app: AppInfo
    public let account: Account
    public let addedAt: Date
    public var status: DownloadStatus = .waiting
    public var progress: Double = 0
    public var error: String?
    public var downloadedBytes: Int64 = 0
    public var externalVersionID: String?

    public enum DownloadStatus {
        case waiting
        case purchasing
        case downloading
        case processing
        case completed
        case failed
        case cancelled
        case paused
    }

    public var statusText: String {
        switch status {
        case .waiting: return "等待中"
        case .purchasing: return "获取许可..."
        case .downloading: return "下载中..."
        case .processing: return "处理中..."
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .paused: return "已暂停"
        }
    }
}

/// 日志条目
public struct LogEntry: Identifiable {
    public let id = UUID()
    public let timestamp = Date()
    public let message: String
    public let type: LogType

    public enum LogType { case info, warning, error, success }
}
