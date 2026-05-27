import Foundation

/// 地区选项
struct RegionOption: Identifiable, Hashable {
    let code: String
    let displayName: String

    var id: String { code }

    static let all: [RegionOption] = [
        .init(code: "AE", displayName: "阿联酋"),
        .init(code: "AG", displayName: "安提瓜和巴布达"),
        .init(code: "AI", displayName: "安圭拉"),
        .init(code: "AL", displayName: "阿尔巴尼亚"),
        .init(code: "AM", displayName: "亚美尼亚"),
        .init(code: "AO", displayName: "安哥拉"),
        .init(code: "AR", displayName: "阿根廷"),
        .init(code: "AT", displayName: "奥地利"),
        .init(code: "AU", displayName: "澳大利亚"),
        .init(code: "AZ", displayName: "阿塞拜疆"),
        .init(code: "BB", displayName: "巴巴多斯"),
        .init(code: "BD", displayName: "孟加拉国"),
        .init(code: "BE", displayName: "比利时"),
        .init(code: "BG", displayName: "保加利亚"),
        .init(code: "BH", displayName: "巴林"),
        .init(code: "BM", displayName: "百慕大"),
        .init(code: "BN", displayName: "文莱"),
        .init(code: "BO", displayName: "玻利维亚"),
        .init(code: "BR", displayName: "巴西"),
        .init(code: "BS", displayName: "巴哈马"),
        .init(code: "BW", displayName: "博茨瓦纳"),
        .init(code: "BY", displayName: "白俄罗斯"),
        .init(code: "BZ", displayName: "伯利兹"),
        .init(code: "CA", displayName: "加拿大"),
        .init(code: "CH", displayName: "瑞士"),
        .init(code: "CI", displayName: "科特迪瓦"),
        .init(code: "CL", displayName: "智利"),
        .init(code: "CN", displayName: "中国大陆"),
        .init(code: "CO", displayName: "哥伦比亚"),
        .init(code: "CR", displayName: "哥斯达黎加"),
        .init(code: "CY", displayName: "塞浦路斯"),
        .init(code: "CZ", displayName: "捷克"),
        .init(code: "DE", displayName: "德国"),
        .init(code: "DK", displayName: "丹麦"),
        .init(code: "DM", displayName: "多米尼克"),
        .init(code: "DO", displayName: "多米尼加"),
        .init(code: "DZ", displayName: "阿尔及利亚"),
        .init(code: "EC", displayName: "厄瓜多尔"),
        .init(code: "EE", displayName: "爱沙尼亚"),
        .init(code: "EG", displayName: "埃及"),
        .init(code: "ES", displayName: "西班牙"),
        .init(code: "FI", displayName: "芬兰"),
        .init(code: "FR", displayName: "法国"),
        .init(code: "GB", displayName: "英国"),
        .init(code: "GD", displayName: "格林纳达"),
        .init(code: "GE", displayName: "格鲁吉亚"),
        .init(code: "GH", displayName: "加纳"),
        .init(code: "GR", displayName: "希腊"),
        .init(code: "GT", displayName: "危地马拉"),
        .init(code: "GY", displayName: "圭亚那"),
        .init(code: "HK", displayName: "中国香港"),
        .init(code: "HN", displayName: "洪都拉斯"),
        .init(code: "HR", displayName: "克罗地亚"),
        .init(code: "HU", displayName: "匈牙利"),
        .init(code: "ID", displayName: "印度尼西亚"),
        .init(code: "IE", displayName: "爱尔兰"),
        .init(code: "IL", displayName: "以色列"),
        .init(code: "IN", displayName: "印度"),
        .init(code: "IQ", displayName: "伊拉克"),
        .init(code: "IS", displayName: "冰岛"),
        .init(code: "IT", displayName: "意大利"),
        .init(code: "JM", displayName: "牙买加"),
        .init(code: "JO", displayName: "约旦"),
        .init(code: "JP", displayName: "日本"),
        .init(code: "KE", displayName: "肯尼亚"),
        .init(code: "KN", displayName: "圣基茨和尼维斯"),
        .init(code: "KR", displayName: "韩国"),
        .init(code: "KW", displayName: "科威特"),
        .init(code: "KY", displayName: "开曼群岛"),
        .init(code: "KZ", displayName: "哈萨克斯坦"),
        .init(code: "LB", displayName: "黎巴嫩"),
        .init(code: "LC", displayName: "圣卢西亚"),
        .init(code: "LI", displayName: "列支敦士登"),
        .init(code: "LK", displayName: "斯里兰卡"),
        .init(code: "LT", displayName: "立陶宛"),
        .init(code: "LU", displayName: "卢森堡"),
        .init(code: "LV", displayName: "拉脱维亚"),
        .init(code: "MD", displayName: "摩尔多瓦"),
        .init(code: "MG", displayName: "马达加斯加"),
        .init(code: "MK", displayName: "北马其顿"),
        .init(code: "ML", displayName: "马里"),
        .init(code: "MN", displayName: "蒙古"),
        .init(code: "MO", displayName: "中国澳门"),
        .init(code: "MS", displayName: "蒙特塞拉特"),
        .init(code: "MT", displayName: "马耳他"),
        .init(code: "MU", displayName: "毛里求斯"),
        .init(code: "MV", displayName: "马尔代夫"),
        .init(code: "MX", displayName: "墨西哥"),
        .init(code: "MY", displayName: "马来西亚"),
        .init(code: "NE", displayName: "尼日尔"),
        .init(code: "NG", displayName: "尼日利亚"),
        .init(code: "NI", displayName: "尼加拉瓜"),
        .init(code: "NL", displayName: "荷兰"),
        .init(code: "NO", displayName: "挪威"),
        .init(code: "NP", displayName: "尼泊尔"),
        .init(code: "NZ", displayName: "新西兰"),
        .init(code: "OM", displayName: "阿曼"),
        .init(code: "PA", displayName: "巴拿马"),
        .init(code: "PE", displayName: "秘鲁"),
        .init(code: "PH", displayName: "菲律宾"),
        .init(code: "PK", displayName: "巴基斯坦"),
        .init(code: "PL", displayName: "波兰"),
        .init(code: "PT", displayName: "葡萄牙"),
        .init(code: "PY", displayName: "巴拉圭"),
        .init(code: "QA", displayName: "卡塔尔"),
        .init(code: "RO", displayName: "罗马尼亚"),
        .init(code: "RS", displayName: "塞尔维亚"),
        .init(code: "RU", displayName: "俄罗斯"),
        .init(code: "SA", displayName: "沙特阿拉伯"),
        .init(code: "SE", displayName: "瑞典"),
        .init(code: "SG", displayName: "新加坡"),
        .init(code: "SI", displayName: "斯洛文尼亚"),
        .init(code: "SK", displayName: "斯洛伐克"),
        .init(code: "SN", displayName: "塞内加尔"),
        .init(code: "SR", displayName: "苏里南"),
        .init(code: "SV", displayName: "萨尔瓦多"),
        .init(code: "TC", displayName: "特克斯和凯科斯群岛"),
        .init(code: "TH", displayName: "泰国"),
        .init(code: "TN", displayName: "突尼斯"),
        .init(code: "TR", displayName: "土耳其"),
        .init(code: "TT", displayName: "特立尼达和多巴哥"),
        .init(code: "TW", displayName: "中国台湾"),
        .init(code: "TZ", displayName: "坦桑尼亚"),
        .init(code: "UA", displayName: "乌克兰"),
        .init(code: "UG", displayName: "乌干达"),
        .init(code: "US", displayName: "美国"),
        .init(code: "UY", displayName: "乌拉圭"),
        .init(code: "UZ", displayName: "乌兹别克斯坦"),
        .init(code: "VC", displayName: "圣文森特和格林纳丁斯"),
        .init(code: "VE", displayName: "委内瑞拉"),
        .init(code: "VG", displayName: "英属维尔京群岛"),
        .init(code: "VN", displayName: "越南"),
        .init(code: "YE", displayName: "也门"),
        .init(code: "ZA", displayName: "南非"),
    ]

    /// 根据地区代码获取显示名
    static func displayName(for code: String) -> String {
        all.first(where: { $0.code == code })?.displayName ?? code
    }
}

/// App Store 账号信息
struct Account: Codable, Identifiable, Sendable {
    var id: String { email + "_" + region }
    let email: String
    let name: String
    let region: String
    var passwordToken: String
    var directoryServicesID: String
    var storeFront: String
    var password: String
    var pod: String

    var regionDisplayName: String {
        RegionOption.displayName(for: region)
    }

    var countryCode: String? {
        Storefront.countryCode(for: storeFront)
    }

    var storeFrontID: String {
        storeFront.split(separator: "-").first.map(String.init) ?? "143465"
    }
}

/// 账号摘要（列表展示用）
struct AccountSummary: Codable, Identifiable {
    var id: String { email + "_" + region }
    let email: String
    let name: String
    let region: String

    var regionDisplayName: String {
        RegionOption.displayName(for: region)
    }
}