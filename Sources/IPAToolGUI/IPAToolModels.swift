import Foundation
import SwiftUI
import Security
import IPAToolCore

// MARK: - Brand Colors
// 取色自应用 Logo（ICON.png）：主色为暖橙色，辅色为更深的橙色，用于渐变与强调。

extension Color {
    /// 品牌主色（Logo 中的浅暖橙）
    static let brandPrimary = Color(red: 0xF0 / 255, green: 0xA0 / 255, blue: 0x60 / 255)
    /// 品牌辅色（Logo 中的深橙）
    static let brandSecondary = Color(red: 0xE0 / 255, green: 0x80 / 255, blue: 0x40 / 255)

    /// 品牌渐变：主色 → 辅色
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [.brandPrimary, .brandSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 卡片/输入框背景色（适配深色模式）
    static var nsBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }
}

// MARK: - App Sections

enum AppSection: String, CaseIterable, Identifiable {
    case search
    case purchased
    case library
    case accounts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return String(localized: "Search")
        case .purchased: return String(localized: "Purchased")
        case .library: return String(localized: "Library")
        case .accounts: return String(localized: "Accounts")
        case .settings: return String(localized: "Settings")
        }
    }

    var subtitle: String {
        switch self {
        case .search: return String(localized: "Find and download apps")
        case .purchased: return String(localized: "Apps owned by the current account")
        case .library: return String(localized: "Manage downloaded IPAs")
        case .accounts: return String(localized: "Manage Apple IDs")
        case .settings: return String(localized: "Paths and preferences")
        }
    }

    var systemImage: String {
        switch self {
        case .search: return "magnifyingglass"
        case .purchased: return "bag.fill"
        case .library: return "square.grid.2x2.fill"
        case .accounts: return "person.2.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

// MARK: - App Version

/// 应用版本信息：externalVersionID 是 App Store 内部版本标识符，version 是用户可见的版本号
struct AppVersion: Identifiable, Equatable {
    let id = UUID()
    let externalVersionID: String
    var version: String?      // 例如 "1.2.3"，可能为 nil
    var releaseDate: String?  // ISO 日期字符串，可能为 nil
    var isLatest: Bool

    /// 显示名称：优先版本号，其次外部标识符
    var displayName: String {
        version ?? externalVersionID
    }

    /// 格式化后的发布日期
    var formattedDate: String? {
        guard let releaseDate = releaseDate, !releaseDate.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: releaseDate) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: releaseDate) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: date)
        }
        return releaseDate
    }
}

// MARK: - Download Task

enum DownloadStatus: String, Codable {
    case pending = "等待中"
    case downloading = "下载中"
    case completed = "已完成"
    case failed = "失败"

    /// 用于 UI 显示的本地化名称（rawValue 保持不变以保证持久化数据兼容）
    var displayName: String {
        switch self {
        case .pending: return String(localized: "Pending")
        case .downloading: return String(localized: "Downloading")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        }
    }
}

struct DownloadTask: Identifiable, Equatable, Codable {
    let id: UUID
    let app: AppStoreApp
    var status: DownloadStatus = .pending
    var progress: Double = 0
    var outputURL: URL?
    var errorMessage: String?
    var startedAt: Date?
    var completedAt: Date?

    init(app: AppStoreApp, status: DownloadStatus = .pending) {
        self.id = UUID()
        self.app = app
        self.status = status
    }
}

// MARK: - Download Removal Confirmation

/// 移除下载记录时的确认请求，用于驱动「是否同时删除文件」的二次确认弹窗。
enum DownloadRemovalRequest: Identifiable {
    case single(DownloadTask)
    case clearCompleted([DownloadTask])

    var id: String {
        switch self {
        case .single(let task): return "single-\(task.id.uuidString)"
        case .clearCompleted(let tasks): return "clear-\(tasks.map { $0.id.uuidString }.joined(separator: ","))"
        }
    }

    /// 需要确认的任务列表
    var tasks: [DownloadTask] {
        switch self {
        case .single(let task): return [task]
        case .clearCompleted(let tasks): return tasks
        }
    }

    /// 是否存在可删除的本地文件
    var hasDeletableFiles: Bool {
        tasks.contains { $0.outputURL != nil }
    }

    var title: String {
        switch self {
        case .single: return String(localized: "Remove this download record?")
        case .clearCompleted: return String(localized: "Clear all completed download records?")
        }
    }
}

// MARK: - Account

struct AppAccount: Identifiable, Equatable, Codable {
    let id: UUID
    let email: String
    let dsid: String
    let name: String
    let region: String
    var isActive: Bool
    let createdAt: Date
    let storeFront: String
    var passwordToken: String
    let pod: String
    /// 明文密码，存储在 Keychain 中，用于 token 失效时自动重新登录
    let password: String
    /// token 是否失效，需要用户重新登录（通常是自动重登遇到 2FA）
    var needsReauth: Bool

    init(email: String, dsid: String, name: String, region: String, isActive: Bool, createdAt: Date,
         storeFront: String = "", passwordToken: String = "", pod: String = "", password: String = "",
         needsReauth: Bool = false) {
        self.id = UUID()
        self.email = email
        self.dsid = dsid
        self.name = name
        self.region = region
        self.isActive = isActive
        self.createdAt = createdAt
        self.storeFront = storeFront
        self.passwordToken = passwordToken
        self.pod = pod
        self.password = password
        self.needsReauth = needsReauth
    }

    /// 地区国旗 emoji
    var flagEmoji: String {
        RegionOption.flag(for: region)
    }

    /// 地区显示名
    var regionDisplayName: String {
        RegionOption.label(for: region)
    }
}

// MARK: - Settings

/// 展开路径中的 ~ 为真实用户主目录。
/// 注意：沙盒下 NSHomeDirectory()/expandingTildeInPath 返回的是容器路径，
/// 需通过 getpwuid 获取真实主目录（/Users/<name>）
func expandTildeInPath(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        let home = String(cString: dir)
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    }
    return (path as NSString).expandingTildeInPath
}

struct AppSettings: Equatable, Codable {
    var downloadDirectory: String
    /// 安全作用域书签：沙盒下持久化用户选择目录的访问授权
    var downloadBookmark: Data?
    var keepOriginal: Bool
    var autoImport: Bool

    static let `default` = AppSettings(
        downloadDirectory: expandTildeInPath("~/IPATool/downloads"),
        downloadBookmark: nil,
        keepOriginal: false,
        autoImport: true
    )
}

// MARK: - Popup

enum PopupLevel {
    case info
    case success
    case error
}

struct AppPopup: Identifiable, Equatable {
    let id = UUID()
    let level: PopupLevel
    let title: String
    let message: String
}

struct BasicMessage: Equatable {
    let success: Bool
    let message: String
}

// MARK: - Metric

struct MetricItem: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let tint: Color
}

// MARK: - Region

struct RegionOption: Identifiable, Equatable {
    let code: String
    let displayName: String
    let flag: String

    var id: String { code }

    /// 热门地区放在最前，其余按字母序排列
    static let popularCodes: Set<String> = ["cn", "us", "jp", "kr", "hk", "tw", "gb", "au", "ca", "de", "fr", "sg"]

    static let all: [RegionOption] = {
        var list: [RegionOption] = [
            // —— 热门地区 ——
            .init(code: "cn", displayName: String(localized: "Mainland China", table: "Regions"), flag: "🇨🇳"),
            .init(code: "hk", displayName: String(localized: "Hong Kong, China", table: "Regions"), flag: "🇭🇰"),
            .init(code: "tw", displayName: String(localized: "Taiwan, China", table: "Regions"), flag: "🇨🇳"),
            .init(code: "mo", displayName: String(localized: "Macao, China", table: "Regions"), flag: "🇲🇴"),
            .init(code: "us", displayName: String(localized: "United States", table: "Regions"), flag: "🇺🇸"),
            .init(code: "jp", displayName: String(localized: "Japan", table: "Regions"), flag: "🇯🇵"),
            .init(code: "kr", displayName: String(localized: "South Korea", table: "Regions"), flag: "🇰🇷"),
            .init(code: "gb", displayName: String(localized: "United Kingdom", table: "Regions"), flag: "🇬🇧"),
            .init(code: "au", displayName: String(localized: "Australia", table: "Regions"), flag: "🇦🇺"),
            .init(code: "ca", displayName: String(localized: "Canada", table: "Regions"), flag: "🇨🇦"),
            .init(code: "de", displayName: String(localized: "Germany", table: "Regions"), flag: "🇩🇪"),
            .init(code: "fr", displayName: String(localized: "France", table: "Regions"), flag: "🇫🇷"),
            .init(code: "sg", displayName: String(localized: "Singapore", table: "Regions"), flag: "🇸🇬"),
            // —— 其他地区 ——
            .init(code: "ae", displayName: String(localized: "United Arab Emirates", table: "Regions"), flag: "🇦🇪"),
            .init(code: "ar", displayName: String(localized: "Argentina", table: "Regions"), flag: "🇦🇷"),
            .init(code: "at", displayName: String(localized: "Austria", table: "Regions"), flag: "🇦🇹"),
            .init(code: "be", displayName: String(localized: "Belgium", table: "Regions"), flag: "🇧🇪"),
            .init(code: "bg", displayName: String(localized: "Bulgaria", table: "Regions"), flag: "🇧🇬"),
            .init(code: "bh", displayName: String(localized: "Bahrain", table: "Regions"), flag: "🇧🇭"),
            .init(code: "br", displayName: String(localized: "Brazil", table: "Regions"), flag: "🇧🇷"),
            .init(code: "by", displayName: String(localized: "Belarus", table: "Regions"), flag: "🇧🇾"),
            .init(code: "ch", displayName: String(localized: "Switzerland", table: "Regions"), flag: "🇨🇭"),
            .init(code: "cl", displayName: String(localized: "Chile", table: "Regions"), flag: "🇨🇱"),
            .init(code: "co", displayName: String(localized: "Colombia", table: "Regions"), flag: "🇨🇴"),
            .init(code: "cr", displayName: String(localized: "Costa Rica", table: "Regions"), flag: "🇨🇷"),
            .init(code: "cy", displayName: String(localized: "Cyprus", table: "Regions"), flag: "🇨🇾"),
            .init(code: "cz", displayName: String(localized: "Czechia", table: "Regions"), flag: "🇨🇿"),
            .init(code: "dk", displayName: String(localized: "Denmark", table: "Regions"), flag: "🇩🇰"),
            .init(code: "ee", displayName: String(localized: "Estonia", table: "Regions"), flag: "🇪🇪"),
            .init(code: "eg", displayName: String(localized: "Egypt", table: "Regions"), flag: "🇪🇬"),
            .init(code: "es", displayName: String(localized: "Spain", table: "Regions"), flag: "🇪🇸"),
            .init(code: "fi", displayName: String(localized: "Finland", table: "Regions"), flag: "🇫🇮"),
            .init(code: "gr", displayName: String(localized: "Greece", table: "Regions"), flag: "🇬🇷"),
            .init(code: "hr", displayName: String(localized: "Croatia", table: "Regions"), flag: "🇭🇷"),
            .init(code: "hu", displayName: String(localized: "Hungary", table: "Regions"), flag: "🇭🇺"),
            .init(code: "id", displayName: String(localized: "Indonesia", table: "Regions"), flag: "🇮🇩"),
            .init(code: "ie", displayName: String(localized: "Ireland", table: "Regions"), flag: "🇮🇪"),
            .init(code: "il", displayName: String(localized: "Israel", table: "Regions"), flag: "🇮🇱"),
            .init(code: "in", displayName: String(localized: "India", table: "Regions"), flag: "🇮🇳"),
            .init(code: "is", displayName: String(localized: "Iceland", table: "Regions"), flag: "🇮🇸"),
            .init(code: "it", displayName: String(localized: "Italy", table: "Regions"), flag: "🇮🇹"),
            .init(code: "jo", displayName: String(localized: "Jordan", table: "Regions"), flag: "🇯🇴"),
            .init(code: "kz", displayName: String(localized: "Kazakhstan", table: "Regions"), flag: "🇰🇿"),
            .init(code: "lb", displayName: String(localized: "Lebanon", table: "Regions"), flag: "🇱🇧"),
            .init(code: "lt", displayName: String(localized: "Lithuania", table: "Regions"), flag: "🇱🇹"),
            .init(code: "lu", displayName: String(localized: "Luxembourg", table: "Regions"), flag: "🇱🇺"),
            .init(code: "lv", displayName: String(localized: "Latvia", table: "Regions"), flag: "🇱🇻"),
            .init(code: "mt", displayName: String(localized: "Malta", table: "Regions"), flag: "🇲🇹"),
            .init(code: "mx", displayName: String(localized: "Mexico", table: "Regions"), flag: "🇲🇽"),
            .init(code: "my", displayName: String(localized: "Malaysia", table: "Regions"), flag: "🇲🇾"),
            .init(code: "nl", displayName: String(localized: "Netherlands", table: "Regions"), flag: "🇳🇱"),
            .init(code: "no", displayName: String(localized: "Norway", table: "Regions"), flag: "🇳🇴"),
            .init(code: "nz", displayName: String(localized: "New Zealand", table: "Regions"), flag: "🇳🇿"),
            .init(code: "om", displayName: String(localized: "Oman", table: "Regions"), flag: "🇴🇲"),
            .init(code: "pe", displayName: String(localized: "Peru", table: "Regions"), flag: "🇵🇪"),
            .init(code: "ph", displayName: String(localized: "Philippines", table: "Regions"), flag: "🇵🇭"),
            .init(code: "pk", displayName: String(localized: "Pakistan", table: "Regions"), flag: "🇵🇰"),
            .init(code: "pl", displayName: String(localized: "Poland", table: "Regions"), flag: "🇵🇱"),
            .init(code: "pt", displayName: String(localized: "Portugal", table: "Regions"), flag: "🇵🇹"),
            .init(code: "qa", displayName: String(localized: "Qatar", table: "Regions"), flag: "🇶🇦"),
            .init(code: "ro", displayName: String(localized: "Romania", table: "Regions"), flag: "🇷🇴"),
            .init(code: "rs", displayName: String(localized: "Serbia", table: "Regions"), flag: "🇷🇸"),
            .init(code: "ru", displayName: String(localized: "Russia", table: "Regions"), flag: "🇷🇺"),
            .init(code: "sa", displayName: String(localized: "Saudi Arabia", table: "Regions"), flag: "🇸🇦"),
            .init(code: "se", displayName: String(localized: "Sweden", table: "Regions"), flag: "🇸🇪"),
            .init(code: "si", displayName: String(localized: "Slovenia", table: "Regions"), flag: "🇸🇮"),
            .init(code: "sk", displayName: String(localized: "Slovakia", table: "Regions"), flag: "🇸🇰"),
            .init(code: "th", displayName: String(localized: "Thailand", table: "Regions"), flag: "🇹🇭"),
            .init(code: "tr", displayName: String(localized: "Türkiye", table: "Regions"), flag: "🇹🇷"),
            .init(code: "ua", displayName: String(localized: "Ukraine", table: "Regions"), flag: "🇺🇦"),
            .init(code: "uy", displayName: String(localized: "Uruguay", table: "Regions"), flag: "🇺🇾"),
            .init(code: "ve", displayName: String(localized: "Venezuela", table: "Regions"), flag: "🇻🇪"),
            .init(code: "vn", displayName: String(localized: "Vietnam", table: "Regions"), flag: "🇻🇳"),
            .init(code: "za", displayName: String(localized: "South Africa", table: "Regions"), flag: "🇿🇦"),
        ]
        return list
    }()

    static func label(for code: String) -> String {
        all.first { $0.code == code }?.displayName ?? code.uppercased()
    }

    static func flag(for code: String) -> String {
        all.first { $0.code == code }?.flag ?? "🌍"
    }
}

// MARK: - Keychain 存储

/// 简单的 Keychain 封装，用于安全存储账号凭据（passwordToken / dsid / storeFront 等）
enum KeychainStore {
    private static let service = "cn.ipatool.accounts"

    /// 保存数据到 Keychain（已存在则更新）
    @discardableResult
    static func save(_ data: Data, forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        // 先尝试更新
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        // 不存在则添加
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// 从 Keychain 读取数据
    static func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// 从 Keychain 删除数据
    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
