import Foundation

enum AppStoreError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case notLoggedIn
    case parseError(String)
    case authCodeRequired
    case accountDisabled
    case loginError(String)
    case unknownError(String)
    case paidAppNotSupported
    case passwordTokenExpired
    case temporarilyUnavailable
    case subscriptionRequired
    case licenseAlreadyExists
    case licenseRequired
    case rateLimited
    case appNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: "无效的 URL"
        case .httpError(let code): "HTTP 错误: \(code)"
        case .notLoggedIn: "未登录"
        case .parseError(let msg): "解析错误: \(msg)"
        case .authCodeRequired: "需要两步验证码"
        case .accountDisabled: "账号已被禁用"
        case .loginError(let msg): "登录失败: \(msg)"
        case .unknownError(let msg): msg
        case .paidAppNotSupported: "付费应用暂不支持"
        case .passwordTokenExpired: "登录凭证已过期，请删除账号后重新登录"
        case .temporarilyUnavailable: "应用暂时不可用"
        case .subscriptionRequired: "需要订阅"
        case .licenseAlreadyExists: "许可证已存在"
        case .licenseRequired: "需要先获取许可证"
        case .rateLimited: "请求太频繁，请稍后再试"
        case .appNotFound: "未找到该应用"
        }
    }
}