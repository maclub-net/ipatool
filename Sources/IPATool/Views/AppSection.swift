import SwiftUI
#if SWIFT_PACKAGE
import IPAToolKit
#endif

enum AppSection: String, Identifiable, CaseIterable {
    case search = "search"
    case downloads = "downloads"
    case purchases = "purchases"
    case accounts = "accounts"
    case logs = "logs"
    case cliMcp = "cliMcp"
    case crackedIpa = "crackedIpa"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "搜索与下载"
        case .downloads: return "下载记录"
        case .purchases: return "已购应用"
        case .accounts: return "账号管理"
        case .logs: return "操作日志"
        case .cliMcp: return "CLI 与 MCP"
        case .crackedIpa: return "砸壳包下载"
        }
    }

    var subtitle: String {
        switch self {
        case .search: return "搜索 App Store 应用"
        case .downloads: return "查看已下载的 IPA"
        case .purchases: return "浏览已购买的应用"
        case .accounts: return "管理各地区 Apple ID"
        case .logs: return "查看操作记录与错误信息"
        case .cliMcp: return "命令行与 MCP Server 使用说明"
        case .crackedIpa: return "前往Mac俱乐部下载砸壳包"
        }
    }

    var systemImage: String {
        switch self {
        case .search: return "magnifyingglass.circle.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .purchases: return "cart.circle.fill"
        case .accounts: return "person.2.circle.fill"
        case .logs: return "doc.text.magnifyingglass"
        case .cliMcp: return "terminal.fill"
        case .crackedIpa: return "link.circle.fill"
        }
    }

    var isExternalLink: Bool {
        self == .crackedIpa
    }
}
