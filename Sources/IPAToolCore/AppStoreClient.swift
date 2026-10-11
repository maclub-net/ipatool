import Foundation
import IOKit

// MARK: - Constants

private let iTunesAPIDomain = "itunes.apple.com"
private let iTunesAPIPathSearch = "/search"
private let iTunesAPIPathLookup = "/lookup"
private let privateAppStoreAPIDomain = "buy.itunes.apple.com"
private let privateAppStoreAPIPathPurchase = "/WebObjects/MZFinance.woa/wa/buyProduct"
private let privateAppStoreAPIPathDownload = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
private let privatePurchaseDAAPBaseURL = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
private let defaultUserAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"

private let pricingParameterAppStore = "STDQ"
private let pricingParameterAppleArcade = "GAME"

// MARK: - Platform

/// 应用平台，对应 iTunes Search API 的 entity 参数（对齐上游 ipatool-go）。
public enum Platform: String, CaseIterable, Codable {
    case iphone
    case ipad
    case appleTV
    case visionOS
    case macOS

    /// iTunes Search API 中搜索接口使用的 entity 值
    public var searchEntity: String {
        switch self {
        case .iphone: return "software"
        case .ipad: return "iPadSoftware"
        case .appleTV: return "software,tvSoftware"
        case .visionOS: return "xrosSoftware"
        case .macOS: return "macSoftware"
        }
    }

    public var displayName: String {
        switch self {
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .appleTV: return "Apple TV"
        case .visionOS: return "visionOS"
        case .macOS: return "macOS"
        }
    }

    public var systemImage: String {
        switch self {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .appleTV: return "appletv"
        case .visionOS: return "visionpro"
        case .macOS: return "macbook"
        }
    }
}

// MARK: - Models

public struct AccountInfo: Equatable {
    public let email: String
    public let name: String
    public let storeFront: String
    public let passwordToken: String
    public let directoryServicesID: String
    public let pod: String

    public init(email: String, name: String, storeFront: String, passwordToken: String, directoryServicesID: String, pod: String) {
        self.email = email
        self.name = name
        self.storeFront = storeFront
        self.passwordToken = passwordToken
        self.directoryServicesID = directoryServicesID
        self.pod = pod
    }
}

public struct AppStoreApp: Identifiable, Equatable, Codable {
    public let trackId: Int
    public let trackName: String
    public let bundleId: String
    public let sellerName: String
    public let version: String
    public let price: Double?
    public let artworkUrl: String?
    public let platforms: [Platform]

    public var id: Int { trackId }

    public init(trackId: Int, trackName: String, bundleId: String, sellerName: String, version: String, price: Double?, artworkUrl: String?, platforms: [Platform] = []) {
        self.trackId = trackId
        self.trackName = trackName
        self.bundleId = bundleId
        self.sellerName = sellerName
        self.version = version
        self.price = price
        self.artworkUrl = artworkUrl
        self.platforms = platforms
    }
}

/// 已购应用（来自购买历史接口）
public struct OwnedApp: Identifiable, Equatable, Codable {
    public let id: Int
    public let name: String
    public let bundleId: String
    public let version: String
    public var purchaseDate: Date?
    public var platforms: [Platform]
    public var artworkUrl: String?

    public init(id: Int, name: String, bundleId: String, version: String, purchaseDate: Date?, platforms: [Platform], artworkUrl: String? = nil) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.version = version
        self.purchaseDate = purchaseDate
        self.platforms = platforms
        self.artworkUrl = artworkUrl
    }
}

public struct SAPConfig {
    public let authEndpoint: URL
    public let certificateURL: URL
    public let setupURL: URL
    public let version: UInt32

    public init(authEndpoint: URL, certificateURL: URL, setupURL: URL, version: UInt32) {
        self.authEndpoint = authEndpoint
        self.certificateURL = certificateURL
        self.setupURL = setupURL
        self.version = version
    }
}

public struct MachineIdentity {
    public let guid: String
    public let hardwareID: Data

    public init(guid: String, hardwareID: Data) {
        self.guid = guid
        self.hardwareID = hardwareID
    }
}

// MARK: - Machine Identity

public func currentMachineIdentity() throws -> MachineIdentity {
    let mac = try primaryMacAddress()
    let guid = mac.map { String(format: "%02X", $0) }.joined()
    return MachineIdentity(guid: guid, hardwareID: Data(mac))
}

private func primaryMacAddress() throws -> [UInt8] {
    let mainPort: UInt32 = 0
    let matching = IOBSDNameMatching(mainPort, 0, "en0")
    guard let matching = matching else {
        throw NSError(domain: "IPATool", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建网络接口匹配字典"])
    }

    let service = IOServiceGetMatchingService(mainPort, matching)
    guard service != 0 else {
        throw NSError(domain: "IPATool", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到 en0 网络接口"])
    }
    defer { IOObjectRelease(service) }

    let key = "IOMACAddress" as CFString
    guard let property = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        key,
        kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    ) else {
        throw NSError(domain: "IPATool", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法读取硬件 MAC 地址"])
    }

    guard let data = property as? Data, data.count == 6 else {
        throw NSError(domain: "IPATool", code: 4, userInfo: [NSLocalizedDescriptionKey: "MAC 地址格式不正确"])
    }
    return [UInt8](data)
}

// MARK: - Storefront → Country Code

private let storeFrontToCountry: [String: String] = [
    "143441": "US", "143442": "FR", "143443": "DE", "143444": "GB",
    "143445": "AT", "143446": "BE", "143447": "FI", "143448": "GR",
    "143449": "IE", "143450": "IT", "143451": "LU", "143452": "NL",
    "143453": "PT", "143454": "ES", "143455": "CA", "143456": "SE",
    "143457": "NO", "143458": "DK", "143459": "CH", "143460": "AU",
    "143461": "NZ", "143462": "JP", "143463": "HK", "143464": "SG",
    "143465": "CN", "143466": "KR", "143467": "IN", "143468": "MX",
    "143469": "RU", "143470": "TW", "143471": "VN", "143472": "ZA",
    "143473": "MY", "143474": "PH", "143475": "TH", "143476": "ID",
    "143477": "PK", "143478": "PL", "143479": "SA", "143480": "TR",
    "143481": "AE", "143482": "HU", "143483": "CL", "143484": "NP",
    "143485": "PA", "143486": "LK", "143487": "RO", "143488": "MV",
    "143489": "CZ", "143490": "BD", "143491": "IL", "143492": "UA",
    "143493": "KW", "143494": "HR", "143495": "CR", "143496": "SK",
    "143497": "LB", "143498": "QA", "143499": "SI", "143500": "RS",
    "143501": "CO", "143502": "VE", "143503": "BR", "143504": "GT",
    "143505": "AR", "143506": "SV", "143507": "PE", "143508": "DO",
    "143509": "EC", "143510": "HN", "143511": "JM", "143512": "NI",
    "143513": "PY", "143514": "UY", "143515": "MO", "143516": "EG",
    "143517": "KZ", "143518": "EE", "143519": "LV", "143520": "LT",
    "143521": "MT", "143522": "LI", "143523": "MD", "143524": "AM",
    "143525": "BW", "143526": "BG", "143527": "CI", "143528": "JO",
    "143529": "KE", "143530": "MK", "143531": "MG", "143532": "ML",
    "143533": "MU", "143534": "NE", "143535": "SN", "143536": "TN",
    "143537": "UG", "143538": "AI", "143539": "BS", "143540": "AG",
    "143541": "BB", "143542": "BM", "143543": "VG", "143544": "KY",
    "143545": "DM", "143546": "GD", "143547": "MS", "143548": "KN",
    "143549": "LC", "143550": "VC", "143551": "TT", "143552": "TC",
    "143553": "GY", "143554": "SR", "143555": "BZ", "143556": "BO",
    "143557": "CY", "143558": "IS", "143559": "BH", "143560": "BN",
    "143561": "NG", "143562": "OM", "143563": "DZ", "143564": "AO",
    "143565": "BY", "143566": "UZ", "143568": "AZ", "143571": "YE",
    "143572": "TZ", "143573": "GH", "143575": "AL", "143577": "TZ",
    "143592": "MN", "143615": "GE", "143617": "IQ",
]

private func countryCode(from storeFront: String) -> String {
    let parts = storeFront.split(separator: "-")
    guard let prefix = parts.first.map(String.init) else { return "US" }
    return storeFrontToCountry[prefix] ?? "US"
}

// MARK: - App Store Client

public class AppStoreClient: NSObject, URLSessionTaskDelegate {
    private let session: URLSession
    private lazy var noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public var account: AccountInfo?

    public override init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
        super.init()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: - Helpers

    private func defaultRequest(_ url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// 从可能带有 <Document> 包装的 XML 中提取并解析 plist
    private func parsePlistResponse(_ data: Data) -> [String: Any]? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dict = plist as? [String: Any] {
            return dict
        }
        guard let xmlStr = String(data: data, encoding: .utf8),
              let plistRange = xmlStr.range(of: "<plist[^>]*>.*</plist>", options: .regularExpression) else {
            return nil
        }
        let plistData = Data(xmlStr[plistRange].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }
        return dict
    }

    // MARK: - Bag

    public func fetchBag() async throws -> SAPConfig {
        let identity = try currentMachineIdentity()
        guard let url = URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(identity.guid)") else {
            throw AppStoreError.invalidResponse
        }

        var request = defaultRequest(url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.invalidResponse
        }

        guard let xmlStr = String(data: data, encoding: .utf8),
              let plistRange = xmlStr.range(of: "<plist[^>]*>.*</plist>", options: .regularExpression) else {
            throw AppStoreError.parseFailed
        }
        let plistData = Data(xmlStr[plistRange].utf8)

        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dict = plist as? [String: Any],
              let urlBag = dict["urlBag"] as? [String: Any],
              let authURLString = urlBag["authenticateAccount"] as? String,
              let certURLString = urlBag["sign-sap-setup-cert"] as? String,
              let setupURLString = urlBag["sign-sap-setup"] as? String,
              let versionString = urlBag["sign-sap-version"] as? String,
              let authURL = URL(string: authURLString),
              let certURL = URL(string: certURLString),
              let setupURL = URL(string: setupURLString),
              let version = UInt32(versionString) else {
            throw AppStoreError.parseFailed
        }

        var authComponents = URLComponents(url: authURL, resolvingAgainstBaseURL: false)
        authComponents?.path = "/WebObjects/MZFinance.woa/wa/authenticate/"
        let normalizedAuthURL = authComponents?.url ?? authURL

        return SAPConfig(authEndpoint: normalizedAuthURL, certificateURL: certURL, setupURL: setupURL, version: version)
    }

    /// 获取 bag 中的 urlBag 字典，用于获取 redownloadProduct 等端点
    public func fetchURLBag() async throws -> [String: Any] {
        let identity = try currentMachineIdentity()
        guard let url = URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(identity.guid)") else {
            throw AppStoreError.invalidResponse
        }

        var request = defaultRequest(url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.invalidResponse
        }

        guard let xmlStr = String(data: data, encoding: .utf8),
              let plistRange = xmlStr.range(of: "<plist[^>]*>.*</plist>", options: .regularExpression) else {
            throw AppStoreError.parseFailed
        }
        let plistData = Data(xmlStr[plistRange].utf8)

        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dict = plist as? [String: Any],
              let urlBag = dict["urlBag"] as? [String: Any] else {
            throw AppStoreError.parseFailed
        }

        return urlBag
    }

    // MARK: - Login

    public func login(email: String, password: String, code: String? = nil,
                      signer: SAPSigner, authEndpoint: URL, guid: String) async throws -> AccountInfo {
        let body: [String: Any] = [
            "appleId": email,
            "attempt": "1",
            "guid": guid,
            "password": password + (code?.replacingOccurrences(of: " ", with: "") ?? ""),
            "rmp": "0",
            "why": "signIn",
        ]

        let bodyData = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)

        let signature = try signer.sign(bodyData)
        let signatureB64 = signature.base64EncodedString()

        var request = defaultRequest(authEndpoint, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(signatureB64, forHTTPHeaderField: "X-Apple-ActionSignature")
        request.httpBody = bodyData

        print("[login] POST \(authEndpoint.absoluteString)")
        print("[login] signature length: \(signatureB64.count)")

        var currentRequest = request
        var data = Data()
        var httpResponse: HTTPURLResponse?

        for _ in 0...5 {
            let (respData, resp) = try await noRedirectSession.data(for: currentRequest)
            data = respData
            guard let http = resp as? HTTPURLResponse else {
                throw AppStoreError.invalidResponse
            }
            httpResponse = http

            if (300...399).contains(http.statusCode),
               let location = http.value(forHTTPHeaderField: "Location"),
               let redirectURL = URL(string: location, relativeTo: currentRequest.url) {
                print("[login] redirect \(http.statusCode) -> \(redirectURL.absoluteString)")
                currentRequest.url = redirectURL
                currentRequest.httpBody = bodyData
                continue
            }
            break
        }

        guard let httpResponse = httpResponse else {
            throw AppStoreError.invalidResponse
        }
        print("[login] HTTP \(httpResponse.statusCode)")
        if let bodyStr = String(data: data, encoding: .utf8) {
            print("[login] response (\(data.count) bytes): \(bodyStr.prefix(3000))")
        }

        guard let dict = parsePlistResponse(data) else {
            throw AppStoreError.parseFailed
        }

        if let failureType = dict["failureType"] as? String, !failureType.isEmpty {
            let msg = dict["customerMessage"] as? String ?? failureType
            print("[login] FAILURE: \(failureType) - \(msg)")
            // -5000 (InvalidCredentials) 且未提供验证码时，通常表示需要 2FA
            if code == nil, failureType == "-5000" {
                throw AppStoreError.requires2FA
            }
            throw AppStoreError.loginFailed(message: msg)
        }

        // customerMessage 为 BadLogin 且无验证码时也表示需要 2FA
        if let customerMessage = dict["customerMessage"] as? String,
           customerMessage.contains("BadLogin"), code == nil {
            print("[login] BadLogin without code -> requires 2FA")
            throw AppStoreError.requires2FA
        }

        guard let passwordToken = dict["passwordToken"] as? String, !passwordToken.isEmpty else {
            throw AppStoreError.loginFailed(message: "No password token in response")
        }

        // 从响应头提取 storefront 和 pod
        let storeFront = httpResponse.value(forHTTPHeaderField: "X-Set-Apple-Store-Front") ?? ""
        let pod = httpResponse.value(forHTTPHeaderField: "pod") ?? ""
        print("[login] all headers: \(httpResponse.allHeaderFields)")
        print("[login] storeFront=\(storeFront), pod=\(pod)")

        let accountInfo = dict["accountInfo"] as? [String: Any]
        let firstName = accountInfo?["firstName"] as? String ?? ""
        let lastName = accountInfo?["lastName"] as? String ?? ""
        let dsid = dict["dsPersonId"] as? String ?? ""

        let acc = AccountInfo(
            email: email,
            name: "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces),
            storeFront: storeFront,
            passwordToken: passwordToken,
            directoryServicesID: dsid,
            pod: pod
        )
        self.account = acc

        print("[login] SUCCESS: \(acc.name), storefront=\(storeFront), pod=\(pod)")
        return acc
    }

    public func logout() {
        account = nil
    }

    // MARK: - Search

    public func search(term: String, limit: Int = 25, platform: Platform? = nil) async throws -> [AppStoreApp] {
        let country = account.map { countryCode(from: $0.storeFront) } ?? "US"
        let entity = platform?.searchEntity ?? "software,iPadSoftware"
        print("[search] term=\(term), platform=\(platform?.rawValue ?? "all"), entity=\(entity), country=\(country)")
        var components = URLComponents(string: "https://\(iTunesAPIDomain)\(iTunesAPIPathSearch)")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "country", value: country),
        ]

        let request = defaultRequest(components.url!)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw AppStoreError.parseFailed
        }

        return results.compactMap { dict in
            guard let trackId = dict["trackId"] as? Int,
                  let trackName = dict["trackName"] as? String else {
                return nil
            }
            return AppStoreApp(
                trackId: trackId,
                trackName: trackName,
                bundleId: dict["bundleId"] as? String ?? "",
                sellerName: dict["sellerName"] as? String ?? "",
                version: dict["version"] as? String ?? "",
                price: dict["price"] as? Double,
                artworkUrl: dict["artworkUrl100"] as? String,
                platforms: Self.parsePlatforms(from: dict)
            )
        }
    }

    /// 从搜索/查找结果中解析支持的平台列表
    private static func parsePlatforms(from dict: [String: Any]) -> [Platform] {
        var platforms: [Platform] = []
        let kind = dict["kind"] as? String ?? ""
        if kind == "mac-software" {
            platforms.append(.macOS)
        }
        if let devices = dict["supportedDevices"] as? [String] {
            for device in devices {
                if device.hasPrefix("iPhone") && !platforms.contains(.iphone) {
                    platforms.append(.iphone)
                } else if device.hasPrefix("iPad") && !platforms.contains(.ipad) {
                    platforms.append(.ipad)
                } else if device.hasPrefix("AppleTV") && !platforms.contains(.appleTV) {
                    platforms.append(.appleTV)
                }
            }
        }
        if let isUniversal = dict["isUniversal"] as? Bool, isUniversal {
            if !platforms.contains(.iphone) { platforms.append(.iphone) }
            if !platforms.contains(.ipad) { platforms.append(.ipad) }
        }
        return platforms
    }

    // MARK: - Lookup

    public func lookup(bundleID: String) async throws -> AppStoreApp? {
        let country = account.map { countryCode(from: $0.storeFront) } ?? "US"
        var components = URLComponents(string: "https://\(iTunesAPIDomain)\(iTunesAPIPathLookup)")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "media", value: "software"),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "country", value: country),
        ]

        let request = defaultRequest(components.url!)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let dict = results.first,
              let trackId = dict["trackId"] as? Int,
              let trackName = dict["trackName"] as? String else {
            return nil
        }

        return AppStoreApp(
            trackId: trackId,
            trackName: trackName,
            bundleId: dict["bundleId"] as? String ?? "",
            sellerName: dict["sellerName"] as? String ?? "",
            version: dict["version"] as? String ?? "",
            price: dict["price"] as? Double,
            artworkUrl: dict["artworkUrl100"] as? String,
            platforms: Self.parsePlatforms(from: dict)
        )
    }

    /// 批量通过 trackId 查找应用信息（含 artwork URL），用于已购应用补全图标
    public func lookupApps(byIDs ids: [Int]) async throws -> [Int: AppStoreApp] {
        guard !ids.isEmpty else { return [:] }
        let country = account.map { countryCode(from: $0.storeFront) } ?? "US"
        var result: [Int: AppStoreApp] = [:]

        // iTunes lookup 接口支持逗号分隔的多个 id，分批避免 URL 过长
        for chunk in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[chunk..<min(chunk + 100, ids.count)])
            let idString = batch.map(String.init).joined(separator: ",")
            var components = URLComponents(string: "https://\(iTunesAPIDomain)\(iTunesAPIPathLookup)")!
            components.queryItems = [
                URLQueryItem(name: "id", value: idString),
                URLQueryItem(name: "country", value: country),
            ]

            let request = defaultRequest(components.url!)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                continue
            }

            for dict in results {
                guard let trackId = dict["trackId"] as? Int,
                      let trackName = dict["trackName"] as? String else { continue }
                let app = AppStoreApp(
                    trackId: trackId,
                    trackName: trackName,
                    bundleId: dict["bundleId"] as? String ?? "",
                    sellerName: dict["sellerName"] as? String ?? "",
                    version: dict["version"] as? String ?? "",
                    price: dict["price"] as? Double,
                    artworkUrl: dict["artworkUrl100"] as? String,
                    platforms: Self.parsePlatforms(from: dict)
                )
                result[trackId] = app
            }
        }

        return result
    }

    // MARK: - Purchase

    public func purchase(appID: Int) async throws {
        guard let account = account else {
            throw AppStoreError.notAuthenticated
        }

        let identity = try currentMachineIdentity()
        let podPrefix = account.pod.isEmpty ? "" : "p\(account.pod)-"
        let url = URL(string: "https://\(podPrefix)\(privateAppStoreAPIDomain)\(privateAppStoreAPIPathPurchase)")!

        let body: [String: Any] = [
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": identity.guid,
            "needDiv": "0",
            "origPage": "Software-\(appID)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricingParameterAppStore,
            "productType": "C",
            "salableAdamId": String(appID),
        ]

        let bodyData = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)

        var request = defaultRequest(url, method: "POST")
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")
        request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        request.httpBody = bodyData

        print("[purchase] POST \(url.absoluteString)")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreError.invalidResponse
        }
        print("[purchase] HTTP \(httpResponse.statusCode)")

        guard let dict = parsePlistResponse(data) else {
            throw AppStoreError.parseFailed
        }

        if let failureType = dict["failureType"] as? String, !failureType.isEmpty {
            if failureType == "5002" {
                print("[purchase] license already exists")
                return
            }
            let msg = dict["customerMessage"] as? String ?? failureType
            throw AppStoreError.purchaseFailed(message: msg)
        }

        let jingleDocType = dict["jingleDocType"] as? String
        let status = dict["status"] as? Int ?? -1
        guard jingleDocType == "purchaseSuccess", status == 0 else {
            throw AppStoreError.purchaseFailed(message: "Unexpected response")
        }

        print("[purchase] SUCCESS")
    }

    // MARK: - Download (product request)

    public func downloadProduct(appID: Int, externalVersionID: String? = nil) async throws -> [String: Any] {
        guard let account = account else {
            throw AppStoreError.notAuthenticated
        }

        let identity = try currentMachineIdentity()

        // 1. 尝试 volumeStoreDownloadProduct
        let podPrefix = account.pod.isEmpty ? "" : "p\(account.pod)-"
        let volumeURL = URL(string: "https://\(podPrefix)\(privateAppStoreAPIDomain)\(privateAppStoreAPIPathDownload)?guid=\(identity.guid)")!
        var volumeDict = try await sendDownloadRequest(url: volumeURL, appID: appID, guid: identity.guid, externalVersionID: externalVersionID, versionKey: "externalVersionId")

        // 2. 如果 songList 为空，尝试先购买再重试
        if isEmptyDownloadResponse(volumeDict) {
            print("[download] volumeStore empty, attempting purchase...")
            try? await purchase(appID: appID)
            volumeDict = try await sendDownloadRequest(url: volumeURL, appID: appID, guid: identity.guid, externalVersionID: externalVersionID, versionKey: "externalVersionId")
        }

        // 3. 如果仍然为空，回退到 redownload 端点
        if isEmptyDownloadResponse(volumeDict) {
            print("[download] still empty, trying redownload...")
            if let redownloadURL = try? await redownloadEndpoint() {
                do {
                    volumeDict = try await sendDownloadRequest(url: redownloadURL, appID: appID, guid: identity.guid, externalVersionID: externalVersionID, versionKey: "appExtVrsId")
                } catch {
                    print("[download] redownload failed: \(error)")
                }
            }
        }

        // 4. 如果仍然为空，回退到 updateProduct 端点
        if isEmptyDownloadResponse(volumeDict) {
            print("[download] still empty, trying updateProduct...")
            if let updateURL = try? await updateProductEndpoint() {
                do {
                    volumeDict = try await sendDownloadRequest(url: updateURL, appID: appID, guid: identity.guid, externalVersionID: externalVersionID, versionKey: "appExtVrsId")
                } catch {
                    print("[download] updateProduct failed: \(error)")
                }
            }
        }

        if let failureType = volumeDict["failureType"] as? String, !failureType.isEmpty {
            let msg = volumeDict["customerMessage"] as? String ?? failureType
            print("[download] failureType=\(failureType), msg=\(msg)")
            throw AppStoreError.downloadFailed(message: msg)
        }

        return volumeDict
    }

    private func sendDownloadRequest(url: URL, appID: Int, guid: String, externalVersionID: String?, versionKey: String) async throws -> [String: Any] {
        var body: [String: Any] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": String(appID),
            "serialNumber": "0",
        ]
        if let externalVersionID = externalVersionID {
            body[versionKey] = externalVersionID
        }

        let bodyData = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)

        var request = defaultRequest(url, method: "POST")
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        if let account = account {
            request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
            request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")
            request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        }
        request.httpBody = bodyData

        print("[download] POST \(url.absoluteString)")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreError.invalidResponse
        }
        print("[download] HTTP \(httpResponse.statusCode)")

        guard let dict = parsePlistResponse(data) else {
            print("[download] parsePlistResponse failed, raw: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "")")
            throw AppStoreError.parseFailed
        }

        print("[download] response keys: \(dict.keys.sorted())")
        if let songList = dict["songList"] {
            print("[download] songList type: \(type(of: songList)), count: \( (songList as? [Any])?.count ?? -1 )")
        }

        return dict
    }

    private func isEmptyDownloadResponse(_ dict: [String: Any]) -> Bool {
        guard let songList = dict["songList"] as? [Any], !songList.isEmpty else {
            return true
        }
        return false
    }

    private func redownloadEndpoint() async throws -> URL? {
        let urlBag = try await fetchURLBag()
        guard let endpoint = urlBag["redownloadProduct"] as? String, !endpoint.isEmpty else {
            print("[download] no redownloadProduct in bag")
            return nil
        }
        let identity = try currentMachineIdentity()
        return URL(string: "\(endpoint)?guid=\(identity.guid)")
    }

    private func updateProductEndpoint() async throws -> URL? {
        let urlBag = try await fetchURLBag()
        guard let endpoint = urlBag["updateProduct"] as? String, !endpoint.isEmpty else {
            print("[download] no updateProduct in bag")
            return nil
        }
        let identity = try currentMachineIdentity()
        return URL(string: "\(endpoint)?guid=\(identity.guid)")
    }

    // MARK: - List Versions

    public func listVersions(appID: Int) async throws -> [String] {
        // 先尝试获取版本列表，如果没有 license 则先购买再重试
        do {
            let dict = try await downloadProduct(appID: appID)
            return try extractVersions(from: dict)
        } catch AppStoreError.downloadFailed(let msg) where msg.contains("License") || msg.contains("license") {
            print("[versions] no license, purchasing first...")
            try await purchase(appID: appID)
            let dict = try await downloadProduct(appID: appID)
            return try extractVersions(from: dict)
        }
    }

    private func extractVersions(from dict: [String: Any]) throws -> [String] {
        guard let rawSongList = dict["songList"] else {
            print("[versions] no songList key in response, keys: \(dict.keys)")
            throw AppStoreError.parseFailed
        }

        guard let songList = rawSongList as? [Any], !songList.isEmpty else {
            print("[versions] songList is empty or not an array")
            throw AppStoreError.parseFailed
        }

        guard let item = songList.first as? [String: Any],
              let metadata = item["metadata"] as? [String: Any] else {
            print("[versions] no metadata in item")
            throw AppStoreError.parseFailed
        }

        guard let identifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any] else {
            print("[versions] no softwareVersionExternalIdentifiers")
            throw AppStoreError.parseFailed
        }

        let versionIDs = identifiers.map { "\($0)" }
        let latestID = metadata["softwareVersionExternalIdentifier"].map { "\($0)" }

        print("[versions] total \(versionIDs.count) versions, latestID=\(latestID ?? "nil")")

        // Apple 返回的数组按时间升序（最早→最新）
        // 我们要：最新 → 次新 → ... → 最早
        // 先反转整个数组（最新→最早），然后确保最新版本在第一位
        var ordered = Array(versionIDs.reversed())

        if let latestID = latestID, let latestIndex = ordered.firstIndex(of: latestID) {
            // 最新版本已经是第一个，无需调整
            if latestIndex != 0 {
                let latest = ordered.remove(at: latestIndex)
                ordered.insert(latest, at: 0)
            }
        }

        return ordered
    }

    /// 获取指定版本的元数据（版本号、发布日期）
    /// 如果获取失败，返回 nil 对应字段，不影响调用方
    public func getVersionMetadata(appID: Int, externalVersionID: String) async -> (version: String?, date: String?) {
        do {
            let dict = try await downloadProduct(appID: appID, externalVersionID: externalVersionID)
            guard let songList = dict["songList"] as? [Any],
                  let item = songList.first as? [String: Any],
                  let metadata = item["metadata"] as? [String: Any] else {
                return (nil, nil)
            }
            let version = metadata["bundleShortVersionString"] as? String
            let date = metadata["releaseDate"] as? String
            return (version, date)
        } catch {
            print("[version-meta] failed for \(externalVersionID): \(error)")
            return (nil, nil)
        }
    }

    // MARK: - File Download

    /// 从下载响应中提取下载 URL
    public func extractDownloadURL(from dict: [String: Any]) -> URL? {
        guard let songList = dict["songList"] as? [Any],
              let item = songList.first as? [String: Any],
              let urlStr = item["URL"] as? String,
              let url = URL(string: urlStr) else {
            return nil
        }
        return url
    }

    /// 下载文件到指定路径，支持进度回调
    public func downloadFile(from url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        print("[download-file] GET \(url.absoluteString)")
        print("[download-file] destination: \(destination.path)")

        let (asyncBytes, response) = try await session.bytes(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppStoreError.downloadFailed(message: "下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let totalBytes = httpResponse.expectedContentLength
        print("[download-file] HTTP 200, totalBytes=\(totalBytes)")

        // 确保目标目录存在
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 如果目标文件已存在，先删除
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        // 创建空文件
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var received: Int64 = 0
        // 按 64KB 缓冲读取，提高性能
        var buffer = Data()
        buffer.reserveCapacity(65536)
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 65536 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if totalBytes > 0 {
                    progress(Double(received) / Double(totalBytes))
                }
            }
        }
        // 写入剩余数据
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        if totalBytes > 0 {
            progress(1.0)
        }

        print("[download-file] download complete, \(received) bytes")
    }

    // MARK: - macOS 包解密

    private static let macChunkSize = 0x8000  // 32KB，与 CSAP_STOREAGENT_CHUNK_SIZE 一致

    /// 从下载响应中提取 dpInfo（macOS 包的解密凭据）
    /// - Returns: dpInfo 数据，如果不存在则为 nil（表示非 macOS 包）
    public func extractDPInfo(from dict: [String: Any]) -> Data? {
        guard let songList = dict["songList"] as? [Any],
              let item = songList.first as? [String: Any],
              let sinfs = item["sinfs"] as? [[String: Any]] else {
            return nil
        }
        var dpInfo: Data?
        for sinf in sinfs {
            if let dp = sinf["dpInfo"] as? Data, !dp.isEmpty {
                if dpInfo != nil && dpInfo != dp {
                    // 冲突的 dpInfo，无法确定
                    return nil
                }
                dpInfo = dp
            }
        }
        return dpInfo
    }

    /// 下载并解密 macOS 应用包
    /// - Parameters:
    ///   - url: 加密包下载 URL
    ///   - destination: 最终解密后的输出路径
    ///   - hardwareID: 硬件 ID
    ///   - dpInfo: 从下载响应提取的 dpInfo
    ///   - assets: SAP 资产（用于加载 StoreAgent）
    ///   - progress: 下载进度回调（0.0 ~ 1.0）
    public func downloadMacPackage(from url: URL, to destination: URL,
                                   hardwareID: Data, dpInfo: Data,
                                   assets: SAPAssets,
                                   progress: @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        let encryptedPath = destination.path + ".ipatool-encrypted"
        let decryptedPath = destination.path + ".ipatool-decrypted"
        let stagePaths = [encryptedPath, decryptedPath]

        // 清理旧的临时文件
        for p in stagePaths {
            if fm.fileExists(atPath: p) {
                try? fm.removeItem(atPath: p)
            }
        }
        defer {
            for p in stagePaths {
                try? fm.removeItem(atPath: p)
            }
        }

        // 1. 下载加密包到临时路径
        let encryptedURL = URL(fileURLWithPath: encryptedPath)
        try await downloadFile(from: url, to: encryptedURL, progress: progress)

        // 2. 打开 StoreAgent 解密器
        let decrypter = SAPSigner.StoreAgentDecrypter(assets: assets)
        try decrypter.open(hardwareID: hardwareID, dpInfo: dpInfo)
        defer { decrypter.close() }

        // 3. 分块解密
        let encryptedHandle = try FileHandle(forReadingFrom: encryptedURL)
        defer { try? encryptedHandle.close() }

        let decryptedURL = URL(fileURLWithPath: decryptedPath)
        if fm.fileExists(atPath: decryptedPath) {
            try fm.removeItem(at: decryptedURL)
        }
        fm.createFile(atPath: decryptedPath, contents: nil)
        let decryptedHandle = try FileHandle(forWritingTo: decryptedURL)
        defer { try? decryptedHandle.close() }

        print("[mac-decrypt] starting chunked decryption, chunkSize=\(Self.macChunkSize)")
        var totalDecrypted: Int64 = 0
        while true {
            let chunk = encryptedHandle.readData(ofLength: Self.macChunkSize)
            if chunk.isEmpty { break }
            var mutableChunk = chunk
            try decrypter.decryptChunk(&mutableChunk)
            try decryptedHandle.write(contentsOf: mutableChunk)
            totalDecrypted += Int64(mutableChunk.count)
        }
        print("[mac-decrypt] complete, \(totalDecrypted) bytes decrypted")

        // 4. 校验解密后的包非空
        let attr = try fm.attributesOfItem(atPath: decryptedPath)
        guard let size = attr[.size] as? Int64, size > 0 else {
            throw AppStoreError.downloadFailed(message: "macOS 包解密失败：输出文件为空")
        }

        // 5. 移动到最终路径
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: decryptedURL, to: destination)
        print("[mac-decrypt] published to \(destination.path)")
    }

    // MARK: - Owned Apps (Purchase History)

    /// 获取当前账号的已购应用列表（通过购买历史 DAAP 接口）
    public func ownedApps(signer: SAPSigner, guid: String) async throws -> [OwnedApp] {
        guard let account = account else {
            throw AppStoreError.notAuthenticated
        }

        let storeFront = account.storeFront.components(separatedBy: ",").first ?? account.storeFront
        var merged: [OwnedApp] = []
        var seen: [Int: OwnedApp] = [:]

        // 遍历两种 storefront（34=Configurator 移动应用, 13=Mac App Store）
        for store in ["34", "13"] {
            let apps = try await fetchOwnedAppsForStorefront(account: account, guid: guid, signer: signer, storeFront: "\(storeFront),\(store)")
            for app in apps {
                if var existing = seen[app.id] {
                    for p in app.platforms where !existing.platforms.contains(p) {
                        existing.platforms.append(p)
                    }
                    if let appDate = app.purchaseDate, let existingDate = existing.purchaseDate, appDate > existingDate {
                        existing.purchaseDate = appDate
                    }
                    seen[app.id] = existing
                } else {
                    seen[app.id] = app
                }
            }
        }

        merged = Array(seen.values)
        // 按购买日期降序
        merged.sort { a, b in
            switch (a.purchaseDate, b.purchaseDate) {
            case (let d1?, let d2?): return d1 > d2
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return merged
    }

    private func fetchOwnedAppsForStorefront(account: AccountInfo, guid: String, signer: SAPSigner, storeFront: String) async throws -> [OwnedApp] {
        // 1. login
        let loginResponse = try await sendDAAPRequest(
            url: URL(string: "\(privatePurchaseDAAPBaseURL)/login")!,
            account: account, guid: guid, storeFront: storeFront, body: nil, signBody: false, signer: signer
        )
        guard let sessionID = dmapUInt(loginResponse, tag: "mlid") else {
            throw AppStoreError.parseFailed
        }

        // 2. update
        let query = "('com.apple.itunes.extended\\-media\\-kind:131072','com.apple.itunes.extended\\-media\\-kind:262144','com.apple.itunes.extended\\-media\\-kind:67108864')"
        let updateBody = "session-id=\(sessionID)&revision-number=(null)&query=\(query)".data(using: .utf8)!
        let updateResponse = try await sendDAAPRequest(
            url: URL(string: "\(privatePurchaseDAAPBaseURL)/update")!,
            account: account, guid: guid, storeFront: storeFront, body: updateBody, signBody: true, signer: signer
        )
        guard let latestVersion = dmapUInt(updateResponse, tag: "musr") else {
            throw AppStoreError.parseFailed
        }

        // 3. items
        let itemsURL = URL(string: "\(privatePurchaseDAAPBaseURL)/databases/\(latestVersion)/items")!
        let itemsBody = dmapItemsBody(sessionID: sessionID, latestVersion: latestVersion, query: query)
        let itemsResponse = try await sendDAAPRequest(
            url: itemsURL, account: account, guid: guid, storeFront: storeFront, body: itemsBody, signBody: true, signer: signer, contentType: "application/x-dmap-tagged"
        )

        return parseOwnedApps(itemsResponse)
    }

    private func sendDAAPRequest(url: URL, account: AccountInfo, guid: String, storeFront: String, body: Data?, signBody: Bool, signer: SAPSigner, contentType: String = "application/x-www-form-urlencoded") async throws -> Data {
        let now = Date()
        let utc = now
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        let dateStr = formatter.string(from: utc)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let clientTime = isoFormatter.string(from: utc)

        var request = defaultRequest(url, method: "POST")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        request.setValue("5", forHTTPHeaderField: "Client-Cloud-DAAP-Request-Reason")
        request.setValue("1.1/Configurator-2.0", forHTTPHeaderField: "Client-Cloud-Purchase-Daap-Version")
        request.setValue("3.12", forHTTPHeaderField: "Client-DAAP-Version")
        request.setValue(dateStr, forHTTPHeaderField: "Date")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(clientTime, forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue("en_US", forHTTPHeaderField: "X-Apple-I-Locale")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Apple-I-TimeZone")
        request.setValue(storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue("\(TimeZone.current.secondsFromGMT() / 60)", forHTTPHeaderField: "X-Apple-TZ")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")
        request.setValue(guid, forHTTPHeaderField: "X-Guid")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = body
            if signBody {
                let signature = try signer.sign(body)
                request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Apple-ActionSignature")
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreError.invalidResponse
        }
        print("[owned-apps] \(url.lastPathComponent) HTTP \(httpResponse.statusCode), \(data.count) bytes")

        guard httpResponse.statusCode == 200 else {
            throw AppStoreError.downloadFailed(message: "DAAP request failed with HTTP \(httpResponse.statusCode)")
        }
        return data
    }

    private func dmapItemsBody(sessionID: UInt32, latestVersion: UInt32, query: String) -> Data {
        let now = Date()
        var payload = Data()
        payload.append(dmapTag("mstc", value: dmapUint32(UInt32(now.timeIntervalSince1970))))
        payload.append(dmapTag("mlid", value: dmapUint32(sessionID)))
        payload.append(dmapTag("mikd", value: Data([2])))
        payload.append(dmapTag("musr", value: dmapUint32(latestVersion)))
        payload.append(dmapTag("mder", value: dmapUint32(0)))
        payload.append(dmapTag("mque", value: query.data(using: .utf8)!))
        payload.append(dmapTag("aetl", value: Data()))
        return dmapTag("adsr", value: payload)
    }

    private func dmapTag(_ name: String, value: Data) -> Data {
        var data = Data()
        data.append(contentsOf: Array(name.utf8))
        var length = UInt32(value.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(value)
        return data
    }

    private func dmapUint32(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    /// 从 DMAP 二进制响应中查找指定 tag 的整数值
    private func dmapUInt(_ data: Data, tag: String) -> UInt32? {
        var result: UInt32?
        walkDMAP(data) { t, payload in
            if result == nil && t == tag {
                if payload.count == 4 {
                    result = payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                } else if payload.count == 8 {
                    result = UInt32(payload.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
                }
            }
        }
        return result
    }

    /// 解析已购应用列表
    private func parseOwnedApps(_ data: Data) -> [OwnedApp] {
        var apps: [OwnedApp] = []
        walkDMAP(data) { tag, payload in
            if tag == "mlit" {
                if let app = parseOwnedApp(payload) {
                    apps.append(app)
                }
            }
        }
        return apps
    }

    private func parseOwnedApp(_ data: Data) -> OwnedApp? {
        var id: Int64 = 0
        var name = ""
        var bundleId = ""
        var version = ""
        var purchaseDate: Date?
        var mediaKind: UInt64 = 0
        var supportedProducts: UInt64 = 0

        walkDMAP(data) { tag, payload in
            switch tag {
            case "aeSI":
                if payload.count == 4 {
                    id = Int64(payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                } else if payload.count == 8 {
                    id = Int64(bitPattern: payload.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
                }
            case "aeBI":
                bundleId = String(data: payload, encoding: .utf8) ?? ""
            case "aeLN":
                name = String(data: payload, encoding: .utf8) ?? ""
            case "minm":
                if name.isEmpty { name = String(data: payload, encoding: .utf8) ?? "" }
            case "aePd":
                version = String(data: payload, encoding: .utf8) ?? ""
            case "asdp":
                if payload.count == 4 {
                    let ts = payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    purchaseDate = Date(timeIntervalSince1970: TimeInterval(ts))
                }
            case "aeMk":
                mediaKind = readDMAPUInt(payload)
            case "aeSS":
                supportedProducts = readDMAPUInt(payload)
            default:
                break
            }
        }

        guard id != 0 else { return nil }

        var platforms: [Platform] = []
        switch mediaKind {
        case 67108864: // Mac
            platforms.append(.macOS)
        case 131072, 262144: // iOS / Arcade
            let mapping: [(mask: UInt64, platform: Platform)] = [
                (1, .iphone), (2, .ipad), (16, .visionOS), (8, .macOS)
            ]
            for item in mapping where supportedProducts & item.mask != 0 {
                platforms.append(item.platform)
            }
        default:
            break
        }

        return OwnedApp(id: Int(id), name: name, bundleId: bundleId, version: version, purchaseDate: purchaseDate, platforms: platforms)
    }

    private func readDMAPUInt(_ payload: Data) -> UInt64 {
        switch payload.count {
        case 1: return UInt64(payload[0])
        case 2: return UInt64(payload.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        case 4: return UInt64(payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        case 8: return payload.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        default: return 0
        }
    }

    /// 递归遍历 DMAP 二进制结构
    private func walkDMAP(_ data: Data, visit: (String, Data) -> Void) {
        var offset = 0
        let containerTags: Set<String> = ["adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd"]
        while offset + 8 <= data.count {
            let tagBytes = data.subdata(in: offset..<offset+4)
            guard let tag = String(data: tagBytes, encoding: .utf8) else { break }
            let length = Int(data.subdata(in: offset+4..<offset+8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + length
            guard payloadEnd <= data.count else { break }
            let payload = data.subdata(in: payloadStart..<payloadEnd)
            visit(tag, payload)
            if containerTags.contains(tag) {
                walkDMAP(payload, visit: visit)
            }
            offset = payloadEnd
        }
    }
}

// MARK: - Errors

public enum AppStoreError: Error, LocalizedError {
    case notAuthenticated
    case invalidResponse
    case parseFailed
    case loginFailed(message: String)
    case requires2FA
    case purchaseFailed(message: String)
    case downloadFailed(message: String)
    case notImplemented

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "未登录 App Store"
        case .invalidResponse: return "无效的服务器响应"
        case .parseFailed: return "解析响应失败"
        case .loginFailed(let msg): return "登录失败: \(msg)"
        case .requires2FA: return "需要双重认证验证码"
        case .purchaseFailed(let msg): return "购买失败: \(msg)"
        case .downloadFailed(let msg): return "下载失败: \(msg)"
        case .notImplemented: return "功能未实现"
        }
    }
}
