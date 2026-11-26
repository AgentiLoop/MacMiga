public enum DMSError: Error, Equatable {
    /// The file does not start with a valid `DMS!` header.
    case notDMS
    /// The archive is encrypted (a password is needed) or holds files (FMS), not a disk.
    case unsupported(String)
    /// A track header or the data after it is cut short or fails its CRC.
    case corruptTrack(Int)
    /// A track unpacked to data whose checksum differs from the one in its header.
    case checksumMismatch(Int)
}

/// Reader for DMS (Disk Masher System) archives, the usual packaging of Amiga demos and
/// games: a 56-byte header, then one record per cylinder (two tracks, 11,264 bytes for a
/// DD disk) with a 20-byte `TR` header. A port of xDMS 1.3 by Andre Rodrigues de la Rocha
/// (public domain), covering every mode: none, simple (run-length), quick, medium, deep
/// (LZ with an adaptive Huffman code) and heavy 1 and 2 (LZH). Encrypted archives are
/// not read. The decoders keep their dictionary from one cylinder to the next unless a
/// cylinder's flags say otherwise, so cylinders are unpacked in the order stored.
public enum DMS {
    /// Unpacks the archive into an ADF image of 80 cylinders (cylinders the archive lacks
    /// read as zeros). The banner, `FILE_ID.DIZ` and fake boot block records are skipped.
    public static func unpack(_ archive: [UInt8]) throws -> [UInt8] {
        func word(_ at: Int) -> Int { Int(archive[at]) << 8 | Int(archive[at + 1]) }
        guard archive.count >= 56, archive.starts(with: Array("DMS!".utf8)),
              word(54) == Int(crc16(archive[4..<54])) else { throw DMSError.notDMS }
        let info = word(10), diskType = word(50)
        if info & 2 != 0 { throw DMSError.unsupported("encrypted archive") }
        if diskType == 7 { throw DMSError.unsupported("FMS file archive") }

        var unpacker = Unpacker()
        var adf: [UInt8] = []
        var offset = 56
        while offset + 20 <= archive.count, archive[offset] == 0x54, archive[offset + 1] == 0x52 { // "TR"
            let number = word(offset + 2)
            guard word(offset + 18) == Int(crc16(archive[offset..<offset + 18])) else { throw DMSError.corruptTrack(number) }
            let packed = word(offset + 6), firstPass = word(offset + 8), length = word(offset + 10)
            let flags = archive[offset + 12], mode = archive[offset + 13]
            let sum = word(offset + 14), crc = word(offset + 16)
            offset += 20
            guard offset + packed <= archive.count, Int(crc16(archive[offset..<offset + packed])) == crc else {
                throw DMSError.corruptTrack(number)
            }
            let data = Array(archive[offset..<offset + packed])
            offset += packed
            guard number < 80, length > 2048 else { continue }
            let track = try unpacker.unpack(data, firstPass: firstPass, length: length, mode: mode, flags: flags, number: number)
            guard track.reduce(0, { ($0 + Int($1)) & 0xFFFF }) == sum else { throw DMSError.checksumMismatch(number) }
            if adf.isEmpty { adf = [UInt8](repeating: 0, count: 80 * length) }
            guard track.count * (number + 1) <= adf.count else { throw DMSError.corruptTrack(number) }
            adf.replaceSubrange(number * track.count..<(number + 1) * track.count, with: track)
        }
        guard !adf.isEmpty else { throw DMSError.notDMS }
        return adf
    }

    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            var value = (crc ^ UInt16(byte)) & 0xFF
            for _ in 0..<8 { value = value & 1 != 0 ? value >> 1 ^ 0xA001 : value >> 1 }
            crc = value ^ crc >> 8
        }
        return crc
    }

    /// Distance codes of the medium and deep modes (LZHUF's tables): the upper six bits of a
    /// distance for each first byte, and how many more bits follow.
    static let distanceCode: [UInt8] = {
        var table: [UInt8] = []
        for (code, count) in [(0, 32), (1, 16), (2, 16), (3, 16)] { table += [UInt8](repeating: UInt8(code), count: count) }
        for code in 4...11 { table += [UInt8](repeating: UInt8(code), count: 8) }
        for code in 12...23 { table += [UInt8](repeating: UInt8(code), count: 4) }
        for code in 24...47 { table += [UInt8](repeating: UInt8(code), count: 2) }
        for code in 48...63 { table.append(UInt8(code)) }
        return table
    }()
    static let distanceLength: [UInt8] = [(3, 32), (4, 48), (5, 64), (6, 48), (7, 48), (8, 16)]
        .flatMap { [UInt8](repeating: UInt8($0.0), count: $0.1) }

    /// MSB-first bit reader over a zero-padded copy of the input (the decoders may look
    /// a few bytes past the end, as xDMS does into its large buffer).
    struct Bits {
        let data: [UInt8]
        var index = 0
        var buffer: UInt32 = 0
        var count = 0

        init(_ input: [UInt8]) {
            data = input + [UInt8](repeating: 0, count: 8)
            drop(0)
        }

        func peek(_ n: Int) -> Int { Int(UInt16(truncatingIfNeeded: buffer >> UInt32(count - n))) }

        mutating func drop(_ n: Int) {
            count -= n
            buffer &= (1 << UInt32(count)) - 1
            while count < 16 {
                buffer = buffer << 8 | UInt32(index < data.count ? data[index] : 0)
                index += 1
                count += 8
            }
        }

        mutating func read(_ n: Int) -> Int {
            let value = peek(n)
            drop(n)
            return value
        }
    }

    /// Decoder state that carries over from one cylinder to the next.
    struct Unpacker {
        var text = [UInt8](repeating: 0, count: 0x4000)
        var quickLocation = 251, mediumLocation = 0x3FBE, heavyLocation = 0, deepLocation = 0x3FC4
        var deepTablesReady = false
        // Deep mode's adaptive Huffman tree (LZHUF).
        static let characters = 256 - 2 + 60, tableSize = characters * 2 - 1, root = tableSize - 1
        var frequency = [UInt16](repeating: 0, count: tableSize + 1)
        var parent = [Int](repeating: 0, count: tableSize + characters)
        var son = [Int](repeating: 0, count: tableSize)
        // Heavy modes' code tables, kept when a cylinder reuses the previous one's trees.
        var codeLength = [UInt8](repeating: 0, count: 510), positionLength = [UInt8](repeating: 0, count: 20)
        var codeTable = [Int](repeating: 0, count: 4096), positionTable = [Int](repeating: 0, count: 256)
        var left = [Int](repeating: 0, count: 2 * 510 - 1), right = [Int](repeating: 0, count: 2 * 510 - 1 + 9)
        var lastLength = 0, positionCodes = 0

        mutating func reset() {
            quickLocation = 251; mediumLocation = 0x3FBE; heavyLocation = 0; deepLocation = 0x3FC4
            deepTablesReady = false
            for index in 0..<0x3FC8 { text[index] = 0 }
        }

        mutating func unpack(_ input: [UInt8], firstPass: Int, length: Int, mode: UInt8, flags: UInt8, number: Int) throws -> [UInt8] {
            var output: [UInt8]
            switch mode {
            case 0:
                guard input.count >= length else { throw DMSError.corruptTrack(number) }
                output = Array(input.prefix(length))
            case 1:
                output = try Self.runLength(input, length: length, number: number)
            case 2:
                output = try Self.runLength(quick(input, length: firstPass), length: length, number: number)
            case 3:
                output = try Self.runLength(medium(input, length: firstPass), length: length, number: number)
            case 4:
                output = try Self.runLength(deep(input, length: firstPass), length: length, number: number)
            case 5, 6:
                output = try heavy(input, flags: mode == 5 ? flags & 7 : flags | 8, length: firstPass, number: number)
                if flags & 4 != 0 { output = try Self.runLength(output, length: length, number: number) }
            default:
                throw DMSError.unsupported("compression mode \(mode)")
            }
            if flags & 1 == 0 { reset() }
            guard output.count >= length else { throw DMSError.corruptTrack(number) }
            return Array(output.prefix(length))
        }

        /// `$90 n c` repeats `c` n times (`$90 $FF c hi lo` a 16-bit count); `$90 0` is `$90`.
        static func runLength(_ input: [UInt8], length: Int, number: Int) throws -> [UInt8] {
            var output: [UInt8] = []
            output.reserveCapacity(length)
            var index = 0
            func next() throws -> UInt8 {
                guard index < input.count else { throw DMSError.corruptTrack(number) }
                defer { index += 1 }
                return input[index]
            }
            while output.count < length {
                let a = try next()
                if a != 0x90 { output.append(a); continue }
                let b = try next()
                if b == 0 { output.append(a); continue }
                let value = try next()
                let count = b == 0xFF ? Int(try next()) << 8 | Int(try next()) : Int(b)
                guard output.count + count <= length else { throw DMSError.corruptTrack(number) }
                output += [UInt8](repeating: value, count: count)
            }
            return output
        }

        mutating func quick(_ input: [UInt8], length: Int) -> [UInt8] {
            var bits = Bits(input), output: [UInt8] = []
            output.reserveCapacity(length)
            while output.count < length {
                if bits.read(1) != 0 {
                    let byte = UInt8(bits.read(8))
                    text[quickLocation & 0xFF] = byte; quickLocation &+= 1
                    output.append(byte)
                } else {
                    var count = bits.read(2) + 2
                    var from = quickLocation - bits.read(8) - 1
                    while count > 0 {
                        let byte = text[from & 0xFF]; from += 1
                        text[quickLocation & 0xFF] = byte; quickLocation += 1
                        output.append(byte)
                        count -= 1
                    }
                }
            }
            quickLocation = (quickLocation + 5) & 0xFF
            return output
        }

        /// The distance of a medium or deep match: a byte, its table code, then extra bits.
        static func distance(_ bits: inout Bits) -> Int {
            let first = bits.read(8)
            let extra = Int(DMS.distanceLength[first])
            let low = ((first << extra) | bits.read(extra)) & 0xFF
            return Int(DMS.distanceCode[first]) << 8 | low
        }

        mutating func medium(_ input: [UInt8], length: Int) -> [UInt8] {
            var bits = Bits(input), output: [UInt8] = []
            output.reserveCapacity(length)
            while output.count < length {
                if bits.read(1) != 0 {
                    let byte = UInt8(bits.read(8))
                    text[mediumLocation & 0x3FFF] = byte; mediumLocation &+= 1
                    output.append(byte)
                } else {
                    var code = bits.read(8)
                    var count = Int(DMS.distanceCode[code]) + 3
                    var extra = Int(DMS.distanceLength[code])
                    code = ((code << extra) | bits.read(extra)) & 0xFF
                    extra = Int(DMS.distanceLength[code])
                    let distance = Int(DMS.distanceCode[code]) << 8 | (((code << extra) | bits.read(extra)) & 0xFF)
                    var from = (mediumLocation - distance - 1) & 0xFFFF
                    while count > 0 {
                        let byte = text[from & 0x3FFF]; from += 1
                        text[mediumLocation & 0x3FFF] = byte; mediumLocation += 1
                        output.append(byte)
                        count -= 1
                    }
                }
            }
            mediumLocation = (mediumLocation + 66) & 0x3FFF
            return output
        }

        mutating func deep(_ input: [UInt8], length: Int) -> [UInt8] {
            if !deepTablesReady { initDeepTables() }
            var bits = Bits(input), output: [UInt8] = []
            output.reserveCapacity(length)
            while output.count < length {
                var node = son[Self.root]
                while node < Self.tableSize { node = son[node + bits.read(1)] }
                let code = node - Self.tableSize
                update(code)
                if code < 256 {
                    text[deepLocation & 0x3FFF] = UInt8(code); deepLocation += 1
                    output.append(UInt8(code))
                } else {
                    var count = code - 255 + 2
                    var from = (deepLocation - Self.distance(&bits) - 1) & 0xFFFF
                    while count > 0 {
                        let byte = text[from & 0x3FFF]; from += 1
                        text[deepLocation & 0x3FFF] = byte; deepLocation += 1
                        output.append(byte)
                        count -= 1
                    }
                }
            }
            deepLocation = (deepLocation + 60) & 0x3FFF
            return output
        }

        mutating func initDeepTables() {
            let t = Self.tableSize
            for index in 0..<Self.characters {
                frequency[index] = 1
                son[index] = index + t
                parent[index + t] = index
            }
            var i = 0, j = Self.characters
            while j <= Self.root {
                frequency[j] = frequency[i] &+ frequency[i + 1]
                son[j] = i
                parent[i] = j; parent[i + 1] = j
                i += 2; j += 1
            }
            frequency[t] = 0xFFFF
            parent[Self.root] = 0
            deepTablesReady = true
        }

        /// Rebuilds the tree with halved frequencies when the root's reaches its limit.
        mutating func reconstruct() {
            let t = Self.tableSize
            var j = 0
            for i in 0..<t where son[i] >= t {
                frequency[j] = (frequency[i] + 1) / 2
                son[j] = son[i]
                j += 1
            }
            var i = 0
            j = Self.characters
            while j < t {
                let f = frequency[i] &+ frequency[i + 1]
                var k = j - 1
                while f < frequency[k] { k -= 1 }
                k += 1
                if k < j {
                    frequency.replaceSubrange(k + 1...j, with: frequency[k..<j])
                    son.replaceSubrange(k + 1...j, with: son[k..<j])
                }
                frequency[k] = f
                son[k] = i
                i += 2; j += 1
            }
            for i in 0..<t {
                let k = son[i]
                if k >= t { parent[k] = i } else { parent[k] = i; parent[k + 1] = i }
            }
        }

        mutating func update(_ code: Int) {
            if frequency[Self.root] == 0x8000 { reconstruct() }
            var c = parent[code + Self.tableSize]
            repeat {
                frequency[c] &+= 1
                let k = frequency[c]
                var l = c + 1
                if k > frequency[l] {
                    l += 1
                    while k > frequency[l] { l += 1 }
                    l -= 1
                    frequency[c] = frequency[l]
                    frequency[l] = k
                    let i = son[c]
                    parent[i] = l
                    if i < Self.tableSize { parent[i + 1] = l }
                    let j = son[l]
                    son[l] = i
                    parent[j] = c
                    if j < Self.tableSize { parent[j + 1] = c }
                    son[c] = j
                    c = l
                }
                c = parent[c]
            } while c != 0
        }

        mutating func heavy(_ input: [UInt8], flags: UInt8, length: Int, number: Int) throws -> [UInt8] {
            // Heavy 1 has a 4 KiB dictionary, heavy 2 an 8 KiB one.
            positionCodes = flags & 8 != 0 ? 15 : 14
            let mask = flags & 8 != 0 ? 0x1FFF : 0x0FFF
            var bits = Bits(input)
            if flags & 2 != 0 {
                guard readCodeTree(&bits), readPositionTree(&bits) else { throw DMSError.corruptTrack(number) }
            }
            var output: [UInt8] = []
            output.reserveCapacity(length)
            while output.count < length {
                let code = decodeCode(&bits)
                if code < 256 {
                    text[heavyLocation & mask] = UInt8(code); heavyLocation += 1
                    output.append(UInt8(code))
                } else {
                    var count = code - 253
                    var from = (heavyLocation - decodePosition(&bits) - 1) & 0xFFFF
                    while count > 0 {
                        let byte = text[from & mask]; from += 1
                        text[heavyLocation & mask] = byte; heavyLocation += 1
                        output.append(byte)
                        count -= 1
                    }
                }
            }
            heavyLocation &= 0xFFFF
            return output
        }

        func decodeCode(_ bits: inout Bits) -> Int {
            var j = codeTable[bits.peek(12)]
            if j < 510 {
                bits.drop(Int(codeLength[j]))
            } else {
                bits.drop(12)
                let i = bits.peek(16)
                var m = 0x8000
                repeat {
                    j = i & m != 0 ? right[j] : left[j]
                    m >>= 1
                } while j >= 510
                bits.drop(Int(codeLength[j]) - 12)
            }
            return j
        }

        mutating func decodePosition(_ bits: inout Bits) -> Int {
            var j = positionTable[bits.peek(8)]
            if j < positionCodes {
                bits.drop(Int(positionLength[j]))
            } else {
                bits.drop(8)
                let i = bits.peek(16)
                var m = 0x8000
                repeat {
                    j = i & m != 0 ? right[j] : left[j]
                    m >>= 1
                } while j >= positionCodes
                bits.drop(Int(positionLength[j]) - 8)
            }
            if j != positionCodes - 1 {
                if j > 0 { j = bits.read(j - 1) | 1 << (j - 1) }
                lastLength = j
            }
            return lastLength
        }

        mutating func readCodeTree(_ bits: inout Bits) -> Bool {
            let n = bits.read(9)
            if n > 0 {
                guard n <= 510 else { return false }
                for i in 0..<510 { codeLength[i] = i < n ? UInt8(bits.read(5)) : 0 }
                var table = codeTable
                defer { codeTable = table }
                return makeTable(510, codeLength, 12, &table)
            }
            let only = bits.read(9)
            for i in 0..<510 { codeLength[i] = 0 }
            for i in 0..<4096 { codeTable[i] = only }
            return true
        }

        mutating func readPositionTree(_ bits: inout Bits) -> Bool {
            let n = bits.read(5)
            if n > 0 {
                guard n <= positionLength.count else { return false }
                for i in 0..<max(n, positionCodes) { positionLength[i] = i < n ? UInt8(bits.read(4)) : 0 }
                var table = positionTable
                defer { positionTable = table }
                return makeTable(positionCodes, positionLength, 8, &table)
            }
            let only = bits.read(5)
            for i in 0..<positionCodes { positionLength[i] = 0 }
            for i in 0..<256 { positionTable[i] = only }
            return true
        }

        /// LHA's make_table as in xDMS: a lookup table for codes up to `tableBits` long,
        /// with longer codes continued in the `left`/`right` tree.
        mutating func makeTable(_ count: Int, _ lengths: [UInt8], _ tableBits: Int, _ table: inout [Int]) -> Bool {
            let size = 1 << tableBits
            var c = -1, length = 1, depth = 1, codeword = 0, bit = size / 2, available = count
            let maxDepth = tableBits + 1
            var failed = false
            func subtree() -> Int {
                if failed { return 0 }
                var i = 0
                if length == depth {
                    c += 1
                    while c < count {
                        if Int(lengths[c]) == length {
                            i = codeword
                            codeword += bit
                            if codeword > size { failed = true; return 0 }
                            while i < codeword { table[i] = c; i += 1 }
                            return c
                        }
                        c += 1
                    }
                    c = -1
                    length += 1
                    bit >>= 1
                }
                depth += 1
                if depth < maxDepth {
                    _ = subtree()
                    _ = subtree()
                } else if depth > 32 {
                    failed = true
                    return 0
                } else {
                    i = available
                    available += 1
                    if i >= 2 * count - 1 { failed = true; return 0 }
                    left[i] = subtree()
                    right[i] = subtree()
                    if codeword >= size { failed = true; return 0 }
                    if depth == maxDepth { table[codeword] = i; codeword += 1 }
                }
                depth -= 1
                return i
            }
            _ = subtree()
            if failed { return false }
            _ = subtree()
            return !failed && codeword == size
        }
    }
}
