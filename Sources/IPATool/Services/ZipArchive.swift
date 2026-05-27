import Foundation

/// 简化的 ZIP 归档读取/写入工具
enum ZipArchive {

    struct Entry {
        let name: String
        let data: Data
        let compressionMethod: UInt16
    }

    static func readEntries(from data: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = 0

        while offset + 30 <= data.count {
            let signature = data.readUInt32(at: offset)
            if signature != 0x04034b50 { break }

            let generalPurpose = data.readUInt16(at: offset + 6)
            let compressionMethod = data.readUInt16(at: offset + 8)
            let compressedSize = data.readUInt32(at: offset + 18)
            _ = data.readUInt32(at: offset + 22) // uncompressedSize
            let fileNameLength = data.readUInt16(at: offset + 26)
            let extraFieldLength = data.readUInt16(at: offset + 28)

            let headerSize = 30 + Int(fileNameLength) + Int(extraFieldLength)
            guard offset + headerSize + Int(compressedSize) <= data.count else { break }

            let nameData = data.subdata(in: (offset + 30)..<(offset + 30 + Int(fileNameLength)))
            // 处理带 bit 11 的 UTF-8 文件名
            let nameEncoding: String.Encoding = (generalPurpose & 0x0800) != 0 ? .utf8 : .utf8
            let name = String(data: nameData, encoding: nameEncoding) ?? "unknown"

            if name.hasSuffix("/") {
                offset += headerSize
                continue
            }

            let rawData: Data
            if compressionMethod == 0 {
                rawData = data.subdata(in: (offset + headerSize)..<(offset + headerSize + Int(compressedSize)))
            } else if compressionMethod == 8 {
                let compressedData = data.subdata(in: (offset + headerSize)..<(offset + headerSize + Int(compressedSize)))
                if let decompressed = try? (compressedData as NSData).decompressed(using: .zlib) as Data {
                    rawData = decompressed
                } else {
                    rawData = compressedData
                }
            } else {
                rawData = Data()
            }

            entries.append(Entry(name: name, data: rawData, compressionMethod: compressionMethod))
            offset += headerSize + Int(compressedSize)
        }

        return entries
    }

    static func createZip(entries: [(name: String, data: Data)]) throws -> Data {
        var result = Data()
        var centralDirectory = Data()
        var localHeaderOffset: UInt32 = 0

        for entry in entries {
            let shouldCompress = entry.data.count > 128
            let finalData: Data
            let compressionMethod: UInt16 = shouldCompress ? 8 : 0

            if shouldCompress, let compressed = try? (entry.data as NSData).compressed(using: .zlib) as Data {
                finalData = compressed
            } else {
                finalData = entry.data
            }

            let crc = CRC32.compute(entry.data)
            let nameData = entry.name.data(using: .utf8)!
            let nameLength = UInt16(nameData.count)

            // Local file header
            let localHeaderSize: UInt32 = 30 + UInt32(nameLength)
            var localHeader = Data()
            localHeader.appendUInt32(0x04034b50)
            localHeader.appendUInt16(20)
            localHeader.appendUInt16(0x0800) // UTF-8
            localHeader.appendUInt16(compressionMethod)
            localHeader.appendUInt16(0)
            localHeader.appendUInt16(0)
            localHeader.appendUInt32(crc)
            localHeader.appendUInt32(UInt32(finalData.count))
            localHeader.appendUInt32(UInt32(entry.data.count))
            localHeader.appendUInt16(nameLength)
            localHeader.appendUInt16(0)
            localHeader.append(nameData)

            result.append(localHeader)
            result.append(finalData)

            // Central directory
            var cdEntry = Data()
            cdEntry.appendUInt32(0x02014b50)
            cdEntry.appendUInt16(20)
            cdEntry.appendUInt16(20)
            cdEntry.appendUInt16(0x0800)
            cdEntry.appendUInt16(compressionMethod)
            cdEntry.appendUInt16(0)
            cdEntry.appendUInt16(0)
            cdEntry.appendUInt32(crc)
            cdEntry.appendUInt32(UInt32(finalData.count))
            cdEntry.appendUInt32(UInt32(entry.data.count))
            cdEntry.appendUInt16(nameLength)
            cdEntry.appendUInt16(0)
            cdEntry.appendUInt16(0)
            cdEntry.appendUInt16(0)
            cdEntry.appendUInt16(0)
            cdEntry.appendUInt32(0)
            cdEntry.appendUInt32(localHeaderOffset)
            cdEntry.append(nameData)
            centralDirectory.append(cdEntry)

            localHeaderOffset += localHeaderSize + UInt32(finalData.count)
        }

        let cdOffset = UInt32(result.count)
        result.append(centralDirectory)

        var eocd = Data()
        eocd.appendUInt32(0x06054b50)
        eocd.appendUInt16(0)
        eocd.appendUInt16(0)
        eocd.appendUInt16(UInt16(entries.count))
        eocd.appendUInt16(UInt16(entries.count))
        eocd.appendUInt32(UInt32(centralDirectory.count))
        eocd.appendUInt32(cdOffset)
        eocd.appendUInt16(0)

        result.append(eocd)
        return result
    }
}

// MARK: - CRC32

enum CRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc = crc >> 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Data helpers

extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append($0.bindMemory(to: UInt8.self)) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append($0.bindMemory(to: UInt8.self)) }
    }
}