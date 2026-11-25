/// Writes partitioned hard disk images: a Rigid Disk Block, a partition block per partition
/// and, optionally, file systems (a header block with the program in LoadSeg blocks), all in
/// the first cylinders, followed by the partitions in the order given.
///
/// The geometry is that of a hardfile (1 surface, 32 blocks per track, so a cylinder is
/// 16 KiB), so a hardfile volume, which is a whole number of such cylinders, becomes a
/// partition byte for byte. Partitions use 2 reserved blocks, like hardfiles.
public enum RigidDiskBuilder {
    public struct Partition: Equatable, Sendable {
        /// AmigaDOS device name, for example `DH0`: 1 to 31 ISO Latin-1 characters, no `/` or `:`.
        public var name: String
        /// The partition's blocks, a whole number of cylinders; nil for an empty partition
        /// of `cylinders` cylinders (to be formatted on the Amiga).
        public var volume: [UInt8]?
        public var cylinders: Int
        /// de_DosType; for a volume, nil takes the type from its first block (`DOS\0`…`DOS\7`).
        public var dosType: UInt32?
        public var bootPriority: Int = 0
        /// Kickstart may boot from it (PBFF_BOOTABLE).
        public var bootable = true
        /// Kickstart mounts it (otherwise PBFF_NOMOUNT).
        public var automount = true

        /// A partition holding `volume`, such as a hardfile from `FastFileSystem`.
        public init(name: String, volume: [UInt8], dosType: UInt32? = nil) {
            self.name = name
            self.volume = volume
            self.cylinders = volume.count / HardDisk.cylinderSize
            self.dosType = dosType
        }

        /// An empty partition of `cylinders` cylinders (16 KiB each) of type `dosType`.
        public init(name: String, cylinders: Int, dosType: UInt32) {
            self.name = name
            self.cylinders = cylinders
            self.dosType = dosType
        }
    }

    public struct FileSystem: Equatable, Sendable {
        /// The partition type it handles, e.g. `PFS\3` = `$50465303`.
        public var dosType: UInt32
        /// Version in the upper word, revision in the lower.
        public var version: UInt32
        /// The load file (hunk format), for example `L:FastFileSystem` or `pfs3aio`.
        public var program: [UInt8]
        public var name = ""
        public var stackSize: UInt32 = 16384
        public var priority: Int32 = 10

        public init(dosType: UInt32, version: UInt32, program: [UInt8], name: String = "") {
            self.dosType = dosType
            self.version = version
            self.program = program
            self.name = name
        }
    }

    public enum BuildError: Error, Equatable {
        /// No partitions, or more than fit in the table.
        case partitionCount(Int)
        /// The partition's name cannot be stored, or another partition has it.
        case invalidName(String)
        /// The named partition's volume is not a whole number of cylinders, or it has none.
        case invalidSize(String)
        /// The named partition's volume has no `DOS\0`…`DOS\7` signature and no type was given.
        case unknownType(String)
        /// A file system's program is not a load file, or its length is not a whole number
        /// of long words.
        case invalidProgram(String)
        /// The image would be larger than 2 GiB.
        case tooLarge
    }

    static let hostID: UInt32 = 7
    static let end: UInt32 = 0xFFFF_FFFF

    public static func image(partitions: [Partition], fileSystems: [FileSystem] = []) throws -> [UInt8] {
        let blockSize = HardDisk.blockSize
        let cylinderBlocks = HardDisk.blocksPerTrack
        guard !partitions.isEmpty, partitions.count < 100 else { throw BuildError.partitionCount(partitions.count) }
        var names = Set<String>()
        var types: [UInt32] = []
        for partition in partitions {
            let scalars = partition.name.unicodeScalars
            guard !scalars.isEmpty, scalars.count <= 31, names.insert(partition.name.uppercased()).inserted,
                  scalars.allSatisfy({ $0.value > 0x20 && $0.value <= 0xFF && $0 != "/" && $0 != ":" }) else {
                throw BuildError.invalidName(partition.name)
            }
            guard partition.cylinders > 0,
                  partition.volume.map({ $0.count == partition.cylinders * HardDisk.cylinderSize }) ?? true else {
                throw BuildError.invalidSize(partition.name)
            }
            if let type = partition.dosType {
                types.append(type)
            } else if let volume = partition.volume, volume.starts(with: [0x44, 0x4F, 0x53]), volume[3] < 8 {
                types.append(0x444F_5300 | UInt32(volume[3]))
            } else {
                throw BuildError.unknownType(partition.name)
            }
        }
        for system in fileSystems where system.program.count % 4 != 0 || (try? HunkFile(system.program)) == nil {
            throw BuildError.invalidProgram(system.name)
        }

        // Blocks of the table: RDSK, the partition blocks, then each file system's header and
        // LoadSeg blocks of 123 long words each.
        let chunks = fileSystems.map { system in
            stride(from: 0, to: system.program.count, by: 492).map { system.program[$0..<min($0 + 492, system.program.count)] }
        }
        let tableBlocks = 1 + partitions.count + chunks.reduce(0) { $0 + 1 + $1.count }
        let reserved = max(2, (tableBlocks + cylinderBlocks - 1) / cylinderBlocks)
        let cylinders = reserved + partitions.reduce(0) { $0 + $1.cylinders }
        guard cylinders * HardDisk.cylinderSize <= 0x7FFF_FFFF else { throw BuildError.tooLarge }

        var image = [UInt8](repeating: 0, count: cylinders * HardDisk.cylinderSize)
        func put(_ value: UInt32, _ block: Int, _ offset: Int) {
            for index in 0..<4 { image[block * blockSize + offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(24 - index * 8)) }
        }
        func put(_ id: String, _ block: Int, longs: Int) {
            image.replaceSubrange(block * blockSize..<block * blockSize + 4, with: Array(id.utf8))
            put(UInt32(longs), block, 4)
            put(hostID, block, 12)
        }
        /// Sets rdb_ChkSum and the like so that the block's first `longs` long words add up to zero.
        func seal(_ block: Int, longs: Int) {
            var sum: UInt32 = 0
            for index in 0..<longs {
                let at = block * blockSize + index * 4
                sum &+= UInt32(image[at]) << 24 | UInt32(image[at + 1]) << 16 | UInt32(image[at + 2]) << 8 | UInt32(image[at + 3])
            }
            put(0 &- sum, block, 8)
        }
        let firstSystem = 1 + partitions.count

        put("RDSK", 0, longs: 64)
        put(UInt32(blockSize), 0, 16)                       // rdb_BlockBytes
        put(7, 0, 20)                                       // RDBFF_LAST | LASTLUN | LASTTID
        put(end, 0, 24)                                     // rdb_BadBlockList
        put(1, 0, 28)                                       // rdb_PartitionList
        put(fileSystems.isEmpty ? end : UInt32(firstSystem), 0, 32)
        put(end, 0, 36)                                     // rdb_DriveInit
        for offset in stride(from: 40, to: 64, by: 4) { put(end, 0, offset) }
        put(UInt32(cylinders), 0, 64)
        put(UInt32(cylinderBlocks), 0, 68)                  // rdb_Sectors
        put(1, 0, 72)                                       // rdb_Heads
        put(1, 0, 76)                                       // rdb_Interleave
        put(UInt32(cylinders), 0, 80)                       // rdb_Park
        put(UInt32(cylinders), 0, 96)                       // rdb_WritePreComp
        put(UInt32(cylinders), 0, 100)                      // rdb_ReducedWrite
        put(3, 0, 104)                                      // rdb_StepRate
        put(0, 0, 128)                                      // rdb_RDBBlocksLo
        put(UInt32(reserved * cylinderBlocks - 1), 0, 132)  // rdb_RDBBlocksHi
        put(UInt32(reserved), 0, 136)                       // rdb_LoCylinder
        put(UInt32(cylinders - 1), 0, 140)                  // rdb_HiCylinder
        put(UInt32(cylinderBlocks), 0, 144)                 // rdb_CylBlocks
        put(UInt32(tableBlocks - 1), 0, 152)                // rdb_HighRDSKBlock
        for (offset, text) in [(160, "MacMiga"), (168, "Hard Disk"), (184, "1.0")] {
            image.replaceSubrange(offset..<offset + text.utf8.count, with: Array(text.utf8))
        }
        seal(0, longs: 64)

        var low = reserved
        for (index, partition) in partitions.enumerated() {
            let block = 1 + index
            put("PART", block, longs: 64)
            put(index + 1 < partitions.count ? UInt32(block + 1) : end, block, 16) // pb_Next
            put((partition.bootable ? 1 : 0) | (partition.automount ? 0 : 2), block, 20)
            put(end, block, 24)
            put(end, block, 28)
            let name = partition.name.unicodeScalars.map { UInt8($0.value) }
            image[block * blockSize + 36] = UInt8(name.count)
            image.replaceSubrange(block * blockSize + 37..<block * blockSize + 37 + name.count, with: name)
            for offset in stride(from: 68, to: 128, by: 4) { put(end, block, offset) }
            let high = low + partition.cylinders - 1
            let environment: [UInt32] = [16, UInt32(blockSize / 4), 0, 1, 1, UInt32(cylinderBlocks),
                                         2, 0, 0, UInt32(low), UInt32(high),  // reserved, prealloc, interleave
                                         30, 1, 0x00FF_FFFF, 0x7FFF_FFFE,     // buffers, MEMF_PUBLIC, MaxTransfer, Mask
                                         UInt32(bitPattern: Int32(partition.bootPriority)), types[index]]
            for (entry, value) in environment.enumerated() { put(value, block, 128 + entry * 4) }
            seal(block, longs: 64)
            if let volume = partition.volume {
                image.replaceSubrange(low * HardDisk.cylinderSize..<(high + 1) * HardDisk.cylinderSize, with: volume)
            }
            low = high + 1
        }

        var block = firstSystem
        for (index, system) in fileSystems.enumerated() {
            let header = block
            let next = header + 1 + chunks[index].count
            put("FSHD", header, longs: 64)
            put(index + 1 < fileSystems.count ? UInt32(next) : end, header, 16) // fhb_Next
            put(system.dosType, header, 32)
            put(system.version, header, 36)
            put(0x180, header, 40)                          // patch SegList and GlobalVec
            put(UInt32(system.stackSize), header, 60)
            put(UInt32(bitPattern: system.priority), header, 64)
            put(chunks[index].isEmpty ? end : UInt32(header + 1), header, 72) // fhb_SegListBlocks
            put(end, header, 76)                            // fhb_GlobalVec: -1, no global vector
            let name = Array(system.name.utf8.prefix(83))
            image.replaceSubrange(header * blockSize + 172..<header * blockSize + 172 + name.count, with: name)
            seal(header, longs: 64)
            for (number, chunk) in chunks[index].enumerated() {
                let data = header + 1 + number
                // The last block sums only the long words it uses, so no padding is loaded.
                put("LSEG", data, longs: 5 + chunk.count / 4)
                put(number + 1 < chunks[index].count ? UInt32(data + 1) : end, data, 16) // lsb_Next
                image.replaceSubrange(data * blockSize + 20..<data * blockSize + 20 + chunk.count, with: chunk)
                seal(data, longs: 5 + chunk.count / 4)
            }
            block = next
        }
        return image
    }
}
