public enum HunkFileError: Error, Equatable {
    /// The data does not start with a load file's header (`HUNK_HEADER`, `$3F3`), names
    /// resident libraries, or does not number its hunks from 0.
    case notALoadFile
    /// The data ends inside a hunk.
    case truncated
    /// A block type this loader does not know, e.g. an overlay.
    case unsupportedBlock(UInt32)
    /// A hunk holds more data than its size in the header, or a relocation lies outside its
    /// hunk or names a hunk that does not exist.
    case inconsistent
}

/// An AmigaDOS load file: the "hunk" format of executables that dos.library's LoadSeg reads.
/// Read here for the file systems a hard disk carries in its partition table, which have to
/// be loaded before dos.library runs.
///
/// Understood are the blocks a linked program is made of: code, data, BSS, 32-bit
/// relocations in the long and the short form, and symbol, debug and name blocks, which are
/// skipped. Overlays are not.
public struct HunkFile: Equatable, Sendable {
    public struct Relocation: Equatable, Sendable {
        /// The hunk whose address is added.
        public let target: Int
        /// Offsets, in the hunk that has the relocation, of the long words to adjust.
        public let offsets: [Int]
    }

    public struct Hunk: Equatable, Sendable {
        /// Bytes the hunk occupies in memory, from the header; a multiple of 4.
        public let size: Int
        /// The header asks for chip memory (`HUNKF_CHIP`).
        public let needsChipMemory: Bool
        /// The hunk's contents; what `size` has beyond them is zero (BSS).
        public let data: [UInt8]
        public let relocations: [Relocation]
    }

    public let hunks: [Hunk]

    public init(_ bytes: [UInt8]) throws {
        var position = 0
        func long() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw HunkFileError.truncated }
            defer { position += 4 }
            return UInt32(bytes[position]) << 24 | UInt32(bytes[position + 1]) << 16 | UInt32(bytes[position + 2]) << 8 | UInt32(bytes[position + 3])
        }
        func word() throws -> Int {
            guard position + 2 <= bytes.count else { throw HunkFileError.truncated }
            defer { position += 2 }
            return Int(bytes[position]) << 8 | Int(bytes[position + 1])
        }
        func skip(longs: UInt32) throws {
            guard longs <= UInt32((bytes.count - position) / 4) else { throw HunkFileError.truncated }
            position += Int(longs) * 4
        }
        guard bytes.count >= 4, try long() == 0x3F3, try long() == 0 else { throw HunkFileError.notALoadFile }
        _ = try long() // table size
        let first = try long(), last = try long()
        guard first == 0, last < 1024 else { throw HunkFileError.notALoadFile }
        var sizes: [(size: Int, chip: Bool)] = []
        for _ in 0...last {
            let value = try long()
            // Bit 30 asks for chip memory, bit 31 for fast; both set: the attributes follow.
            let chip = try value >> 30 == 3 ? long() & 2 != 0 : value >> 30 == 1
            sizes.append((Int(value & 0x3FFF_FFFF) * 4, chip))
        }
        var hunks: [Hunk] = []
        for (index, (size, chip)) in sizes.enumerated() {
            var data: [UInt8] = []
            var relocations: [Relocation] = []
            func relocation(target: Int, offsets: [Int]) throws {
                guard target < sizes.count, offsets.allSatisfy({ $0 + 4 <= size }) else { throw HunkFileError.inconsistent }
                relocations.append(Relocation(target: target, offsets: offsets))
            }
            var seen = false
            block: while true {
                // A file may end without the last hunk's HUNK_END.
                if position == bytes.count, seen, index == sizes.count - 1 { break }
                let type = try long() & 0x3FFF_FFFF
                seen = true
                switch type {
                case 0x3E9, 0x3EA: // HUNK_CODE, HUNK_DATA
                    let count = try long() & 0x3FFF_FFFF
                    guard count <= UInt32(size / 4) else { throw HunkFileError.inconsistent }
                    let start = position
                    try skip(longs: count)
                    data = Array(bytes[start..<position])
                case 0x3EB: // HUNK_BSS
                    _ = try long()
                case 0x3EC: // HUNK_RELOC32: count, hunk, offsets; a count of 0 ends it
                    while true {
                        let count = try long()
                        guard count != 0 else { break }
                        let target = try long()
                        guard count <= UInt32((bytes.count - position) / 4) else { throw HunkFileError.truncated }
                        let offsets = try (0..<count).map { _ in Int(try long()) }
                        try relocation(target: Int(target), offsets: offsets)
                    }
                case 0x3FC, 0x3F7: // HUNK_RELOC32SHORT (and HUNK_DREL32, used for it): the same in words
                    while true {
                        let count = try word()
                        guard count != 0 else { break }
                        let target = try word()
                        let offsets = try (0..<count).map { _ in try word() }
                        try relocation(target: target, offsets: offsets)
                    }
                    if position % 4 != 0 { _ = try word() }
                case 0x3F0: // HUNK_SYMBOL: name length in longs, name, value; a length of 0 ends it
                    while true {
                        let length = try long() & 0x00FF_FFFF
                        guard length != 0 else { break }
                        try skip(longs: length + 1)
                    }
                case 0x3F1, 0x3E8: // HUNK_DEBUG, HUNK_NAME
                    try skip(longs: try long())
                case 0x3F2: // HUNK_END
                    break block
                default:
                    throw HunkFileError.unsupportedBlock(type)
                }
            }
            hunks.append(Hunk(size: size, needsChipMemory: chip, data: data, relocations: relocations))
        }
        self.hunks = hunks
    }

    /// Offset of each hunk's segment in the memory `loaded(at:)` fills.
    private var segmentOffsets: [Int] {
        var offsets: [Int] = [], next = 0
        for hunk in hunks {
            offsets.append(next)
            next += (hunk.size + 8 + 7) & ~7
        }
        return offsets + [next]
    }

    /// Bytes of memory the loaded program takes: for every hunk two long words and its
    /// contents, rounded up to exec's 8-byte granularity.
    public var loadSize: Int { segmentOffsets.last ?? 0 }

    public var needsChipMemory: Bool { hunks.contains(where: \.needsChipMemory) }

    /// The program as LoadSeg leaves it in memory, for a block of `loadSize` bytes at
    /// `address` (a multiple of 8): a segment per hunk, made of the segment's length, a BPTR
    /// to the next segment's second long word (0 in the last) and the relocated contents.
    /// The segment list a DeviceNode or FileSysEntry wants is `(address + 4) / 4`.
    public func loaded(at address: UInt32) -> [UInt8] {
        let offsets = segmentOffsets
        var memory = [UInt8](repeating: 0, count: offsets[hunks.count])
        func get(_ at: Int) -> UInt32 {
            UInt32(memory[at]) << 24 | UInt32(memory[at + 1]) << 16 | UInt32(memory[at + 2]) << 8 | UInt32(memory[at + 3])
        }
        func put(_ value: UInt32, _ at: Int) {
            for index in 0..<4 { memory[at + index] = UInt8(truncatingIfNeeded: value >> UInt32(24 - index * 8)) }
        }
        for (index, hunk) in hunks.enumerated() {
            put(UInt32(offsets[index + 1] - offsets[index]), offsets[index])
            if index + 1 < hunks.count { put((address &+ UInt32(offsets[index + 1]) &+ 4) >> 2, offsets[index] + 4) }
            memory.replaceSubrange(offsets[index] + 8..<offsets[index] + 8 + hunk.data.count, with: hunk.data)
        }
        for (index, hunk) in hunks.enumerated() {
            for relocation in hunk.relocations {
                let base = address &+ UInt32(offsets[relocation.target]) &+ 8
                for offset in relocation.offsets {
                    let at = offsets[index] + 8 + offset
                    put(get(at) &+ base, at)
                }
            }
        }
        return memory
    }
}
