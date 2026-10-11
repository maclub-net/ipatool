import Foundation
import CSAP

/// SAP 签名器，封装 C 层 CSAP API
public class SAPSigner {
    private var signer: OpaquePointer?
    private let assets: SAPAssets

    public init(assets: SAPAssets) {
        self.assets = assets
    }

    deinit {
        close()
    }

    /// 在缓存目录中查找 libunicorn.2.dylib
    private static func findUnicornDylib() -> String? {
        let home = NSHomeDirectory()
        let base = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Caches/ipatool/unicorn/2.1.4", isDirectory: true)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return nil
        }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("libunicorn.2.dylib")
            if fm.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    /// 创建并设置签名器
    /// - Parameters:
    ///   - hardwareID: 硬件 ID（1-20 字节）
    ///   - version: SAP 协议版本（默认 200）
    ///   - certificateURL: 证书获取 URL
    ///   - setupURL: setup 交换 URL
    public func setup(hardwareID: Data, version: UInt32 = 200,
                      certificateURL: URL, setupURL: URL) async throws {
        guard signer == nil else { return }

        // 加载 libunicorn
        guard let unicornPath = Self.findUnicornDylib() else {
            throw SAPError.creationFailed
        }
        guard csap_uc_load(unicornPath) == 0 else {
            throw SAPError.creationFailed
        }

        // 加载资产
        let coreFP = try assets.load(.coreFP)
        let commerceCore = try assets.load(.commerceCore)
        let commerceKit = try assets.load(.commerceKit)
        let icxs = try? assets.load(.coreFPICXS)

        var hwID = [UInt8](hardwareID)
        var coreFPBytes = [UInt8](coreFP)
        var commerceCoreBytes = [UInt8](commerceCore)
        var commerceKitBytes = [UInt8](commerceKit)
        var icxsBytes = icxs != nil ? [UInt8](icxs!) : []

        let created = coreFPBytes.withUnsafeMutableBufferPointer { coreFPBuf in
            commerceCoreBytes.withUnsafeMutableBufferPointer { ccBuf in
                commerceKitBytes.withUnsafeMutableBufferPointer { ckBuf in
                    icxsBytes.withUnsafeMutableBufferPointer { icxsBuf in
                        hwID.withUnsafeMutableBufferPointer { hwBuf in
                            csap_signer_create(
                                coreFPBuf.baseAddress, coreFPBuf.count,
                                ccBuf.baseAddress, ccBuf.count,
                                ckBuf.baseAddress, ckBuf.count,
                                icxs != nil ? icxsBuf.baseAddress : nil, icxsBuf.count,
                                hwBuf.baseAddress, hwBuf.count,
                                version
                            )
                        }
                    }
                }
            }
        }

        guard let s = created else {
            throw SAPError.creationFailed
        }
        self.signer = s
        print("[SAP] signer created: \(s)")

        // 获取证书
        let certificate = try await fetchCertificate(from: certificateURL)
        print("[SAP] certificate fetched, \(certificate.count) bytes")

        // 第一次 exchange
        var setupRequest: Data?
        var state: Int32 = 0
        try exchange(input: certificate) { output, result in
            setupRequest = output
            state = result
        }
        print("[SAP] exchange #1 state=\(state), output=\(setupRequest?.count ?? 0) bytes")

        guard state == 1 else {
            throw SAPError.setupFailed(state: state)
        }
        guard let request = setupRequest, !request.isEmpty else {
            throw SAPError.emptySetupRequest
        }

        // 发送 setup 请求
        let reply = try await sendSetupRequest(to: setupURL, request: request)
        print("[SAP] setup reply received, \(reply.count) bytes")

        // 第二次 exchange
        try exchange(input: reply) { _, result in
            state = result
        }
        print("[SAP] exchange #2 state=\(state)")

        guard state == 0 else {
            throw SAPError.setupFailed(state: state)
        }
        print("[SAP] setup complete")
    }

    /// 签名数据
    public func sign(_ input: Data) throws -> Data {
        guard let signer = signer else {
            throw SAPError.notSetup
        }

        var inputBytes = [UInt8](input)
        var outputPtr: UnsafeMutablePointer<UInt8>?
        var outputLen: Int = 0

        let ret = inputBytes.withUnsafeMutableBufferPointer { buf in
            csap_signer_sign(signer, buf.baseAddress, buf.count, &outputPtr, &outputLen)
        }

        guard ret == 0, let ptr = outputPtr, outputLen > 0 else {
            throw SAPError.signFailed
        }

        let data = Data(bytes: ptr, count: outputLen)
        csap_free(ptr)
        return data
    }

    public func close() {
        if let signer = signer {
            csap_signer_free(signer)
            self.signer = nil
        }
    }

    // MARK: - macOS 包解密 (StoreAgent)

    /// StoreAgent 解密器，用于解密 macOS 应用安装包
    public class StoreAgentDecrypter {
        private var agent: OpaquePointer?
        private let assets: SAPAssets

        public init(assets: SAPAssets) {
            self.assets = assets
        }

        deinit { close() }

        /// 打开 StoreAgent 会话
        /// - Parameters:
        ///   - hardwareID: 硬件 ID
        ///   - dpInfo: 从下载响应 sinfs 中提取的 dpInfo
        public func open(hardwareID: Data, dpInfo: Data) throws {
            guard agent == nil else { return }

            let coreFP = try assets.load(.coreFP)
            let commerceCore = try assets.load(.commerceCore)
            let commerceKit = try assets.load(.commerceKit)
            let icxs = try? assets.load(.coreFPICXS)
            let storeagent = try assets.load(.storeagent)

            var coreFPBytes = [UInt8](coreFP)
            var ccBytes = [UInt8](commerceCore)
            var ckBytes = [UInt8](commerceKit)
            var icxsBytes = icxs != nil ? [UInt8](icxs!) : []
            var saBytes = [UInt8](storeagent)
            var hwBytes = [UInt8](hardwareID)
            var dpBytes = [UInt8](dpInfo)

            let opened = coreFPBytes.withUnsafeMutableBufferPointer { coreFPBuf in
                ccBytes.withUnsafeMutableBufferPointer { ccBuf in
                    ckBytes.withUnsafeMutableBufferPointer { ckBuf in
                        icxsBytes.withUnsafeMutableBufferPointer { icxsBuf in
                            saBytes.withUnsafeMutableBufferPointer { saBuf in
                                hwBytes.withUnsafeMutableBufferPointer { hwBuf in
                                    dpBytes.withUnsafeMutableBufferPointer { dpBuf in
                                        csap_storeagent_open(
                                            coreFPBuf.baseAddress, coreFPBuf.count,
                                            ccBuf.baseAddress, ccBuf.count,
                                            ckBuf.baseAddress, ckBuf.count,
                                            icxs != nil ? icxsBuf.baseAddress : nil, icxsBuf.count,
                                            saBuf.baseAddress, saBuf.count,
                                            hwBuf.baseAddress, hwBuf.count,
                                            dpBuf.baseAddress, dpBuf.count
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            guard let a = opened else {
                throw SAPError.storeAgentOpenFailed
            }
            self.agent = a
            print("[StoreAgent] opened, agent=\(a)")
        }

        /// 解密一块数据（原地解密），块大小应为 CSAP_STOREAGENT_CHUNK_SIZE (0x8000)
        public func decryptChunk(_ data: inout Data) throws {
            guard let agent = agent else {
                throw SAPError.storeAgentNotOpen
            }
            let size = data.count
            let ret = data.withUnsafeMutableBytes { buf -> Int32 in
                guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                return csap_storeagent_decrypt_chunk(agent, ptr, size)
            }
            guard ret == 0 else {
                throw SAPError.storeAgentDecryptFailed(status: ret)
            }
        }

        public func close() {
            if let agent = agent {
                csap_storeagent_close(agent)
                self.agent = nil
            }
        }
    }

    // MARK: - Private

    private func exchange(input: Data, _ handler: (Data, Int32) -> Void) throws {
        guard let signer = signer else {
            print("[SAP] exchange failed: signer is nil")
            throw SAPError.notSetup
        }

        var inputBytes = [UInt8](input)
        var outputPtr: UnsafeMutablePointer<UInt8>?
        var outputLen: Int = 0
        var result: Int32 = 0

        let ret = inputBytes.withUnsafeMutableBufferPointer { buf in
            csap_signer_exchange(signer, buf.baseAddress, buf.count,
                                 &outputPtr, &outputLen, &result)
        }

        guard ret == 0 else {
            print("[SAP] exchange failed: ret=\(ret)")
            throw SAPError.exchangeFailed
        }

        let output = outputPtr.map { Data(bytes: $0, count: outputLen) } ?? Data()
        if let ptr = outputPtr { csap_free(ptr) }
        handler(output, result)
    }

    /// 从可能带有 <Document> 包装的 XML 中提取并解析 plist
    private func parsePlist(from data: Data) -> [String: Any]? {
        // 尝试直接解析
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dict = plist as? [String: Any] {
            return dict
        }
        // 提取 <plist>...</plist> 后再解析
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

    private func fetchCertificate(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6 (KHTML, like Gecko)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SAPError.networkFailed
        }

        // 解析 plist 中的 sign-sap-setup-cert
        guard let dict = parsePlist(from: data),
              let cert = dict["sign-sap-setup-cert"] as? Data else {
            throw SAPError.certificateParseFailed
        }
        return cert
    }

    private func sendSetupRequest(to url: URL, request: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        req.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6 (KHTML, like Gecko)",
                     forHTTPHeaderField: "User-Agent")

        let plist = ["sign-sap-setup-buffer": request]
        req.httpBody = try PropertyListSerialization.data(fromPropertyList: plist,
                                                           format: .xml, options: 0)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SAPError.networkFailed
        }

        guard let dict = parsePlist(from: data),
              let buffer = dict["sign-sap-setup-buffer"] as? Data else {
            throw SAPError.setupParseFailed
        }
        return buffer
    }
}

// MARK: - Errors

public enum SAPError: Error {
    case creationFailed
    case notSetup
    case exchangeFailed
    case signFailed
    case setupFailed(state: Int32)
    case emptySetupRequest
    case networkFailed
    case certificateParseFailed
    case setupParseFailed
    case storeAgentOpenFailed
    case storeAgentNotOpen
    case storeAgentDecryptFailed(status: Int32)
}

// MARK: - Assets

public struct SAPAssets {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public enum AssetType: String {
        case coreFP = "CoreFP"
        case commerceCore = "CommerceCore"
        case commerceKit = "CommerceKit"
        case coreFPICXS = "CoreFP.icxs"
        case storeagent = "storeagent"
    }

    public func load(_ type: AssetType) throws -> Data {
        let url = directory.appendingPathComponent(type.rawValue)
        return try Data(contentsOf: url)
    }

    public static var defaultCacheDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Caches/ipatool/sap/apple-assets-v2")
    }
}
