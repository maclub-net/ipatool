import Foundation

/// App Store 平台枚举
public enum Platform: String, Codable, CaseIterable, Sendable {
    case iphone
    case ipad
    case appletv
    case watchos
    case visionos
    case macos

    /// 从用户输入解析平台
    public static func parse(_ value: String?) -> Platform? {
        guard let value, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "iphone", "ios": return .iphone
        case "ipad", "ipados": return .ipad
        case "appletv", "apple-tv", "tvos": return .appletv
        case "watch", "watchos", "applewatch", "apple-watch": return .watchos
        case "vision", "visionos", "visionpro", "xros", "realitydevice": return .visionos
        case "mac", "macos", "osx": return .macos
        default: return nil
        }
    }

    /// 搜索请求的 entity 参数
    public var searchEntity: String {
        switch self {
        case .iphone: return "software"
        case .ipad: return "iPadSoftware"
        case .appletv: return "software,tvSoftware"
        case .watchos: return "software,watchSoftware"
        case .visionos: return "xrosSoftware"
        case .macos: return "macSoftware"
        }
    }

    /// Lookup 请求的 entity 参数
    public var lookupEntity: String {
        switch self {
        case .iphone: return "software"
        case .ipad: return "iPadSoftware"
        case .appletv: return "tvSoftware"
        case .watchos: return "watchSoftware"
        case .visionos: return "xrosSoftware"
        case .macos: return "macSoftware"
        }
    }

    /// 显示名称
    public var displayName: String {
        switch self {
        case .iphone: return "iOS"
        case .ipad: return "iPadOS"
        case .appletv: return "tvOS"
        case .watchos: return "watchOS"
        case .visionos: return "visionOS"
        case .macos: return "macOS"
        }
    }

    /// SF Symbol 图标名
    public var systemImage: String {
        switch self {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .appletv: return "appletv"
        case .watchos: return "applewatch"
        case .visionos: return "visionpro"
        case .macos: return "macbook"
        }
    }

    /// 文件扩展名
    public var fileExtension: String {
        self == .macos ? "pkg" : "ipa"
    }

    /// 从 supportedDevices 列表推断平台
    public static func fromSupportedDevices(_ devices: [String]) -> [Platform] {
        var platforms: [Platform] = []
        let families: [(prefix: String, platform: Platform)] = [
            ("iPhone", .iphone), ("iPod", .iphone),
            ("iPad", .ipad),
            ("AppleTV", .appletv),
            ("Watch", .watchos),
            ("RealityDevice", .visionos),
            ("Mac", .macos),
        ]
        for family in families {
            if devices.contains(where: { $0.hasPrefix(family.prefix) }) && !platforms.contains(family.platform) {
                platforms.append(family.platform)
            }
        }
        return platforms
    }
}
