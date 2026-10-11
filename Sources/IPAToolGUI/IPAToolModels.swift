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
        case .search: return "搜索"
        case .purchased: return "已购"
        case .library: return "应用库"
        case .accounts: return "账号"
        case .settings: return "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .search: return "查找并下载应用"
        case .purchased: return "当前账号已购应用"
        case .library: return "管理已下载 IPA"
        case .accounts: return "维护 Apple ID"
        case .settings: return "路径与偏好"
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
        case .single: return "移除此下载记录？"
        case .clearCompleted: return "清空已完成的下载记录？"
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

struct AppSettings: Equatable, Codable {
    var downloadDirectory: String
    var keepOriginal: Bool
    var autoImport: Bool

    static let `default` = AppSettings(
        downloadDirectory: ("~/IPATool/downloads" as NSString).expandingTildeInPath,
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
    let title: String
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
            .init(code: "cn", displayName: "中国大陆", flag: "🇨🇳"),
            .init(code: "hk", displayName: "中国香港", flag: "🇭🇰"),
            .init(code: "tw", displayName: "中国台湾", flag: "🇨🇳"),
            .init(code: "mo", displayName: "中国澳门", flag: "🇲🇴"),
            .init(code: "us", displayName: "美国", flag: "🇺🇸"),
            .init(code: "jp", displayName: "日本", flag: "🇯🇵"),
            .init(code: "kr", displayName: "韩国", flag: "🇰🇷"),
            .init(code: "gb", displayName: "英国", flag: "🇬🇧"),
            .init(code: "au", displayName: "澳大利亚", flag: "🇦🇺"),
            .init(code: "ca", displayName: "加拿大", flag: "🇨🇦"),
            .init(code: "de", displayName: "德国", flag: "🇩🇪"),
            .init(code: "fr", displayName: "法国", flag: "🇫🇷"),
            .init(code: "sg", displayName: "新加坡", flag: "🇸🇬"),
            // —— 其他地区 ——
            .init(code: "ae", displayName: "阿联酋", flag: "🇦🇪"),
            .init(code: "ar", displayName: "阿根廷", flag: "🇦🇷"),
            .init(code: "at", displayName: "奥地利", flag: "🇦🇹"),
            .init(code: "be", displayName: "比利时", flag: "🇧🇪"),
            .init(code: "bg", displayName: "保加利亚", flag: "🇧🇬"),
            .init(code: "bh", displayName: "巴林", flag: "🇧🇭"),
            .init(code: "br", displayName: "巴西", flag: "🇧🇷"),
            .init(code: "by", displayName: "白俄罗斯", flag: "🇧🇾"),
            .init(code: "ch", displayName: "瑞士", flag: "🇨🇭"),
            .init(code: "cl", displayName: "智利", flag: "🇨🇱"),
            .init(code: "co", displayName: "哥伦比亚", flag: "🇨🇴"),
            .init(code: "cr", displayName: "哥斯达黎加", flag: "🇨🇷"),
            .init(code: "cy", displayName: "塞浦路斯", flag: "🇨🇾"),
            .init(code: "cz", displayName: "捷克", flag: "🇨🇿"),
            .init(code: "dk", displayName: "丹麦", flag: "🇩🇰"),
            .init(code: "ee", displayName: "爱沙尼亚", flag: "🇪🇪"),
            .init(code: "eg", displayName: "埃及", flag: "🇪🇬"),
            .init(code: "es", displayName: "西班牙", flag: "🇪🇸"),
            .init(code: "fi", displayName: "芬兰", flag: "🇫🇮"),
            .init(code: "gr", displayName: "希腊", flag: "🇬🇷"),
            .init(code: "hr", displayName: "克罗地亚", flag: "🇭🇷"),
            .init(code: "hu", displayName: "匈牙利", flag: "🇭🇺"),
            .init(code: "id", displayName: "印度尼西亚", flag: "🇮🇩"),
            .init(code: "ie", displayName: "爱尔兰", flag: "🇮🇪"),
            .init(code: "il", displayName: "以色列", flag: "🇮🇱"),
            .init(code: "in", displayName: "印度", flag: "🇮🇳"),
            .init(code: "is", displayName: "冰岛", flag: "🇮🇸"),
            .init(code: "it", displayName: "意大利", flag: "🇮🇹"),
            .init(code: "jo", displayName: "约旦", flag: "🇯🇴"),
            .init(code: "kz", displayName: "哈萨克斯坦", flag: "🇰🇿"),
            .init(code: "lb", displayName: "黎巴嫩", flag: "🇱🇧"),
            .init(code: "lt", displayName: "立陶宛", flag: "🇱🇹"),
            .init(code: "lu", displayName: "卢森堡", flag: "🇱🇺"),
            .init(code: "lv", displayName: "拉脱维亚", flag: "🇱🇻"),
            .init(code: "mt", displayName: "马耳他", flag: "🇲🇹"),
            .init(code: "mx", displayName: "墨西哥", flag: "🇲🇽"),
            .init(code: "my", displayName: "马来西亚", flag: "🇲🇾"),
            .init(code: "nl", displayName: "荷兰", flag: "🇳🇱"),
            .init(code: "no", displayName: "挪威", flag: "🇳🇴"),
            .init(code: "nz", displayName: "新西兰", flag: "🇳🇿"),
            .init(code: "om", displayName: "阿曼", flag: "🇴🇲"),
            .init(code: "pe", displayName: "秘鲁", flag: "🇵🇪"),
            .init(code: "ph", displayName: "菲律宾", flag: "🇵🇭"),
            .init(code: "pk", displayName: "巴基斯坦", flag: "🇵🇰"),
            .init(code: "pl", displayName: "波兰", flag: "🇵🇱"),
            .init(code: "pt", displayName: "葡萄牙", flag: "🇵🇹"),
            .init(code: "qa", displayName: "卡塔尔", flag: "🇶🇦"),
            .init(code: "ro", displayName: "罗马尼亚", flag: "🇷🇴"),
            .init(code: "rs", displayName: "塞尔维亚", flag: "🇷🇸"),
            .init(code: "ru", displayName: "俄罗斯", flag: "🇷🇺"),
            .init(code: "sa", displayName: "沙特阿拉伯", flag: "🇸🇦"),
            .init(code: "se", displayName: "瑞典", flag: "🇸🇪"),
            .init(code: "si", displayName: "斯洛文尼亚", flag: "🇸🇮"),
            .init(code: "sk", displayName: "斯洛伐克", flag: "🇸🇰"),
            .init(code: "th", displayName: "泰国", flag: "🇹🇭"),
            .init(code: "tr", displayName: "土耳其", flag: "🇹🇷"),
            .init(code: "ua", displayName: "乌克兰", flag: "🇺🇦"),
            .init(code: "uy", displayName: "乌拉圭", flag: "🇺🇾"),
            .init(code: "ve", displayName: "委内瑞拉", flag: "🇻🇪"),
            .init(code: "vn", displayName: "越南", flag: "🇻🇳"),
            .init(code: "za", displayName: "南非", flag: "🇿🇦"),
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
