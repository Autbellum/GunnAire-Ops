import Foundation

/// Small uncompressed ZIP writer for native Office exports. No executable content or ZIP64.
enum StoredZIP {
    static func encode(_ files: [(String, Data)]) throws -> Data {
        try require(files.count <= 65535, "Too many workbook parts.")
        var output = Data(), directory = Data()
        for (path, bytes) in files {
            let name = Data(path.utf8)
            try require(name.count <= 65535 && bytes.count < Int(UInt32.max) && output.count < Int(UInt32.max), "Workbook exceeds ZIP size limits.")
            let offset = UInt32(output.count), size = UInt32(bytes.count)
            var crc: UInt32 = 0xffffffff
            for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
            crc ^= 0xffffffff
            output.u32(0x04034b50); output.u16(20); output.u16(0x800); output.u16(0); output.u16(0); output.u16(33)
            output.u32(crc); output.u32(size); output.u32(size); output.u16(UInt16(name.count)); output.u16(0); output.append(name); output.append(bytes)
            directory.u32(0x02014b50); directory.u16(20); directory.u16(20); directory.u16(0x800); directory.u16(0); directory.u16(0); directory.u16(33)
            directory.u32(crc); directory.u32(size); directory.u32(size); directory.u16(UInt16(name.count))
            for _ in 0..<4 { directory.u16(0) }
            directory.u32(0); directory.u32(offset); directory.append(name)
        }
        try require(output.count + directory.count < Int(UInt32.max), "Workbook exceeds ZIP size limits.")
        let start = UInt32(output.count); output.append(directory)
        output.u32(0x06054b50); output.u16(0); output.u16(0); output.u16(UInt16(files.count)); output.u16(UInt16(files.count))
        output.u32(UInt32(directory.count)); output.u32(start); output.u16(0)
        return output
    }
}
private extension Data {
    mutating func u16(_ value: UInt16) { append(UInt8(value & 255)); append(UInt8(value >> 8)) }
    mutating func u32(_ value: UInt32) { u16(UInt16(value & 65535)); u16(UInt16(value >> 16)) }
}
