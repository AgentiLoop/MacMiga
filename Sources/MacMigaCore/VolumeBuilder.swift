/// An AmigaDOS DateStamp: days since 1 January 1978, minutes since midnight, and ticks
/// (1/50 s) within the minute.
public struct AmigaDate: Equatable, Sendable {
    public var days: Int
    public var minutes: Int
    public var ticks: Int

    public init(days: Int, minutes: Int = 0, ticks: Int = 0) {
        self.days = days
        self.minutes = minutes
        self.ticks = ticks
    }

    /// From a Gregorian calendar date and time of day. Dates before 1978 become day 0.
    public init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let since1970 = era * 146_097 + dayOfEra - 719_468
        self.init(days: max(0, since1970 - 2_922), minutes: hour * 60 + minute, ticks: second * 50)
    }
}

/// One file or directory to put on a volume.
public struct VolumeEntry: Equatable, Sendable {
    /// Directory names and the entry's own name, outermost first.
    public var path: [String]
    /// The file's bytes; nil makes the entry a directory.
    public var contents: [UInt8]?
    public var date: AmigaDate
    /// AmigaDOS protection bits; 0 allows read, write, execute and delete.
    public var protection: UInt32 = 0
    public var comment = ""

    public init(path: [String], contents: [UInt8]?, date: AmigaDate) {
        self.path = path
        self.contents = contents
        self.date = date
    }
}

public enum VolumeError: Error, Equatable {
    /// A name is empty, longer than 30 characters, contains `/` or `:`, or has a character
    /// outside ISO Latin-1.
    case invalidName(String)
    /// The same name is used for a file and a directory.
    case conflict(String)
    /// The volume would be larger than 2 GiB.
    case tooLarge
}

/// Writes AmigaDOS Fast File System volumes (`DOS\1`), or Original File System volumes
/// (`DOS\0`) for Kickstart 1.x, which has no FFS in ROM, as hardfile images with the geometry
/// `HardDisk` uses: 512-byte blocks, 2 reserved blocks, 32 blocks per cylinder.
///
/// Layout: the root block sits in the middle of the volume, followed by the bitmap and
/// then each directory's entries in the order given; allocation wraps to block 2 at the
/// end. Files and directories are found through 72-slot hash tables (names compare without
/// regard to the case of A–Z); entries sharing a slot are chained in ascending block order.
/// A file header lists its first 72 data blocks, extension blocks the rest. Every block
/// except FFS data blocks carries a checksum; OFS data blocks hold 488 bytes after a 24-byte
/// header (type, file header, sequence number, size, next data block, checksum).
public enum FastFileSystem {
    static let blockSize = HardDisk.blockSize
    static let reserved = 2
    static let hashSlots = 72
    /// Blocks described by one bitmap block: 127 long words after its checksum.
    static let bitsPerBitmapBlock = 127 * 32

    private final class Node {
        let name: [UInt8]
        var entry: VolumeEntry
        var children: [Node] = []
        var index: [[UInt8]: Int] = [:]
        var block = 0

        init(name: [UInt8], entry: VolumeEntry) {
            self.name = name
            self.entry = entry
        }
    }

    /// Whether a file, directory or volume can have this name: 1 to 30 ISO Latin-1
    /// characters, none of them a control character, `/` or `:`.
    public static func canStore(name: String) -> Bool { (try? bytes(ofName: name)) != nil }

    /// The name in ISO Latin-1, as stored on disk.
    static func bytes(ofName name: String) throws -> [UInt8] {
        let scalars = name.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 30,
              scalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0xFF && $0 != "/" && $0 != ":" }) else {
            throw VolumeError.invalidName(name)
        }
        return scalars.map { UInt8($0.value) }
    }

    static func uppercased(_ name: [UInt8]) -> [UInt8] {
        name.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }
    }

    /// The hash-table slot of a name on a `DOS\0`/`DOS\1` volume.
    static func hash(_ name: [UInt8]) -> Int {
        var value = name.count
        for byte in uppercased(name) { value = (value * 13 + Int(byte)) & 0x7FF }
        return value % hashSlots
    }

    /// Builds a hardfile holding `entries`. Directories that are only mentioned in a path are
    /// created with the volume's date; a file given twice keeps its last version. Without
    /// `freeBytes` the volume gets 2 MiB of free space or a quarter of its contents, whichever
    /// is more. The image is a whole number of cylinders. `fastFileSystem` false writes OFS.
    public static func hardfile(named volume: String, entries: [VolumeEntry], freeBytes: Int? = nil,
                                date: AmigaDate, fastFileSystem: Bool = true) throws -> [UInt8] {
        let dataSize = fastFileSystem ? blockSize : blockSize - 24
        let root = Node(name: try bytes(ofName: volume), entry: VolumeEntry(path: [], contents: nil, date: date))
        for entry in entries where !entry.path.isEmpty {
            var node = root
            for (depth, component) in entry.path.enumerated() {
                let name = try bytes(ofName: component)
                let isLast = depth == entry.path.count - 1
                let key = uppercased(name)
                if let existing = node.index[key] {
                    let child = node.children[existing]
                    let wantsDirectory = !isLast || entry.contents == nil
                    guard (child.entry.contents == nil) == wantsDirectory else {
                        throw VolumeError.conflict(entry.path.prefix(depth + 1).joined(separator: "/"))
                    }
                    if isLast { child.entry = entry }
                    node = child
                } else {
                    let child = Node(name: name, entry: isLast ? entry
                                     : VolumeEntry(path: Array(entry.path.prefix(depth + 1)), contents: nil, date: date))
                    node.index[key] = node.children.count
                    node.children.append(child)
                    node = child
                }
            }
        }

        // Size the volume: contents, free space, root, and a bitmap that covers it all.
        func blocks(for node: Node) -> Int {
            guard let contents = node.entry.contents else {
                return 1 + node.children.reduce(0) { $0 + blocks(for: $1) }
            }
            let data = (contents.count + dataSize - 1) / dataSize
            return 1 + data + max(0, data - 1) / hashSlots
        }
        let contentBlocks = blocks(for: root) // includes the root block
        let content = contentBlocks * blockSize
        let free = ((freeBytes ?? max(2 << 20, content / 4)) + blockSize - 1) / blockSize
        func bitmapBlocks(_ total: Int) -> (maps: Int, extensions: Int) {
            let maps = (total - reserved + bitsPerBitmapBlock - 1) / bitsPerBitmapBlock
            return (maps, (max(0, maps - 25) + 126) / 127)
        }
        var total = 0
        var needed = reserved + contentBlocks + free
        repeat {
            total = max(2, (needed + HardDisk.blocksPerTrack - 1) / HardDisk.blocksPerTrack) * HardDisk.blocksPerTrack
            let bitmap = bitmapBlocks(total)
            needed = reserved + contentBlocks + free + bitmap.maps + bitmap.extensions
        } while needed > total
        guard total * blockSize <= 0x7FFF_FFFF else { throw VolumeError.tooLarge }

        var image = [UInt8](repeating: 0, count: total * blockSize)
        var used = [Bool](repeating: false, count: total)
        func put(_ value: Int, _ block: Int, _ offset: Int) {
            let at = block * blockSize + offset
            let word = UInt32(truncatingIfNeeded: value)
            image[at] = UInt8(word >> 24)
            image[at + 1] = UInt8(word >> 16 & 0xFF)
            image[at + 2] = UInt8(word >> 8 & 0xFF)
            image[at + 3] = UInt8(word & 0xFF)
        }
        func get(_ block: Int, _ offset: Int) -> UInt32 {
            let at = block * blockSize + offset
            return UInt32(image[at]) << 24 | UInt32(image[at + 1]) << 16 | UInt32(image[at + 2]) << 8 | UInt32(image[at + 3])
        }
        /// Makes the block's long words sum to zero by setting the one at `offset`.
        func seal(_ block: Int, checksumAt offset: Int = 20) {
            put(0, block, offset)
            var sum: UInt32 = 0
            for index in stride(from: 0, to: blockSize, by: 4) { sum &+= get(block, index) }
            put(Int(0 &- sum), block, offset)
        }
        func putString(_ bytes: [UInt8], _ block: Int, _ offset: Int) {
            image[block * blockSize + offset] = UInt8(bytes.count)
            image.replaceSubrange(block * blockSize + offset + 1..<block * blockSize + offset + 1 + bytes.count, with: bytes)
        }

        let rootBlock = (reserved + total - 1) / 2
        var cursor = rootBlock
        for block in 0..<reserved { used[block] = true }
        func allocate() -> Int {
            while used[cursor] { cursor = cursor + 1 == total ? reserved : cursor + 1 }
            used[cursor] = true
            return cursor
        }
        root.block = allocate()
        let bitmap = bitmapBlocks(total)
        let mapBlocks = (0..<bitmap.maps).map { _ in allocate() }
        let mapExtensions = (0..<bitmap.extensions).map { _ in allocate() }

        /// Name, date, protection, comment and links shared by file and directory headers.
        func putHeader(_ node: Node, parent: Int, type: Int) {
            put(2, node.block, 0)                           // T_HEADER
            put(node.block, node.block, 4)
            put(Int(node.entry.protection), node.block, 320)
            putString(Array(node.entry.comment.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : 0x3F }.prefix(79)),
                      node.block, 328)
            put(node.entry.date.days, node.block, 420)
            put(node.entry.date.minutes, node.block, 424)
            put(node.entry.date.ticks, node.block, 428)
            putString(node.name, node.block, 432)
            put(parent, node.block, 500)
            put(type, node.block, 508)
        }

        /// Stores up to 72 block pointers, the first in the highest slot.
        func putPointers(_ pointers: ArraySlice<Int>, _ block: Int) {
            put(pointers.count, block, 8) // high_seq
            for (index, pointer) in pointers.enumerated() { put(pointer, block, 24 + (hashSlots - 1 - index) * 4) }
        }

        func write(directory: Node) {
            for child in directory.children { child.block = allocate() }
            var chains = [[Node]](repeating: [], count: hashSlots)
            for child in directory.children { chains[hash(child.name)].append(child) }
            for (slot, chain) in chains.enumerated() {
                let sorted = chain.sorted { $0.block < $1.block }
                if let first = sorted.first { put(first.block, directory.block, 24 + slot * 4) }
                for (index, child) in sorted.enumerated() {
                    putHeader(child, parent: directory.block, type: child.entry.contents == nil ? 2 : -3)
                    put(index + 1 < sorted.count ? sorted[index + 1].block : 0, child.block, 496) // hash chain
                }
            }
            for child in directory.children {
                guard let contents = child.entry.contents else {
                    write(directory: child)
                    seal(child.block)
                    continue
                }
                let count = (contents.count + dataSize - 1) / dataSize
                let data = (0..<count).map { _ in allocate() }
                for (index, block) in data.enumerated() {
                    let slice = contents[index * dataSize..<min(contents.count, (index + 1) * dataSize)]
                    let start = block * blockSize + blockSize - dataSize
                    image.replaceSubrange(start..<start + slice.count, with: slice)
                    guard !fastFileSystem else { continue }
                    put(8, block, 0)                        // T_DATA
                    put(child.block, block, 4)
                    put(index + 1, block, 8)
                    put(slice.count, block, 12)
                    put(index + 1 < count ? data[index + 1] : 0, block, 16)
                    seal(block)
                }
                put(contents.count, child.block, 324)
                put(data.first ?? 0, child.block, 16)
                putPointers(data.prefix(hashSlots), child.block)
                var previous = child.block
                for start in stride(from: hashSlots, to: count, by: hashSlots) {
                    let list = allocate()
                    put(16, list, 0)                        // T_LIST
                    put(list, list, 4)
                    putPointers(data[start..<min(count, start + hashSlots)], list)
                    put(child.block, list, 500)
                    put(-3, list, 508)                      // ST_FILE
                    put(list, previous, 504)
                    if previous != child.block { seal(previous) }
                    previous = list
                }
                if previous != child.block { seal(previous) }
                seal(child.block)
            }
        }

        // Root block.
        put(2, root.block, 0)                               // T_HEADER
        put(hashSlots, root.block, 12)
        put(-1, root.block, 312)                            // bitmap valid
        for (index, block) in mapBlocks.prefix(25).enumerated() { put(block, root.block, 316 + index * 4) }
        put(mapExtensions.first ?? 0, root.block, 416)
        for offset in [420, 472, 484] {                     // root, volume and creation dates
            put(date.days, root.block, offset)
            put(date.minutes, root.block, offset + 4)
            put(date.ticks, root.block, offset + 8)
        }
        putString(root.name, root.block, 432)
        put(1, root.block, 508)                             // ST_ROOT
        write(directory: root)
        seal(root.block)

        // Bitmap extension blocks: 127 bitmap block pointers and a link, no checksum.
        for (index, block) in mapExtensions.enumerated() {
            let pointers = mapBlocks.dropFirst(25 + index * 127).prefix(127)
            for (slot, pointer) in pointers.enumerated() { put(pointer, block, slot * 4) }
            put(index + 1 < mapExtensions.count ? mapExtensions[index + 1] : 0, block, 508)
        }
        // Bitmap: one bit per block from the first non-reserved one, set = free.
        for (index, block) in mapBlocks.enumerated() {
            let first = reserved + index * bitsPerBitmapBlock
            for candidate in first..<min(total, first + bitsPerBitmapBlock) where !used[candidate] {
                let bit = candidate - first
                image[block * blockSize + 4 + bit / 32 * 4 + 3 - bit % 32 / 8] |= 1 << UInt8(bit % 8)
            }
            seal(block, checksumAt: 0)
        }
        image.replaceSubrange(0..<4, with: [0x44, 0x4F, 0x53, fastFileSystem ? 1 : 0]) // DOS\1 or DOS\0
        return image
    }
}
