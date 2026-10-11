import Foundation
import CSAP

// IPAToolCore 核心库
public struct IPAToolCore {
    public init() {}

    /// 测试 Unicorn 引擎能否正常工作
    /// 执行 `mov rax, 42; ret`，验证 RAX 返回 42
    public static func testUnicorn(dylibPath: String) -> Bool {
        // 加载 unicorn
        guard csap_uc_load(dylibPath) == 0 else {
            print("[test] failed to load unicorn")
            return false
        }
        defer { csap_uc_unload() }

        // 打开 x86-64 引擎
        guard let uc = csap_uc_open(Int32(CSAP_UC_ARCH_X86), Int32(CSAP_UC_MODE_64)) else {
            print("[test] failed to open unicorn engine")
            return false
        }
        defer { _ = csap_uc_close(uc) }

        // 映射 1MB 可执行内存
        let codeAddr: UInt64 = 0x100000
        let codeSize: UInt64 = 0x100000
        guard csap_uc_mem_map(uc, codeAddr, codeSize, UInt32(CSAP_UC_PROT_ALL)) == 0 else {
            print("[test] failed to map memory")
            return false
        }

        // mov rax, 42; ret
        // 48 c7 c0 2a 00 00 00   mov rax, 42
        // c3                     ret
        var code: [UInt8] = [0x48, 0xc7, 0xc0, 0x2a, 0x00, 0x00, 0x00, 0xc3]
        guard csap_uc_mem_write(uc, codeAddr, &code, UInt64(code.count)) == 0 else {
            print("[test] failed to write code")
            return false
        }

        // 设置 RSP 指向有效栈，并在栈顶压入返回地址（结束地址）
        let stackAddr: UInt64 = 0x200000
        let stackSize: UInt64 = 0x100000
        guard csap_uc_mem_map(uc, stackAddr, stackSize, UInt32(CSAP_UC_PROT_ALL)) == 0 else {
            print("[test] failed to map stack")
            return false
        }
        let rsp = stackAddr + stackSize - 8
        guard csap_uc_reg_write(uc, Int32(CSAP_REG_RSP.rawValue), rsp) == 0 else {
            print("[test] failed to set RSP")
            return false
        }

        // 执行代码，结束地址设为 ret 之后
        // ret 会从栈弹出返回地址，所以将返回地址设为 endAddr
        let endAddr = codeAddr + UInt64(code.count)
        var returnAddr = endAddr
        guard csap_uc_mem_write(uc, rsp, &returnAddr, 8) == 0 else {
            print("[test] failed to write return address")
            return false
        }

        let ret = csap_uc_emu_start(uc, codeAddr, endAddr, 0, 0)
        guard ret == 0 else {
            print("[test] emu_start failed: \(String(cString: csap_uc_strerror(ret)))")
            return false
        }

        // 读取 RAX
        var rax: UInt64 = 0
        guard csap_uc_reg_read(uc, Int32(CSAP_REG_RAX.rawValue), &rax) == 0 else {
            print("[test] failed to read RAX")
            return false
        }

        let ok = rax == 42
        print("[test] unicorn \(ok ? "PASS" : "FAIL"): RAX = \(rax) (expected 42)")
        return ok
    }

    /// 测试 Mach-O 镜像解析
    public static func testMachImage(path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("[test] failed to read file: \(path)")
            return false
        }

        let bytes = [UInt8](data)
        guard let image = csap_macho_open(path, bytes, UInt64(bytes.count)) else {
            print("[test] failed to open Mach-O image")
            return false
        }
        defer { csap_macho_free(image) }

        print("[test] image: \(path)")
        print("[test]   segments: \(image.pointee.segment_count)")
        print("[test]   binds: \(image.pointee.bind_count)")
        print("[test]   rebases: \(image.pointee.rebase_count)")
        print("[test]   base: 0x\(String(image.pointee.base, radix: 16))")

        // 列出 segments
        for i in 0..<Int(image.pointee.segment_count) {
            let seg = image.pointee.segments[i]
            let name = withUnsafePointer(to: seg.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
            }
            print("[test]   seg[\(i)] \(name) addr=0x\(String(seg.address, radix: 16)) size=0x\(String(seg.size, radix: 16))")
        }

        // 测试导出符号查找
        var addr: UInt64 = 0
        let testSymbols = ["_CKAdoptionInfoPlistPath", "_CKDownloadDirectory", "dyld_stub_binder"]
        for sym in testSymbols {
            if csap_macho_export(image, sym, 0, &addr) == 0 {
                print("[test]   export '\(sym)' = 0x\(String(addr, radix: 16))")
            } else {
                print("[test]   export '\(sym)' NOT FOUND")
            }
        }

        return true
    }

    /// 测试 SAP 机器加载
    public static func testMachine(assetsDir: String, unicornPath: String) -> Bool {
        // 加载 unicorn
        guard csap_uc_load(unicornPath) == 0 else {
            print("[test] failed to load unicorn")
            return false
        }
        defer { csap_uc_unload() }

        let fm = FileManager.default
        let coreFPPath = "\(assetsDir)/CoreFP"
        let commerceCorePath = "\(assetsDir)/CommerceCore"
        let commerceKitPath = "\(assetsDir)/CommerceKit"
        let icxsPath = "\(assetsDir)/CoreFP.icxs"

        guard let coreFP = try? Data(contentsOf: URL(fileURLWithPath: coreFPPath)),
              let commerceCore = try? Data(contentsOf: URL(fileURLWithPath: commerceCorePath)),
              let commerceKit = try? Data(contentsOf: URL(fileURLWithPath: commerceKitPath)) else {
            print("[test] failed to read framework assets")
            return false
        }
        let icxs = try? Data(contentsOf: URL(fileURLWithPath: icxsPath))

        var coreFPBytes = [UInt8](coreFP)
        var commerceCoreBytes = [UInt8](commerceCore)
        var commerceKitBytes = [UInt8](commerceKit)
        var icxsBytes = icxs != nil ? [UInt8](icxs!) : []

        let machine: OpaquePointer? = coreFPBytes.withUnsafeMutableBufferPointer { coreFPBuf in
            commerceCoreBytes.withUnsafeMutableBufferPointer { ccBuf in
                commerceKitBytes.withUnsafeMutableBufferPointer { ckBuf in
                    if icxs != nil {
                        return icxsBytes.withUnsafeMutableBufferPointer { icxsBuf in
                            csap_machine_open(
                                coreFPBuf.baseAddress, coreFPBuf.count,
                                ccBuf.baseAddress, ccBuf.count,
                                ckBuf.baseAddress, ckBuf.count,
                                icxsBuf.baseAddress, icxsBuf.count
                            )
                        }
                    } else {
                        return csap_machine_open(
                            coreFPBuf.baseAddress, coreFPBuf.count,
                            ccBuf.baseAddress, ccBuf.count,
                            ckBuf.baseAddress, ckBuf.count,
                            nil, 0
                        )
                    }
                }
            }
        }

        guard let m = machine else {
            print("[test] failed to open SAP machine")
            return false
        }
        defer { csap_machine_close(m) }

        print("[test] SAP machine opened successfully")

        // 尝试 initialize（使用假硬件 ID）
        var hwID: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        var context: UInt64 = 0
        let ret = hwID.withUnsafeMutableBufferPointer { hwBuf in
            csap_machine_initialize(m, hwBuf.baseAddress, hwBuf.count, &context)
        }
        if ret == 0 {
            print("[test]   initialize OK, context = 0x\(String(context, radix: 16))")
        } else {
            print("[test]   initialize FAILED (code \(ret))")
        }

        return true
    }
}
