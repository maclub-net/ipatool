import SwiftUI

enum AppSection: String, Identifiable, CaseIterable {
    case search = "search"
    case downloads = "downloads"
    case accounts = "accounts"
    case logs = "logs"
    case crackedIpa = "crackedIpa"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "搜索与下载"
        case .downloads: return "下载记录"
        case .accounts: return "账号管理"
        case .logs: return "操作日志"
        case .crackedIpa: return "砸壳包下载"
        }
    }

    var subtitle: String {
        switch self {
        case .search: return "搜索 App Store 应用"
        case .downloads: return "查看已下载的 IPA"
        case .accounts: return "管理各地区 Apple ID"
        case .logs: return "查看操作记录与错误信息"
        case .crackedIpa: return "前往Mac俱乐部下载砸壳包"
        }
    }

    var systemImage: String {
        switch self {
        case .search: return "magnifyingglass.circle.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .accounts: return "person.2.circle.fill"
        case .logs: return "doc.text.magnifyingglass"
        case .crackedIpa: return "link.circle.fill"
        }
    }

    var isExternalLink: Bool {
        self == .crackedIpa
    }
}