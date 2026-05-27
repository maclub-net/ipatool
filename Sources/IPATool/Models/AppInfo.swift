import Foundation

/// 搜索响应
struct SearchResponse: Codable {
    let resultCount: Int
    let results: [AppInfo]
}

/// App Store 搜索结果中的 App 信息
struct AppInfo: Codable, Identifiable, Hashable {
    let id: Int64
    let bundleID: String
    let name: String
    let version: String
    let price: Double
    let iconURL: String?
    let developer: String?
    let description: String?
    let fileSizeBytes: String?
    let trackViewURL: URL?

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
    }

    var isFree: Bool { price == 0 }
    var formattedPrice: String { price == 0 ? "免费" : "$\(price)" }
}

/// iTunes Lookup API 返回的详细应用信息
struct AppDetail: Codable {
    let description: String?
    let screenshotUrls: [String]?
    let primaryGenreName: String?
    let genres: [String]?
    let trackContentRating: String?
    let averageUserRating: Double?
    let userRatingCount: Int?
    let releaseNotes: String?
    let releaseDate: String?
    let currentVersionReleaseDate: String?
    let minimumOsVersion: String?
    let sellerName: String?
    let languageCodesISO2A: [String]?
    let fileSizeBytes: String?

    var fileSizeFormatted: String {
        guard let sizeStr = fileSizeBytes, let bytes = Int64(sizeStr), bytes > 0 else { return "未知" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var ratingStars: String {
        guard let rating = averageUserRating, rating > 0 else { return "" }
        let full = Int(rating)
        let half = (rating - Double(full)) >= 0.5
        return String(repeating: "★", count: full) + (half ? "½" : "") + String(repeating: "☆", count: max(0, 5 - full - (half ? 1 : 0)))
    }
}

/// Lookup API 响应
struct LookupResponse: Codable {
    let resultCount: Int
    let results: [AppDetail]
}

/// 下载结果
struct DownloadResult: Identifiable {
    let id = UUID()
    let app: AppInfo
    let destinationPath: URL
    let version: String
    let bundleID: String
    let region: String
    let completedAt: Date

    var regionDisplayName: String { RegionOption.displayName(for: region) }

    init(app: AppInfo, destinationPath: URL, version: String, bundleID: String, region: String) {
        self.app = app
        self.destinationPath = destinationPath
        self.version = version
        self.bundleID = bundleID
        self.region = region
        self.completedAt = Date()
    }
}

/// 下载队列任务
struct DownloadQueueItem: Identifiable {
    let id = UUID()
    let app: AppInfo
    let account: Account
    let addedAt: Date
    var status: DownloadStatus = .waiting
    var progress: Double = 0
    var error: String?

    enum DownloadStatus {
        case waiting
        case purchasing
        case downloading
        case processing
        case completed
        case failed
        case cancelled
    }

    var statusText: String {
        switch status {
        case .waiting: return "等待中"
        case .purchasing: return "获取许可..."
        case .downloading: return "下载中..."
        case .processing: return "处理中..."
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

/// 日志条目
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let type: LogType

    enum LogType { case info, warning, error, success }
}