import Foundation
import Testing
@testable import MacMigaCore

// MARK: LHA test archives

/// Writes bits most significant first, as the `-lh5-` stream is read.
private struct BitWriter {
    var bytes: [UInt8] = []
    var used = 0

    mutating func put(_ value: Int, _ count: Int) {
        for bit in stride(from: count - 1, through: 0, by: -1) {
            if used % 8 == 0 { bytes.append(0) }
            if value >> bit & 1 != 0 { bytes[bytes.count - 1] |= 0x80 >> UInt8(used % 8) }
            used += 1
        }
    }
}

private enum Token {
    case literal(UInt8)
    /// Copy `length` (3–256) bytes starting `distance + 1` (1–128) bytes back.
    case match(length: Int, distance: Int)
}

/// A minimal `-lh5-` encoder with fixed Huffman codes: literal/length symbols 0 and 1 have
/// 8-bit codes and the other 508 have 9-bit codes; the eight position slots have 3-bit codes.
private func lh5(blocks: [[Token]]) -> [UInt8] {
    var writer = BitWriter()
    for tokens in blocks {
        writer.put(tokens.count, 16)
        // Code for the code lengths: symbols 10 and 11 (lengths 8 and 9) get one bit each.
        writer.put(12, 5)
        for _ in 0..<3 { writer.put(0, 3) }
        writer.put(3, 2) // three more zero lengths after the third entry
        for _ in 0..<4 { writer.put(0, 3) }
        writer.put(1, 3)
        writer.put(1, 3)
        writer.put(510, 9)
        for symbol in 0..<510 { writer.put(symbol < 2 ? 0 : 1, 1) }
        writer.put(8, 4)
        for _ in 0..<8 { writer.put(3, 3) }
        func symbol(_ value: Int) { value < 2 ? writer.put(value, 8) : writer.put(value + 2, 9) }
        for token in tokens {
            switch token {
            case .literal(let byte):
                symbol(Int(byte))
            case .match(let length, let distance):
                symbol(253 + length)
                let slot = distance == 0 ? 0 : Int.bitWidth - distance.leadingZeroBitCount
                writer.put(slot, 3)
                if slot > 1 { writer.put(distance - 1 << (slot - 1), slot - 1) }
            }
        }
    }
    return writer.bytes
}

/// What the tokens stand for, with the window starting out as spaces.
private func plain(_ blocks: [[Token]]) -> [UInt8] {
    var output: [UInt8] = []
    for token in blocks.joined() {
        switch token {
        case .literal(let byte): output.append(byte)
        case .match(let length, let distance):
            for _ in 0..<length {
                let source = output.count - distance - 1
                output.append(source >= 0 ? output[source] : 0x20)
            }
        }
    }
    return output
}

private func le(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(value >> ($0 * 8) & 0xFF) } }

/// 25 November 2026, 12:34:56 as an MS-DOS timestamp.
private let dosTime = (2026 - 1980) << 25 | 11 << 21 | 25 << 16 | 12 << 11 | 34 << 5 | 28

private func member(level: Int, method: String, name: [UInt8], directory: [UInt8] = [], packed: [UInt8],
                    original: [UInt8], attribute: UInt8 = 0, crc: Int? = nil) -> [UInt8] {
    let crc = crc ?? LHA.crc16(original)
    var extended: [UInt8] = []
    if !directory.isEmpty { extended += le(directory.count + 3, 2) + [0x02] + directory }
    switch level {
    case 0:
        let body = Array(method.utf8) + le(packed.count, 4) + le(original.count, 4) + le(dosTime, 4)
            + [attribute, 0, UInt8(name.count)] + name + le(crc, 2)
        return [UInt8(body.count), body.reduce(0, &+)] + body + packed
    case 1:
        let chain = extended.isEmpty ? [0, 0] : extended + [0, 0]
        let body = Array(method.utf8) + le(packed.count + chain.count - 2, 4) + le(original.count, 4) + le(dosTime, 4)
            + [attribute, 1, UInt8(name.count)] + name + le(crc, 2) + [0x41] + chain.prefix(2)
        return [UInt8(body.count), body.reduce(0, &+)] + body + chain.dropFirst(2) + packed
    default:
        extended += le(name.count + 3, 2) + [0x01] + name
        let header = Array(method.utf8) + le(packed.count, 4) + le(original.count, 4) + le(1_795_610_096, 4)
            + [0x20, 2] + le(crc, 2) + [0x41] + extended + [0, 0]
        return le(header.count + 2, 2) + header + packed
    }
}

private let sample: [[Token]] = [
    [.literal(0x41), .literal(0x42), .literal(0x43), .match(length: 9, distance: 2), // ABC ABCABCABC (overlapping)
     .literal(0), .literal(1), .literal(2), .literal(0xFF), .match(length: 3, distance: 0),
     .match(length: 256, distance: 15), .match(length: 4, distance: 127)],
    [.match(length: 5, distance: 1), .literal(0x7A), .match(length: 3, distance: 64)]
]

// MARK: LHA

@Test func crc16MatchesThePublishedCheckValue() {
    #expect(LHA.crc16(Array("123456789".utf8)) == 0xBB3D) // CRC-16/ARC
    #expect(LHA.crc16([]) == 0)
}

@Test func lh5StreamWithLiteralsMatchesAndTwoBlocksUnpacks() throws {
    let original = plain(sample)
    #expect(original.count == 3 + 9 + 4 + 3 + 256 + 4 + 5 + 1 + 3)
    #expect(Array(original.prefix(12)) == Array("ABCABCABCABC".utf8))
    for method in ["-lh5-", "-lh4-"] {
        let archive = member(level: 0, method: method, name: Array("data".utf8), packed: lh5(blocks: sample), original: original)
        #expect(try LHA.unpack(archive + [0]).map(\.contents) == [original])
    }
}

@Test func matchBeforeTheStartOfTheOutputCopiesSpaces() throws {
    let tokens: [[Token]] = [[.match(length: 4, distance: 9), .literal(0x58), .match(length: 3, distance: 4)]]
    #expect(plain(tokens) == Array("    X   ".utf8))
    let archive = member(level: 0, method: "-lh5-", name: [0x78], packed: lh5(blocks: tokens), original: plain(tokens))
    #expect(try LHA.unpack(archive).first?.contents == Array("    X   ".utf8))
}

@Test func headerLevelsNamesDirectoriesAndAmigaAttributes() throws {
    let text = Array("stored".utf8)
    var archive = member(level: 0, method: "-lh0-", name: Array("Games\\Pac/read.me\0a comment".utf8), packed: text,
                         original: text, attribute: 0x02)
    archive += member(level: 1, method: "-lh0-", name: Array("gr\u{FC}n".unicodeScalars.map { UInt8($0.value) }),
                      directory: Array("Top".utf8) + [0xFF] + Array("Sub".utf8) + [0xFF], packed: text, original: text,
                      attribute: 0x40)
    archive += member(level: 1, method: "-lhd-", name: [], directory: Array("Empty".utf8) + [0xFF], packed: [], original: [])
    archive += member(level: 2, method: "-lh5-", name: Array("packed".utf8), directory: Array("Top".utf8) + [0xFF],
                      packed: lh5(blocks: sample), original: plain(sample))
    archive += [0]
    let entries = try LHA.unpack(archive)
    #expect(entries.map(\.path) == [["Games", "Pac", "read.me"], ["Top", "Sub", "grün"], ["Empty"], ["Top", "packed"]])
    #expect(entries.map(\.contents) == [text, text, nil, plain(sample)])
    #expect(entries[0].comment == "a comment")
    #expect(entries[0].protection == 0) // level 0 has no system byte: attribute not taken as Amiga bits
    #expect(entries[1].protection == 0x40)
    #expect(entries[0].date == AmigaDate(days: 17860, minutes: 12 * 60 + 34, ticks: 56 * 50))
    #expect(entries[3].date == AmigaDate(days: 1_795_610_096 / 86_400 - 2_922, minutes: 1_795_610_096 % 86_400 / 60,
                                         ticks: 1_795_610_096 % 60 * 50))
}

@Test func damagedArchivesAreReported() throws {
    let original = plain(sample)
    let good = member(level: 0, method: "-lh5-", name: Array("f".utf8), packed: lh5(blocks: sample), original: original)
    #expect(throws: LHAError.checksumMismatch("f")) {
        try LHA.unpack(member(level: 0, method: "-lh5-", name: Array("f".utf8), packed: lh5(blocks: sample),
                              original: original, crc: LHA.crc16(original) ^ 1))
    }
    #expect(throws: LHAError.truncated) { try LHA.unpack(Array(good.dropLast(10))) }
    #expect(throws: LHAError.truncated) { try LHA.unpack(Array(good.prefix(12))) }
    var header = good
    header[9] ^= 0x01 // a size byte: the header checksum no longer fits
    #expect(throws: LHAError.badHeader(offset: 0)) { try LHA.unpack(header) }
    #expect(throws: LHAError.unsupportedMethod("-lh1-")) {
        try LHA.unpack(member(level: 0, method: "-lh1-", name: Array("f".utf8), packed: [1, 2, 3], original: [1, 2, 3]))
    }
    var level = member(level: 2, method: "-lh0-", name: Array("f".utf8), packed: [1], original: [1])
    level[20] = 3
    #expect(throws: LHAError.unsupportedHeaderLevel(3)) { try LHA.unpack(level) }
    #expect(throws: LHAError.badHeader(offset: 0)) { try LHA.unpack([UInt8](repeating: 0x55, count: 64)) }
    #expect(try LHA.unpack([]).isEmpty)
    #expect(try LHA.unpack([0]).isEmpty)
}

// MARK: Fast File System volumes

/// A reader written against the on-disk layout, independent of the writer's helpers.
private struct VolumeReader {
    let image: [UInt8]
    var visited = Set<Int>()

    var blocks: Int { image.count / 512 }
    var root: Int { (2 + blocks - 1) / 2 }

    func long(_ block: Int, _ offset: Int) -> Int {
        let at = block * 512 + offset
        return Int(Int32(bitPattern: UInt32(image[at]) << 24 | UInt32(image[at + 1]) << 16
                         | UInt32(image[at + 2]) << 8 | UInt32(image[at + 3])))
    }

    func sum(_ block: Int) -> UInt32 {
        stride(from: 0, to: 512, by: 4).reduce(UInt32(0)) { $0 &+ UInt32(truncatingIfNeeded: long(block, $1)) }
    }

    func name(_ block: Int) -> String {
        let at = block * 512 + 432
        return String(String.UnicodeScalarView(image[at + 1..<at + 1 + Int(image[at])].map { Unicode.Scalar($0) }))
    }

    /// Header blocks of a directory's entries, following every hash chain.
    mutating func children(of directory: Int) -> [Int] {
        var result: [Int] = []
        for slot in 0..<72 {
            var block = long(directory, 24 + slot * 4), previous = 0
            while block != 0 {
                #expect(sum(block) == 0)
                #expect(long(block, 0) == 2 && long(block, 4) == block && long(block, 500) == directory)
                #expect(block > previous) // chains ascend
                #expect(visited.insert(block).inserted)
                result.append(block)
                previous = block
                block = long(block, 496)
            }
        }
        return result
    }

    mutating func contents(ofFile header: Int) -> [UInt8] {
        var data: [UInt8] = []
        var list = header, expectedFirst = true
        while list != 0 {
            if list != header {
                #expect(sum(list) == 0)
                #expect(long(list, 0) == 16 && long(list, 4) == list && long(list, 500) == header && long(list, 508) == -3)
                #expect(visited.insert(list).inserted)
            }
            let count = long(list, 8)
            #expect(count <= 72)
            for index in 0..<count {
                let block = long(list, 24 + (71 - index) * 4)
                if expectedFirst { #expect(long(header, 16) == block); expectedFirst = false }
                #expect(visited.insert(block).inserted)
                data += image[block * 512..<(block + 1) * 512]
            }
            list = long(list, 504)
        }
        #expect((long(header, 324) + 511) / 512 == data.count / 512)
        return Array(data.prefix(long(header, 324)))
    }

    /// Every file by path, and every directory with nil.
    mutating func tree(_ directory: Int, _ path: String = "") -> [String: [UInt8]?] {
        var result: [String: [UInt8]?] = [:]
        for child in children(of: directory) {
            let childPath = path + name(child)
            switch long(child, 508) {
            case -3: result[childPath] = .some(contents(ofFile: child))
            case 2:
                result[childPath] = .some(nil)
                result.merge(tree(child, childPath + "/")) { first, _ in first }
            default: Issue.record("unexpected secondary type in block \(child)")
            }
        }
        return result
    }

    /// Bitmap blocks from the root and its extension chain, and the blocks marked free.
    mutating func freeBlocks() -> Set<Int> {
        var maps = (0..<25).map { long(root, 316 + $0 * 4) }.filter { $0 != 0 }
        var extensionBlock = long(root, 416)
        while extensionBlock != 0 {
            #expect(visited.insert(extensionBlock).inserted)
            maps += (0..<127).map { long(extensionBlock, $0 * 4) }.filter { $0 != 0 }
            extensionBlock = long(extensionBlock, 508)
        }
        var free = Set<Int>()
        for (index, map) in maps.enumerated() {
            #expect(sum(map) == 0)
            #expect(visited.insert(map).inserted)
            for bit in 0..<127 * 32 where long(map, 4 + bit / 32 * 4) >> (bit % 32) & 1 != 0 {
                free.insert(2 + index * 127 * 32 + bit)
            }
        }
        return free
    }
}

private func pattern(_ count: Int, seed: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8 &+ seed) }
}

private let stamp = AmigaDate(year: 2026, month: 11, day: 25, hour: 12, minute: 34, second: 56)

@Test func datesCountDaysFrom1978() {
    #expect(AmigaDate(year: 1978, month: 1, day: 1) == AmigaDate(days: 0))
    #expect(AmigaDate(year: 1996, month: 2, day: 29).days == 6633)
    #expect(AmigaDate(year: 2000, month: 1, day: 1).days == 8035)
    #expect(AmigaDate(year: 2024, month: 3, day: 1).days == 16861)
    #expect(stamp == AmigaDate(days: 17860, minutes: 754, ticks: 2800))
    #expect(AmigaDate(year: 1970, month: 6, day: 1).days == 0)
}

@Test func nameHashMatchesAmigaDOS() {
    // Values AmigaDOS agreed with when it booted hand-made volumes with these names.
    #expect(FastFileSystem.hash(Array("S".utf8)) == 24)
    #expect(FastFileSystem.hash(Array("Startup-Sequence".utf8)) == 49)
    #expect(FastFileSystem.hash(Array("startup-sequence".utf8)) == 49)
    #expect(FastFileSystem.hash(Array("Devs".utf8)) == 22)
    #expect(FastFileSystem.hash(Array("pacman_HD".utf8)) == 24)
}

@Test func volumeHoldsFilesOfEverySizeClassDirectoriesAndAConsistentBitmap() throws {
    let sizes = [0, 1, 512, 513, 72 * 512, 72 * 512 + 1, 144 * 512, 200_000]
    var entries = sizes.enumerated().map { index, size in
        VolumeEntry(path: ["Data", "file\(size)"], contents: pattern(size, seed: index), date: stamp)
    }
    entries.append(VolumeEntry(path: ["S", "Startup-Sequence"], contents: Array("Echo hi\n".utf8), date: stamp))
    entries.append(VolumeEntry(path: ["pacman_HD", "Deep", "Deeper", "leaf"], contents: [7], date: stamp)) // root slot shared with S
    entries.append(VolumeEntry(path: ["Empty"], contents: nil, date: stamp))
    var noted = VolumeEntry(path: ["Data", "noted"], contents: [1, 2, 3], date: AmigaDate(days: 5000, minutes: 61, ticks: 99))
    noted.protection = 0x42
    noted.comment = "a comment"
    entries.append(noted)
    // Many names in one directory force hash chains.
    entries += (0..<200).map { VolumeEntry(path: ["Many", "n\($0)"], contents: [UInt8($0)], date: stamp) }

    let image = try FastFileSystem.hardfile(named: "TestVolume", entries: entries, freeBytes: 0, date: stamp)
    #expect(image.count % HardDisk.cylinderSize == 0)
    let disk = try HardDisk(image: image)
    #expect(disk.dosType == 0x444F_5301)

    var reader = VolumeReader(image: image)
    let root = reader.root
    #expect(reader.sum(root) == 0)
    #expect(reader.long(root, 0) == 2 && reader.long(root, 12) == 72 && reader.long(root, 508) == 1)
    #expect(reader.long(root, 312) == -1)
    #expect(reader.name(root) == "TestVolume")
    #expect([420, 424, 428, 484].map { reader.long(root, $0) } == [17860, 754, 2800, 17860])
    reader.visited = [0, 1, root]

    let tree = reader.tree(root)
    var expected: [String: [UInt8]?] = [:]
    for entry in entries {
        for depth in 1..<entry.path.count { expected[entry.path.prefix(depth).joined(separator: "/")] = .some(nil) }
        expected[entry.path.joined(separator: "/")] = .some(entry.contents)
    }
    #expect(tree.count == expected.count)
    for (path, contents) in expected { #expect(tree[path] == contents, "\(path)") }

    // Metadata of one file header, found through its directory.
    var probe = VolumeReader(image: image)
    let data = try #require(probe.children(of: root).first { reader.name($0) == "Data" })
    let header = try #require(probe.children(of: data).first { reader.name($0) == "noted" })
    #expect(reader.long(header, 320) == 0x42)
    #expect(reader.long(header, 324) == 3)
    #expect(Array(image[header * 512 + 328..<header * 512 + 338]) == [9] + Array("a comment".utf8))
    #expect([420, 424, 428].map { reader.long(header, $0) } == [5000, 61, 99])

    // The bitmap marks exactly the blocks nothing uses.
    let free = reader.freeBlocks()
    #expect(free.isDisjoint(with: reader.visited))
    #expect(free.count + reader.visited.count == reader.blocks)
    #expect(free.allSatisfy { $0 >= 2 && $0 < reader.blocks })
}

@Test func defaultFreeSpaceAndBitmapExtensionBlocks() throws {
    let small = try FastFileSystem.hardfile(named: "Small", entries: [], date: stamp)
    #expect(small.count >= 2 << 20 && small.count < (2 << 20) + 3 * HardDisk.cylinderSize)
    // More than 25 bitmap blocks (52 MB) need a bitmap extension block.
    let image = try FastFileSystem.hardfile(named: "Large", entries: [VolumeEntry(path: ["f"], contents: [1], date: stamp)],
                                            freeBytes: 54 << 20, date: stamp)
    var reader = VolumeReader(image: image)
    #expect(reader.long(reader.root, 416) != 0)
    reader.visited = [0, 1, reader.root]
    let large: [String: [UInt8]?] = ["f": [1]]
    #expect(reader.tree(reader.root) == large)
    let free = reader.freeBlocks()
    #expect(free.count >= (54 << 20) / 512)
    #expect(free.isDisjoint(with: reader.visited))
    #expect(free.count + reader.visited.count == reader.blocks)
}

@Test func volumeRejectsBadNamesAndConflictsAndKeepsTheLastVersionOfAFile() throws {
    func build(_ entries: [VolumeEntry], name: String = "V") throws -> [UInt8] {
        try FastFileSystem.hardfile(named: name, entries: entries, freeBytes: 0, date: stamp)
    }
    func file(_ path: [String], _ contents: [UInt8] = [1]) -> VolumeEntry { VolumeEntry(path: path, contents: contents, date: stamp) }
    #expect(throws: VolumeError.invalidName("a:b")) { try build([file(["a:b"])]) }
    #expect(throws: VolumeError.invalidName("")) { try build([file(["dir", ""])]) }
    #expect(throws: VolumeError.invalidName(String(repeating: "x", count: 31))) { try build([file([String(repeating: "x", count: 31)])]) }
    #expect(throws: VolumeError.invalidName("日本")) { try build([file(["日本"])]) }
    #expect(throws: VolumeError.invalidName("bad/name")) { try build([], name: "bad/name") }
    #expect(throws: VolumeError.conflict("A")) { try build([file(["a"]), file(["A", "b"])]) } // named as given last
    #expect(throws: VolumeError.conflict("a/B")) { try build([file(["a", "b", "c"]), file(["a", "B"])]) }
    #expect(try build([file([String(repeating: "x", count: 30)])]).count > 0)

    var reader = VolumeReader(image: try build([file(["Readme"], [1]), file(["Dir", "x"]), file(["README"], [2, 3])]))
    reader.visited = [0, 1, reader.root]
    let kept: [String: [UInt8]?] = ["Readme": [2, 3], "Dir": nil, "Dir/x": [1]]
    #expect(reader.tree(reader.root) == kept)
}

@Test func macFolderBecomesVolumeEntries() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacMigaTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("S"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("Empty"), withIntermediateDirectories: true)
    try Data("Echo hi\n".utf8).write(to: folder.appendingPathComponent("S/Startup-Sequence"))
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("game"))
    try Data([9]).write(to: folder.appendingPathComponent(".DS_Store"))
    try Data([9]).write(to: folder.appendingPathComponent("._game"))
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"),
                                               withDestinationURL: folder.appendingPathComponent("game"))
    let date = Date(timeIntervalSince1970: 1_795_610_096) // 2026-11-25 12:34:56 UTC
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.appendingPathComponent("game").path)

    let entries = try VolumeEntry.entries(ofFolder: folder, timeZone: TimeZone(identifier: "UTC")!)
    #expect(entries.map(\.path) == [["Empty"], ["S"], ["S", "Startup-Sequence"], ["game"]])
    #expect(entries.map(\.contents) == [nil, nil, Array("Echo hi\n".utf8), [1, 2, 3]])
    #expect(entries[3].date == stamp)
    #expect(try VolumeEntry.entries(of: folder).map(\.path) == entries.map(\.path))

    // The same folder as a hardfile, with a startup-sequence replacing the folder's own.
    let named = folder.deletingLastPathComponent().appendingPathComponent("Pac:Man.hd")
    try FileManager.default.moveItem(at: folder, to: named)
    defer { try? FileManager.default.removeItem(at: named) }
    var reader = VolumeReader(image: try FastFileSystem.hardfile(from: named, freeBytes: 0, startupSequence: "game"))
    #expect(reader.name(reader.root) == "Pac_Man")
    reader.visited = [0, 1, reader.root]
    let tree = reader.tree(reader.root)
    #expect(tree["S/Startup-Sequence"] == .some(Array("game\n".utf8)))
    #expect(tree["game"] == .some([1, 2, 3]))
    #expect(tree.count == 4)
}
