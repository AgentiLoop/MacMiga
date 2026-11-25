public enum LHAError: Error, Equatable {
    /// The archive ends inside a header or inside a member's data.
    case truncated
    /// No valid member header at this byte offset.
    case badHeader(offset: Int)
    /// A header level other than 0, 1 or 2.
    case unsupportedHeaderLevel(Int)
    /// A compression method this reader does not implement (for example `-lh1-`).
    case unsupportedMethod(String)
    /// The compressed data of the named member is not a valid bit stream.
    case corruptData(String)
    /// The named member unpacked to data whose CRC-16 differs from the one in its header.
    case checksumMismatch(String)
}

/// Reader for LHA (`.lha`, `.lzh`) archives, the usual packaging of Amiga software.
///
/// Header levels 0, 1 and 2 are read, with the file name and directory extended headers.
/// Methods: `-lh0-` (stored), `-lh4-`…`-lh7-` (LZ77 with static Huffman codes and a 4, 8,
/// 32 or 64 KiB window) and `-lhd-` (directory). Every unpacked member is checked against
/// its CRC-16. Names are taken as ISO Latin-1, the Amiga's character set. For archives
/// made on an Amiga the attribute byte is kept as the protection bits and a comment
/// stored after the name is kept as the file comment.
public enum LHA {
    public static func unpack(_ archive: [UInt8]) throws -> [VolumeEntry] {
        var entries: [VolumeEntry] = []
        var offset = 0
        func le16(_ at: Int) -> Int { Int(archive[at]) | Int(archive[at + 1]) << 8 }
        func le32(_ at: Int) -> Int { le16(at) | le16(at + 2) << 16 }

        while offset < archive.count, archive[offset] != 0 {
            guard offset + 24 <= archive.count else { throw LHAError.truncated }
            let method = String(decoding: archive[offset + 2..<offset + 7], as: UTF8.self)
            guard method.hasPrefix("-l"), method.hasSuffix("-") else { throw LHAError.badHeader(offset: offset) }
            let packedSize = le32(offset + 7)
            let originalSize = le32(offset + 11)
            let time = le32(offset + 15)
            let attribute = archive[offset + 19]
            let level = Int(archive[offset + 20])

            var name: [UInt8] = []
            var directory: [UInt8] = []
            var crc = 0
            var system: UInt8 = 0
            var extendedAt = 0      // first extended header, 0 = none
            var extendedSize = 0    // size of the first extended header
            var dataStart = 0
            var dataSize = packedSize
            switch level {
            case 0, 1:
                let headerSize = Int(archive[offset]) + 2
                let nameLength = Int(archive[offset + 21])
                let fixed = 22 + nameLength + 2 + (level == 1 ? 3 : 0)
                guard headerSize >= fixed, offset + headerSize <= archive.count else { throw LHAError.truncated }
                let sum = archive[offset + 2..<offset + headerSize].reduce(UInt8(0), &+)
                guard sum == archive[offset + 1] else { throw LHAError.badHeader(offset: offset) }
                name = Array(archive[offset + 22..<offset + 22 + nameLength])
                crc = le16(offset + 22 + nameLength)
                dataStart = offset + headerSize
                if level == 1 {
                    system = archive[offset + 24 + nameLength]
                    extendedSize = le16(offset + headerSize - 2)
                    extendedAt = dataStart
                }
            case 2:
                let headerSize = le16(offset)
                guard headerSize >= 26, offset + headerSize <= archive.count else { throw LHAError.truncated }
                crc = le16(offset + 21)
                system = archive[offset + 23]
                extendedSize = le16(offset + 24)
                extendedAt = offset + 26
                dataStart = offset + headerSize
            default:
                throw LHAError.unsupportedHeaderLevel(level)
            }
            // Extended headers: type byte, body, then the size of the next one (0 ends the chain).
            while extendedSize != 0 {
                guard extendedSize >= 3, extendedAt + extendedSize <= archive.count else { throw LHAError.truncated }
                let body = archive[extendedAt + 1..<extendedAt + extendedSize - 2]
                switch archive[extendedAt] {
                case 0x01: name = Array(body)
                case 0x02: directory = Array(body)
                default: break
                }
                let next = le16(extendedAt + extendedSize - 2)
                extendedAt += extendedSize
                if level == 1 { // level 1 counts its extended headers in the packed size
                    dataStart = extendedAt
                    dataSize -= extendedSize
                }
                extendedSize = next
            }
            guard dataSize >= 0, dataStart + dataSize <= archive.count else { throw LHAError.truncated }

            // An Amiga archiver appends the file comment to the name after a NUL.
            var comment: [UInt8] = []
            if let end = name.firstIndex(of: 0) {
                comment = Array(name[(end + 1)...])
                name = Array(name[..<end])
            }
            // Directories are separated by `/` or `\` in the name and by $FF in the extended header.
            let path = (directory + [0xFF] + name)
                .split(whereSeparator: { $0 == 0xFF || $0 == 0x2F || $0 == 0x5C })
                .map { String(String.UnicodeScalarView($0.map { Unicode.Scalar($0) })) }
                .filter { $0 != "." && $0 != ".." }
            let label = path.joined(separator: "/")

            let packed = archive[dataStart..<dataStart + dataSize]
            var contents: [UInt8]?
            switch method {
            case "-lhd-": contents = nil
            case "-lh0-": contents = Array(packed.prefix(originalSize))
            case "-lh4-", "-lh5-": contents = try expand(packed, size: originalSize, positionCodes: 14, positionBits: 4, label)
            case "-lh6-": contents = try expand(packed, size: originalSize, positionCodes: 16, positionBits: 5, label)
            case "-lh7-": contents = try expand(packed, size: originalSize, positionCodes: 17, positionBits: 5, label)
            default: throw LHAError.unsupportedMethod(method)
            }
            if let contents {
                guard contents.count == originalSize else { throw LHAError.truncated }
                guard crc16(contents) == crc else { throw LHAError.checksumMismatch(label) }
            }
            if !path.isEmpty {
                var entry = VolumeEntry(path: path, contents: contents, date: date(time, unix: level == 2))
                if system == 0x41 { entry.protection = UInt32(attribute) } // 'A': made on an Amiga
                entry.comment = String(String.UnicodeScalarView(comment.map { Unicode.Scalar($0) }))
                entries.append(entry)
            }
            offset = dataStart + dataSize
        }
        return entries
    }

    /// Level 0/1 headers hold an MS-DOS date and time (local), level 2 seconds since 1970.
    static func date(_ value: Int, unix: Bool) -> AmigaDate {
        if unix {
            return AmigaDate(days: max(0, value / 86_400 - 2_922), minutes: value % 86_400 / 60,
                             ticks: value % 60 * 50)
        }
        return AmigaDate(year: 1980 + (value >> 25 & 0x7F), month: max(1, value >> 21 & 0x0F),
                         day: max(1, value >> 16 & 0x1F), hour: value >> 11 & 0x1F,
                         minute: value >> 5 & 0x3F, second: (value & 0x1F) * 2)
    }

    /// CRC-16 as LHA uses it (polynomial `$A001` reflected, initial value 0; "CRC-16/ARC").
    public static func crc16(_ bytes: [UInt8]) -> Int {
        var crc: UInt16 = 0
        for byte in bytes { crc = crcTable[Int(UInt8(truncatingIfNeeded: crc) ^ byte)] ^ crc >> 8 }
        return Int(crc)
    }

    private static let crcTable: [UInt16] = (0..<256).map { index in
        var value = UInt16(index)
        for _ in 0..<8 { value = value & 1 != 0 ? value >> 1 ^ 0xA001 : value >> 1 }
        return value
    }

    /// Reads the packed data most significant bit first; past the end it supplies zero bits.
    private struct BitReader {
        let bytes: ArraySlice<UInt8>
        var index: Int
        var mask: UInt8 = 0x80

        init(_ bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            index = bytes.startIndex
        }

        mutating func bit() -> Int {
            guard index < bytes.endIndex else { return 0 }
            let value = bytes[index] & mask != 0 ? 1 : 0
            mask >>= 1
            if mask == 0 { mask = 0x80; index += 1 }
            return value
        }

        mutating func bits(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count { value = value << 1 | bit() }
            return value
        }
    }

    /// A canonical Huffman code given by its code lengths: shorter codes first, and symbols
    /// in ascending order within one length. `single` is a code with one symbol and no bits.
    private struct Code {
        var counts = [Int](repeating: 0, count: 17)
        var symbols: [Int] = []
        var single: Int?

        init(single: Int) { self.single = single }

        init(lengths: [Int]) {
            for length in lengths where length > 0 { counts[length] += 1 }
            symbols = lengths.indices.filter { lengths[$0] > 0 }.sorted { (lengths[$0], $0) < (lengths[$1], $1) }
        }

        func decode(_ reader: inout BitReader) -> Int? {
            if let single { return single }
            var code = 0, first = 0, index = 0
            for length in 1...16 {
                code |= reader.bit()
                let count = counts[length]
                if code - first < count { return symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            return nil
        }
    }

    /// The `-lh4-`…`-lh7-` decoder. The data comes in blocks: a 16-bit count of codes, then
    /// the code lengths of three Huffman codes (one that packs the lengths of the second,
    /// the literal/match-length code with 510 symbols, and the match-position code), then
    /// the codes. Symbols 0–255 are literal bytes, 256–509 copy 3–256 bytes from the window.
    private static func expand(_ packed: ArraySlice<UInt8>, size: Int, positionCodes: Int, positionBits: Int,
                               _ label: String) throws -> [UInt8] {
        var reader = BitReader(packed)
        var output = [UInt8]()
        output.reserveCapacity(size)

        /// Lengths 0–6 take three bits; 7 and more continue in unary. After `special`
        /// entries a 2-bit count of zero lengths follows.
        func readLengthCode(symbols: Int, bits: Int, special: Int) -> Code {
            let count = reader.bits(bits)
            if count == 0 { return Code(single: reader.bits(bits)) }
            var lengths = [Int](repeating: 0, count: symbols)
            var index = 0
            while index < min(count, symbols) {
                var length = reader.bits(3)
                if length == 7 { while reader.bit() == 1 && length < 16 { length += 1 } }
                lengths[index] = length
                index += 1
                if index == special { index += reader.bits(2) }
            }
            return Code(lengths: lengths)
        }

        while output.count < size {
            guard reader.index < reader.bytes.endIndex else { throw LHAError.corruptData(label) }
            var remaining = reader.bits(16)
            if remaining == 0 { remaining = 0x1_0000 }
            let lengthCode = readLengthCode(symbols: 19, bits: 5, special: 3)
            var literalCode: Code
            let literals = reader.bits(9)
            if literals == 0 {
                literalCode = Code(single: reader.bits(9))
            } else {
                var lengths = [Int](repeating: 0, count: 510)
                var index = 0
                while index < min(literals, 510) {
                    guard let symbol = lengthCode.decode(&reader) else { throw LHAError.corruptData(label) }
                    switch symbol {
                    case 0: index += 1                       // one zero length
                    case 1: index += reader.bits(4) + 3      // 3–18 zero lengths
                    case 2: index += reader.bits(9) + 20     // 20–531 zero lengths
                    default:
                        lengths[index] = symbol - 2
                        index += 1
                    }
                }
                literalCode = Code(lengths: lengths)
            }
            let positionCode = readLengthCode(symbols: positionCodes, bits: positionBits, special: -1)

            while remaining > 0, output.count < size {
                remaining -= 1
                guard let symbol = literalCode.decode(&reader) else { throw LHAError.corruptData(label) }
                if symbol < 256 {
                    output.append(UInt8(symbol))
                    continue
                }
                guard let slot = positionCode.decode(&reader) else { throw LHAError.corruptData(label) }
                let distance = slot < 2 ? slot : 1 << (slot - 1) | reader.bits(slot - 1)
                var source = output.count - distance - 1
                for _ in 0..<min(symbol - 253, size - output.count) {
                    // The window starts out filled with spaces.
                    output.append(source >= 0 ? output[source] : 0x20)
                    source += 1
                }
            }
        }
        return output
    }
}
