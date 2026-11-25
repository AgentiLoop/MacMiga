public enum HardDiskError: Error, Equatable {
    /// The image is smaller than 32 blocks.
    case invalidImageSize(Int)
    /// A Rigid Disk Block or partition block has the wrong ID, a bad checksum, an unusable
    /// environment table, or is reached twice. `block` is its block number.
    case invalidPartitionTable(block: Int)
    /// The disk or the named partition uses a block size other than 512 bytes.
    case unsupportedBlockSize(Int)
    /// The named partition has no cylinders or extends past the end of the image.
    case partitionOutsideImage(String)
    /// The partition table lists no partition that may be mounted.
    case noPartitions
}

/// A hard disk image, in one of two forms.
///
/// - A "hardfile": one AmigaDOS partition without a partition table, as used by UAE. It is
///   mounted as `DH0` with 512-byte blocks, 1 surface, 32 blocks per track and 2 reserved
///   blocks; blocks past the last whole cylinder are not used.
/// - A partitioned image, as written to real drives: a Rigid Disk Block (`RDSK`) in one of
///   the first 16 blocks leads to a chain of partition blocks (`PART`), each with a device
///   name, flags and the partition's DosEnvec. Every partition not flagged "no automount"
///   is mounted. The table may also carry file systems (`FSHD` blocks, each with its
///   program in a chain of `LSEG` blocks); the controller's boot ROM loads them for the
///   partitions of their type, so a partition does not need a file system Kickstart has
///   in ROM. A damaged `FSHD` block ends that list without making the disk unusable.
///
/// An image whose first block starts with `DOS` is always taken as a hardfile.
///
/// A class, so that copies of the machine share the one disk and writes never copy the image.
public final class HardDisk {
    public static let blockSize = 512
    /// Hardfile geometry.
    public static let blocksPerTrack = 32
    public static let cylinderSize = blockSize * blocksPerTrack

    public struct Partition: Equatable, Sendable {
        /// AmigaDOS device name, for example `DH0`.
        public let name: String
        /// The DosEnvec, from de_TableSize up to the entry de_TableSize names.
        public let environment: [UInt32]
        /// Priority among boot devices (the floppy has 5); -128 mounts without ever booting.
        public let bootPriority: Int
        /// Flags for OpenDevice (pb_DevFlags).
        public let deviceFlags: UInt32

        public var surfaces: Int { Int(environment[3]) }
        public var blocksPerTrack: Int { Int(environment[5]) }
        public var lowCylinder: Int { Int(environment[9]) }
        public var highCylinder: Int { Int(environment[10]) }
        /// The partition's first block on the disk and its length in blocks.
        public var firstBlock: Int { lowCylinder * surfaces * blocksPerTrack }
        public var blockCount: Int { (highCylinder - lowCylinder + 1) * surfaces * blocksPerTrack }
        /// de_DosType, or `DOS\0` when the table is too short to hold one.
        public var dosType: UInt32 { environment.count > 16 ? environment[16] : 0x444F_5300 }
    }

    /// A file system from the partition table (a FileSysHeaderBlock and its LoadSeg blocks).
    public struct FileSystem: Equatable, Sendable {
        /// The partition type it is for, e.g. `PFS\3` = `$50465303`.
        public let dosType: UInt32
        /// Version in the upper word, revision in the lower.
        public let version: UInt32
        /// Bit n set: the DeviceNode's n-th field after dn_Next takes `fields[n]`.
        public let patchFlags: UInt32
        /// fhb_Type, Task, Lock, Handler, StackSize, Priority, Startup, SegList (the first
        /// LSEG block; replaced by the loaded program's segment list) and GlobalVec.
        public let fields: [UInt32]
        /// fhb_FileSysName; empty in tables written before that field existed.
        public let name: String
        /// The program, or nil if its blocks are damaged or not a load file this emulator reads.
        public let program: HunkFile?
    }

    public private(set) var bytes: [UInt8]
    public let isWriteProtected: Bool
    /// The partitions to mount, in the order of the partition table.
    public let partitions: [Partition]
    /// The file systems in the partition table, in its order (none in a hardfile).
    public let fileSystems: [FileSystem]
    /// Whether the image has a partition table (false for a hardfile).
    public let isPartitioned: Bool
    /// Drive geometry as reported to TD_GETGEOMETRY.
    public let cylinders: Int
    public let surfaces: Int
    public let sectorsPerTrack: Int
    /// Blocks written since the last `takeModifiedBlocks()`, for the host to save.
    public private(set) var modifiedBlocks = Set<Int>()
    public private(set) var blocksRead = 0
    public private(set) var blocksWritten = 0

    /// Bytes after the last whole block, which some tools leave (an image of 1,900,000,000
    /// bytes, for example), are not used.
    public init(image: [UInt8], writeProtected: Bool = false) throws {
        guard image.count >= Self.cylinderSize else { throw HardDiskError.invalidImageSize(image.count) }
        let image = image.count % Self.blockSize == 0 ? image : Array(image.prefix(image.count / Self.blockSize * Self.blockSize))
        bytes = image
        isWriteProtected = writeProtected
        func long(_ block: Int, _ offset: Int) -> UInt32 {
            let at = block * Self.blockSize + offset
            return UInt32(image[at]) << 24 | UInt32(image[at + 1]) << 16 | UInt32(image[at + 2]) << 8 | UInt32(image[at + 3])
        }
        func hasID(_ block: Int, _ id: String) -> Bool {
            image[block * Self.blockSize..<block * Self.blockSize + 4].elementsEqual(id.utf8)
        }
        /// The block's first `SummedLongs` long words must add up to zero.
        func isSummed(_ block: Int) -> Bool {
            let count = Int(long(block, 4))
            guard count >= 3, count <= Self.blockSize / 4 else { return false }
            return (0..<count).reduce(UInt32(0)) { $0 &+ long(block, $1 * 4) } == 0
        }
        let blocks = image.count / Self.blockSize
        let hasFileSystem = image.starts(with: [0x44, 0x4F, 0x53])
        guard !hasFileSystem, let rigid = (0..<16).first(where: { hasID($0, "RDSK") }) else {
            // Hardfile: the image's own `DOS\0`…`DOS\7` signature, else `DOS\1` (FFS).
            let dosType = hasFileSystem && image[3] < 8 ? 0x444F_5300 | UInt32(image[3]) : 0x444F_5301
            cylinders = image.count / Self.cylinderSize
            surfaces = 1
            sectorsPerTrack = Self.blocksPerTrack
            isPartitioned = false
            partitions = [Partition(
                name: "DH0",
                environment: [16,                              // de_TableSize (up to de_DosType)
                              UInt32(Self.blockSize / 4),      // de_SizeBlock in longs
                              0, 1, 1,                         // de_SecOrg, de_Surfaces, de_SectorPerBlock
                              UInt32(Self.blocksPerTrack),     // de_BlocksPerTrack
                              2, 0, 0,                         // de_Reserved, de_PreAlloc, de_Interleave
                              0, UInt32(cylinders - 1),        // de_LowCyl, de_HighCyl
                              30, 1,                           // de_NumBuffers, de_BufMemType MEMF_PUBLIC
                              0x7FFF_FFFF, 0x7FFF_FFFE,        // de_MaxTransfer, de_Mask
                              0, dosType],                     // de_BootPri, de_DosType
                bootPriority: 0, deviceFlags: 0)]
            fileSystems = []
            return
        }
        guard isSummed(rigid) else { throw HardDiskError.invalidPartitionTable(block: rigid) }
        guard long(rigid, 16) == UInt32(Self.blockSize) else { throw HardDiskError.unsupportedBlockSize(Int(long(rigid, 16))) }
        var found: [Partition] = []
        var visited = Set<Int>()
        var next = long(rigid, 28) // rdb_PartitionList
        while next != 0xFFFF_FFFF {
            let block = Int(next)
            guard block < blocks, visited.insert(block).inserted, hasID(block, "PART"), isSummed(block) else {
                throw HardDiskError.invalidPartitionTable(block: block)
            }
            next = long(block, 16)                                   // pb_Next
            let flags = long(block, 20)                              // pb_Flags
            guard flags & 2 == 0 else { continue }                   // PBFF_NOMOUNT
            let nameLength = Int(image[block * Self.blockSize + 36]) // pb_DriveName, a BSTR
            guard nameLength <= 31, long(block, 128) >= 10 else { throw HardDiskError.invalidPartitionTable(block: block) }
            let nameBytes = image[block * Self.blockSize + 37..<block * Self.blockSize + 37 + nameLength]
            let name = nameBytes.isEmpty ? "DH\(found.count)" : String(String.UnicodeScalarView(nameBytes.map { Unicode.Scalar($0) }))
            let tableSize = min(Int(long(block, 128)), 19)
            var environment = (0...tableSize).map { long(block, 128 + $0 * 4) }
            environment[0] = UInt32(tableSize)
            guard environment[1] == UInt32(Self.blockSize / 4) else { throw HardDiskError.unsupportedBlockSize(Int(environment[1]) * 4) }
            let priority = tableSize >= 15 ? Int(Int32(bitPattern: environment[15])) : 0
            let partition = Partition(name: name, environment: environment,
                                      bootPriority: flags & 1 != 0 ? min(max(priority, -128), 127) : -128, // PBFF_BOOTABLE
                                      deviceFlags: long(block, 32))
            let end = (UInt64(environment[10]) + 1) * UInt64(environment[3]) * UInt64(environment[5])
            guard environment[9] <= environment[10], end > 0, end <= UInt64(blocks) else {
                throw HardDiskError.partitionOutsideImage(name)
            }
            found.append(partition)
        }
        guard !found.isEmpty else { throw HardDiskError.noPartitions }
        partitions = found
        isPartitioned = true
        var systems: [FileSystem] = []
        next = long(rigid, 32) // rdb_FileSysHeaderList
        while next != 0xFFFF_FFFF {
            let block = Int(next)
            guard block < blocks, visited.insert(block).inserted, hasID(block, "FSHD"), isSummed(block), long(block, 4) >= 20 else { break }
            next = long(block, 16)                                   // fhb_Next
            // The program: the data long words of the chain of LSEG blocks.
            var program: [UInt8]? = []
            var segment = long(block, 72)                            // fhb_SegListBlocks
            while segment != 0xFFFF_FFFF, program != nil {
                let data = Int(segment)
                if data < blocks, visited.insert(data).inserted, hasID(data, "LSEG"), isSummed(data), long(data, 4) >= 5 {
                    program! += image[data * Self.blockSize + 20..<data * Self.blockSize + Int(long(data, 4)) * 4]
                    segment = long(data, 16)                         // lsb_Next
                } else {
                    program = nil
                }
            }
            let nameField = long(block, 4) >= 64 ? image[block * Self.blockSize + 172..<block * Self.blockSize + 256].prefix { $0 != 0 } : []
            systems.append(FileSystem(
                dosType: long(block, 32), version: long(block, 36), patchFlags: long(block, 40),
                fields: (0..<9).map { long(block, 44 + $0 * 4) },
                name: nameField.allSatisfy({ $0 >= 0x20 }) ? String(String.UnicodeScalarView(nameField.map { Unicode.Scalar($0) })) : "",
                program: program.flatMap { try? HunkFile($0) }))
        }
        fileSystems = systems
        // rdb_Cylinders, rdb_Sectors, rdb_Heads; a table without them gets the hardfile layout.
        let geometry = (Int(long(rigid, 64)), Int(long(rigid, 72)), Int(long(rigid, 68)))
        if geometry.0 > 0, geometry.1 > 0, geometry.2 > 0 {
            (cylinders, surfaces, sectorsPerTrack) = geometry
        } else {
            (cylinders, surfaces, sectorsPerTrack) = (blocks / Self.blocksPerTrack, 1, Self.blocksPerTrack)
        }
    }

    /// Bytes the Amiga can address: whole cylinders of a hardfile, all of a partitioned image.
    public var capacity: Int { isPartitioned ? bytes.count : cylinders * Self.cylinderSize }

    /// Returns and clears the set of blocks written since the last call, in ascending order.
    public func takeModifiedBlocks() -> [Int] {
        defer { modifiedBlocks.removeAll(keepingCapacity: true) }
        return modifiedBlocks.sorted()
    }

    func read(at offset: Int, count: Int) -> ArraySlice<UInt8> {
        blocksRead += (count + Self.blockSize - 1) / Self.blockSize
        return bytes[offset..<offset + count]
    }

    func write(_ data: [UInt8], at offset: Int) {
        guard !data.isEmpty else { return }
        bytes.replaceSubrange(offset..<offset + data.count, with: data)
        let blocks = offset / Self.blockSize...(offset + data.count - 1) / Self.blockSize
        modifiedBlocks.formUnion(blocks)
        blocksWritten += blocks.count
    }
}

/// The hard-disk controller: a 64 KiB Zorro II board carrying a boot ROM and a few
/// long-word registers. It is not a model of any real controller.
///
/// The boot ROM (generated for the address Kickstart assigns) holds a DiagArea with a
/// Resident tag for `macmiga.device`. Kickstart copies the DiagArea to RAM and calls its
/// DiagPoint, then initialises the Resident: the device is created, and for each of the
/// disk's partitions a DOS node is made with expansion.library's MakeDosNode and queued
/// with its boot priority (AddBootNode on V36+, a BootNode on eb_MountList before that).
/// All partitions are on unit 0; each one's DosEnvec places it on the disk. The BootPoint
/// starts dos.library.
///
/// File systems in the partition table are installed first, the way a real controller's
/// ROM does it. Each is looked up by its DosType in `FileSystem.resource` (made if
/// Kickstart has none). Unless the resource has that type in the same or a newer version,
/// memory is allocated, the host puts the program there, and a FileSysEntry for it is added
/// to the resource. The DeviceNode of every partition whose type has a file system in the
/// table is then patched from the resource's newest entry of that type, as the entry's
/// patch flags say: usually the segment list and a global vector of -1. Partitions of
/// other types are left to Kickstart, as before.
///
/// The 68000 code is kept minimal by handing the work to the host through the registers:
/// - `$8000` request: writing an IORequest pointer performs the command at once. Reading
///   returns 0 when the request is finished, 1 when the device keeps it (TD_ADDCHANGEINT).
/// - `$8004` diagnostic: writing the DiagArea copy's address fixes up its Resident tag.
/// - `$8008` device: writing the new device base fills in its library node.
/// - `$8040 + 4n` file system n: writing the address of `HunkFile.loadSize` bytes of
///   memory puts the table's n-th file system there, relocated, as a segment list.
public struct HardDiskController: Equatable, Sendable {
    /// Board offset of the DiagArea (er_InitDiagVec).
    public static let diagnosticOffset: UInt16 = 0x0100
    public static let requestRegister = 0x8000
    public static let diagnosticRegister = 0x8004
    public static let deviceRegister = 0x8008
    public static let fileSystemRegisters = 0x8040
    /// File systems of a partition table beyond this many are not installed.
    public static let fileSystemLimit = 16
    public static let deviceName = "macmiga.device"

    /// Assigned board address; `UInt32.max` while unconfigured.
    var base = UInt32.max
    /// Board contents from offset 0 (the boot ROM starts at `diagnosticOffset`).
    var rom: [UInt8] = []
    /// Offsets of the ROM's labels from the DiagArea.
    var labels: [String: Int] = [:]
    var latch: UInt32 = 0
    var requestPending = false

    /// Board address of a boot ROM label, e.g. `beginIO`, or `parameters1` for the second
    /// partition's MakeDosNode packet.
    public func address(of label: String) -> UInt32? {
        labels[label].map { base + UInt32(Self.diagnosticOffset) + UInt32($0) }
    }

    mutating func configure(base: UInt32, disk: HardDisk) {
        self.base = base
        let origin = base + UInt32(Self.diagnosticOffset)
        // Every instruction has a fixed size, so a first pass yields the final label offsets.
        let sizes = Self.bootROM(origin: origin, base: base, disk: disk, known: [:])
        let final = Self.bootROM(origin: origin, base: base, disk: disk, known: sizes.labels)
        rom = [UInt8](repeating: 0, count: Int(Self.diagnosticOffset)) + final.bytes
        labels = final.labels
    }

    private struct Assembler {
        var bytes: [UInt8] = []
        var labels: [String: Int] = [:]
        let origin: UInt32
        let known: [String: Int]

        mutating func label(_ name: String) { labels[name] = bytes.count }
        func offset(_ name: String) -> Int { known[name] ?? 0 }
        func address(_ name: String) -> UInt32 { origin + UInt32(offset(name)) }
        mutating func word(_ values: UInt16...) {
            for value in values { bytes += [UInt8(value >> 8), UInt8(value & 0xFF)] }
        }
        mutating func long(_ values: UInt32...) {
            for value in values { word(UInt16(value >> 16), UInt16(value & 0xFFFF)) }
        }
        /// A Bcc.S (`opcode` = `$6x00`) to a label.
        mutating func branch(_ opcode: UInt16, to name: String) {
            let displacement = offset(name) - (bytes.count + 2)
            precondition(known[name] == nil || (displacement != 0 && (-128...127).contains(displacement)))
            word(opcode | UInt16(UInt8(truncatingIfNeeded: displacement)))
        }
        /// A Bcc.W (`opcode` = `$6x00`) to a label.
        mutating func branchWord(_ opcode: UInt16, to name: String) {
            word(opcode)
            word(UInt16(truncatingIfNeeded: offset(name) - bytes.count))
        }
        /// A NUL-terminated ISO Latin-1 string, padded to a word boundary.
        mutating func string(_ text: String) {
            bytes += text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } + [0]
            if bytes.count % 2 != 0 { bytes.append(0) }
        }
    }

    private static func bootROM(origin: UInt32, base: UInt32, disk: HardDisk,
                                known: [String: Int]) -> (bytes: [UInt8], labels: [String: Int]) {
        var a = Assembler(origin: origin, known: known)
        let request = base + UInt32(requestRegister)
        let diagnostic = base + UInt32(diagnosticRegister)
        let device = base + UInt32(deviceRegister)

        // struct DiagArea
        a.word(0x9000)                                    // da_Config DAC_WORDWIDE|DAC_CONFIGTIME, da_Flags
        a.word(UInt16(a.offset("copyEnd")))               // da_Size
        a.word(UInt16(a.offset("diagPoint")))             // da_DiagPoint
        a.word(UInt16(a.offset("bootPoint")))             // da_BootPoint
        a.word(0, 0, 0)                                   // da_Name, reserved
        // struct Resident; MatchTag and EndSkip are pointed at the RAM copy by the host.
        a.label("romTag")
        a.word(0x4AFC)                                    // rt_MatchWord
        a.long(a.address("romTag"), a.address("copyEnd")) // rt_MatchTag, rt_EndSkip
        a.word(0x8101, 0x0314)                            // RTF_AUTOINIT|RTF_COLDSTART, version 1, NT_DEVICE, pri 20
        a.long(a.address("deviceName"), a.address("idString"), a.address("initTable"))
        // DiagPoint(a0 board, a2 DiagArea copy, a3 ConfigDev)
        a.label("diagPoint")
        a.word(0x23CA); a.long(diagnostic)                // move.l a2,(diagnostic).l
        a.word(0x7001, 0x4E75)                            // moveq #1,d0 ; rts
        // BootPoint(a6 SysBase): start dos.library
        a.label("bootPoint")
        a.word(0x43F9); a.long(a.address("dosLibrary"))   // lea dosLibrary,a1
        a.word(0x4EAE, 0xFFA0)                            // jsr FindResident(a6)
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6700, to: "bootDone")                  // beq.s bootDone
        a.word(0x2040, 0x2068, 0x0016, 0x4E90)            // movea.l d0,a0 ; movea.l rt_Init(a0),a0 ; jsr (a0)
        a.label("bootDone")
        a.word(0x4E75)                                    // rts
        a.label("copyEnd")

        // RTF_AUTOINIT table: data size, function table, data table, init routine
        a.label("initTable")
        a.long(36, a.address("functions"), 0, a.address("initialize"))
        a.label("functions")
        a.long(a.address("open"), a.address("close"), a.address("null"), a.address("null"),
               a.address("beginIO"), a.address("null"), 0xFFFF_FFFF)

        // initialize(d0 device, a6 SysBase) -> d0 device
        a.label("initialize")
        a.word(0x48E7, 0x383A)                            // movem.l d2-d4/a2-a4/a6,-(sp)
        a.word(0x2400)                                    // move.l d0,d2
        a.word(0x23C0); a.long(device)                    // move.l d0,(device).l
        // File systems from the partition table. d3 = FileSystem.resource, or 0 without any.
        a.word(0x7600)                                    // moveq #0,d3
        a.word(0x49F9); a.long(a.address("fileSystemTable")) // lea fileSystemTable,a4
        a.word(0x4A94)                                    // tst.l (a4)
        a.branchWord(0x6700, to: "fileSystemsDone")       // beq fileSystemsDone
        a.word(0x43F9); a.long(a.address("fileSystemResource")) // lea fileSystemResource,a1
        a.word(0x4EAE, 0xFE0E)                            // jsr OpenResource(a6)
        a.word(0x2600)                                    // move.l d0,d3
        a.branch(0x6600, to: "fileSystemLoop")            // bne.s fileSystemLoop
        // Kickstart has no FileSystem.resource: make an empty one.
        a.word(0x7020)                                    // moveq #FileSysResource_SIZEOF,d0
        a.word(0x223C); a.long(0x0001_0001)               // move.l #MEMF_PUBLIC|MEMF_CLEAR,d1
        a.word(0x4EAE, 0xFF3A)                            // jsr AllocMem(a6)
        a.word(0x2600)                                    // move.l d0,d3
        a.branchWord(0x6700, to: "fileSystemsDone")       // beq fileSystemsDone
        a.word(0x2240)                                    // movea.l d0,a1
        a.word(0x137C, 0x0008, 0x0008)                    // move.b #NT_RESOURCE,ln_Type(a1)
        a.word(0x237C); a.long(a.address("fileSystemResource")); a.word(0x000A) // move.l #fileSystemResource,ln_Name(a1)
        a.word(0x237C); a.long(a.address("idString")); a.word(0x000E)           // move.l #idString,fsr_Creator(a1)
        a.word(0x41E9, 0x0012)                            // lea fsr_FileSysEntries(a1),a0
        a.word(0x2148, 0x0008)                            // move.l a0,lh_TailPred(a0)
        a.word(0x5888)                                    // addq.l #4,a0
        a.word(0x2148, 0xFFFC)                            // move.l a0,-4(a0) (lh_Head = &lh_Tail)
        a.word(0x4EAE, 0xFE1A)                            // jsr AddResource(a6)
        // For each table entry (a FileSysEntry's contents, then size, memory type, register, name):
        a.label("fileSystemLoop")
        a.word(0x2014)                                    // move.l (a4),d0 (DosType; 0 ends the table)
        a.branchWord(0x6700, to: "fileSystemsDone")       // beq fileSystemsDone
        a.branchWord(0x6100, to: "findFileSystem")        // bsr findFileSystem
        a.branch(0x6700, to: "loadFileSystem")            // beq.s loadFileSystem
        a.word(0x2040)                                    // movea.l d0,a0
        a.word(0x202C, 0x0004)                            // move.l 4(a4),d0 (version)
        a.word(0xB0A8, 0x0012)                            // cmp.l fse_Version(a0),d0
        a.branch(0x6300, to: "nextFileSystem")            // bls.s nextFileSystem (the resource's is as new)
        a.label("loadFileSystem")
        a.word(0x202C, 0x0030)                            // move.l 48(a4),d0 (bytes; 0 if the program is unreadable)
        a.branch(0x6700, to: "nextFileSystem")            // beq.s nextFileSystem
        a.word(0x222C, 0x0034)                            // move.l 52(a4),d1 (memory type)
        a.word(0x4EAE, 0xFF3A)                            // jsr AllocMem(a6)
        a.word(0x2800)                                    // move.l d0,d4
        a.branch(0x6700, to: "nextFileSystem")            // beq.s nextFileSystem
        a.word(0x703E)                                    // moveq #FileSysEntry_SIZEOF,d0
        a.word(0x223C); a.long(0x0001_0001)               // move.l #MEMF_PUBLIC|MEMF_CLEAR,d1
        a.word(0x4EAE, 0xFF3A)                            // jsr AllocMem(a6)
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6700, to: "nextFileSystem")            // beq.s nextFileSystem
        a.word(0x2640)                                    // movea.l d0,a3 (FileSysEntry)
        a.word(0x206C, 0x0038)                            // movea.l 56(a4),a0
        a.word(0x2084)                                    // move.l d4,(a0) (the host loads the program at d4)
        a.word(0x276C, 0x003C, 0x000A)                    // move.l 60(a4),ln_Name(a3)
        a.word(0x41EB, 0x000E)                            // lea fse_DosType(a3),a0
        a.word(0x244C)                                    // movea.l a4,a2
        a.word(0x700B)                                    // moveq #11,d0
        a.label("copyEntry")
        a.word(0x20DA)                                    // move.l (a2)+,(a0)+
        a.branchWord(0x51C8, to: "copyEntry")             // dbra d0,copyEntry
        a.word(0x5884, 0xE48C)                            // addq.l #4,d4 ; lsr.l #2,d4 (BPTR to the first segment)
        a.word(0x2744, 0x0036)                            // move.l d4,fse_SegList(a3)
        a.word(0x4EAE, 0xFF7C)                            // jsr Forbid(a6)
        a.word(0x2043)                                    // movea.l d3,a0
        a.word(0x41E8, 0x0012)                            // lea fsr_FileSysEntries(a0),a0
        a.word(0x224B)                                    // movea.l a3,a1
        a.word(0x4EAE, 0xFF10)                            // jsr AddHead(a6)
        a.word(0x4EAE, 0xFF76)                            // jsr Permit(a6)
        a.label("nextFileSystem")
        a.word(0x49EC, 0x0040)                            // lea 64(a4),a4
        a.branch(0x6000, to: "fileSystemLoop")            // bra.s fileSystemLoop
        a.label("fileSystemsDone")
        a.word(0x43F9); a.long(a.address("expansionLibrary")) // lea expansionLibrary,a1
        a.word(0x7000, 0x4EAE, 0xFDD8)                    // moveq #0,d0 ; jsr OpenLibrary(a6)
        a.word(0x4A80)                                    // tst.l d0
        a.branchWord(0x6700, to: "initDone")              // beq initDone
        a.word(0x2C40)                                    // movea.l d0,a6 (ExpansionBase)
        a.word(0x91C8)                                    // suba.l a0,a0
        a.word(0x203C); a.long(UInt32(ExpansionBus.manufacturer)) // move.l #manufacturer,d0
        a.word(0x7200 | UInt16(ExpansionBus.hardDiskProduct))     // moveq #product,d1
        a.word(0x4EAE, 0xFFB8)                            // jsr FindConfigDev(a6)
        a.word(0x2640)                                    // movea.l d0,a3 (ConfigDev)
        a.word(0x49F9); a.long(a.address("partitionTable")) // lea partitionTable,a4
        // For each table entry (packet address, boot priority, DosType of a file system
        // from the partition table or 0) until a zero address:
        a.label("partitionLoop")
        a.word(0x201C)                                    // move.l (a4)+,d0
        a.branchWord(0x6700, to: "closeExpansion")        // beq closeExpansion
        a.word(0x2040)                                    // movea.l d0,a0
        a.word(0x4EAE, 0xFF70)                            // jsr MakeDosNode(a6)
        a.word(0x4A80)                                    // tst.l d0
        a.branchWord(0x6700, to: "nextPartition")         // beq nextPartition
        a.word(0x2440)                                    // movea.l d0,a2 (DeviceNode)
        // Patch the node from the resource's entry for the partition's type.
        a.word(0x202C, 0x0004)                            // move.l 4(a4),d0
        a.branch(0x6700, to: "patched")                   // beq.s patched
        a.word(0x4A83)                                    // tst.l d3
        a.branch(0x6700, to: "patched")                   // beq.s patched
        a.branchWord(0x6100, to: "findFileSystem")        // bsr findFileSystem
        a.branch(0x6700, to: "patched")                   // beq.s patched
        a.word(0x2040)                                    // movea.l d0,a0
        a.word(0x2228, 0x0016)                            // move.l fse_PatchFlags(a0),d1
        a.word(0x41E8, 0x001A)                            // lea fse_Type(a0),a0
        a.word(0x43EA, 0x0004)                            // lea dn_Type(a2),a1
        a.word(0x7008)                                    // moveq #8,d0
        a.label("patchField")
        a.word(0xE289)                                    // lsr.l #1,d1
        a.branch(0x6400, to: "keepField")                 // bcc.s keepField
        a.word(0x2290)                                    // move.l (a0),(a1)
        a.label("keepField")
        a.word(0x5888, 0x5889)                            // addq.l #4,a0 ; addq.l #4,a1
        a.branchWord(0x51C8, to: "patchField")            // dbra d0,patchField
        a.label("patched")
        a.word(0x0C6E, 0x0024, 0x0014)                    // cmpi.w #36,lib_Version(a6)
        a.branch(0x6D00, to: "version34")                 // blt.s version34
        a.word(0x204A, 0x224B)                            // movea.l a2,a0 ; movea.l a3,a1
        a.word(0x2014, 0x7201)                            // move.l (a4),d0 (boot priority) ; moveq #ADNF_STARTPROC,d1
        a.word(0x4EAE, 0xFFDC)                            // jsr AddBootNode(a6)
        a.branch(0x6000, to: "nextPartition")             // bra.s nextPartition
        // Kickstart 1.3: queue a BootNode on eb_MountList by hand.
        a.label("version34")
        a.word(0x2F0E, 0x2C78, 0x0004)                    // move.l a6,-(sp) ; movea.l 4.w,a6
        a.word(0x7014)                                    // moveq #BootNode_SIZEOF,d0
        a.word(0x223C); a.long(0x0001_0001)               // move.l #MEMF_PUBLIC|MEMF_CLEAR,d1
        a.word(0x4EAE, 0xFF3A)                            // jsr AllocMem(a6)
        a.word(0x2C5F)                                    // movea.l (sp)+,a6
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6700, to: "nextPartition")             // beq.s nextPartition
        a.word(0x2240)                                    // movea.l d0,a1
        a.word(0x137C, 0x0010, 0x0008)                    // move.b #NT_BOOTNODE,ln_Type(a1)
        a.word(0x136C, 0x0003, 0x0009)                    // move.b 3(a4),ln_Pri(a1) (boot priority)
        a.word(0x234B, 0x000A)                            // move.l a3,ln_Name(a1) (ConfigDev)
        a.word(0x234A, 0x0010)                            // move.l a2,bn_DeviceNode(a1)
        a.word(0x41EE, 0x004A)                            // lea eb_MountList(a6),a0
        a.word(0x2F0E, 0x2C78, 0x0004)                    // move.l a6,-(sp) ; movea.l 4.w,a6
        a.word(0x4EAE, 0xFEF2)                            // jsr Enqueue(a6)
        a.word(0x2C5F)                                    // movea.l (sp)+,a6
        a.label("nextPartition")
        a.word(0x508C)                                    // addq.l #8,a4
        a.branchWord(0x6000, to: "partitionLoop")         // bra partitionLoop
        a.label("closeExpansion")
        a.word(0x224E, 0x2C78, 0x0004)                    // movea.l a6,a1 ; movea.l 4.w,a6
        a.word(0x4EAE, 0xFE62)                            // jsr CloseLibrary(a6)
        a.label("initDone")
        a.word(0x2002)                                    // move.l d2,d0
        a.word(0x4CDF, 0x5C1C, 0x4E75)                    // movem.l (sp)+,d2-d4/a2-a4/a6 ; rts
        // findFileSystem(d0 DosType, d3 resource) -> d0 = the entry of that type with the
        // highest version, or 0; Z set accordingly. Changes d1, a0 and a1.
        a.label("findFileSystem")
        a.word(0x2043)                                    // movea.l d3,a0
        a.word(0x2068, 0x0012)                            // movea.l fsr_FileSysEntries(a0),a0 (first node)
        a.word(0x93C9)                                    // suba.l a1,a1 (best so far)
        a.label("findNext")
        a.word(0x4A90)                                    // tst.l (a0) (ln_Succ; 0 in the list's tail)
        a.branch(0x6700, to: "findDone")                  // beq.s findDone
        a.word(0xB0A8, 0x000E)                            // cmp.l fse_DosType(a0),d0
        a.branch(0x6600, to: "findSkip")                  // bne.s findSkip
        a.word(0x2209)                                    // move.l a1,d1
        a.branch(0x6700, to: "findTake")                  // beq.s findTake
        a.word(0x2228, 0x0012)                            // move.l fse_Version(a0),d1
        a.word(0xB2A9, 0x0012)                            // cmp.l fse_Version(a1),d1
        a.branch(0x6300, to: "findSkip")                  // bls.s findSkip
        a.label("findTake")
        a.word(0x2248)                                    // movea.l a0,a1
        a.label("findSkip")
        a.word(0x2050)                                    // movea.l (a0),a0
        a.branch(0x6000, to: "findNext")                  // bra.s findNext
        a.label("findDone")
        a.word(0x2009, 0x4E75)                            // move.l a1,d0 ; rts

        // Open(a6 device, a1 request, d0 unit): only unit 0 exists
        a.label("open")
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6600, to: "openFailed")                // bne.s openFailed
        a.word(0x526E, 0x0020)                            // addq.w #1,lib_OpenCnt(a6)
        a.word(0x234E, 0x0018)                            // move.l a6,io_Unit(a1)
        a.word(0x4229, 0x001F)                            // clr.b io_Error(a1)
        a.word(0x7000, 0x4E75)                            // moveq #0,d0 ; rts
        a.label("openFailed")
        a.word(0x70FF, 0x1340, 0x001F, 0x4E75)            // moveq #IOERR_OPENFAIL,d0 ; move.b d0,io_Error(a1) ; rts
        a.label("close")
        a.word(0x536E, 0x0020)                            // subq.w #1,lib_OpenCnt(a6)
        a.label("null")                                   // Expunge, ExtFunc, AbortIO
        a.word(0x7000, 0x4E75)                            // moveq #0,d0 ; rts
        // BeginIO(a1 request): the host runs the command; reply unless quick or kept
        a.label("beginIO")
        a.word(0x23C9); a.long(request)                   // move.l a1,(request).l
        a.word(0x4AB9); a.long(request)                   // tst.l (request).l
        a.branch(0x6600, to: "beginDone")                 // bne.s beginDone
        a.word(0x0829, 0x0000, 0x001E)                    // btst #IOB_QUICK,io_Flags(a1)
        a.branch(0x6600, to: "beginDone")                 // bne.s beginDone
        a.word(0x2F0E, 0x2C78, 0x0004)                    // move.l a6,-(sp) ; movea.l 4.w,a6
        a.word(0x4EAE, 0xFE86)                            // jsr ReplyMsg(a6)
        a.word(0x2C5F)                                    // movea.l (sp)+,a6
        a.label("beginDone")
        a.word(0x4E75)                                    // rts

        a.label("deviceName"); a.string(deviceName)
        a.label("idString"); a.string(deviceName + " 1.0 (25.11.2026)\r\n")
        a.label("expansionLibrary"); a.string("expansion.library")
        a.label("dosLibrary"); a.string("dos.library")
        for (index, partition) in disk.partitions.enumerated() {
            a.label("dosName\(index)"); a.string(partition.name)
            // MakeDosNode parameter packet: names, unit, flags, then the DosEnvec.
            a.label("parameters\(index)")
            a.long(a.address("dosName\(index)"), a.address("deviceName"), 0, partition.deviceFlags)
            for value in partition.environment { a.long(value) }
        }
        a.label("partitionTable")
        let fileSystems = disk.fileSystems.prefix(fileSystemLimit)
        for (index, partition) in disk.partitions.enumerated() {
            a.long(a.address("parameters\(index)"), UInt32(bitPattern: Int32(partition.bootPriority)),
                   fileSystems.contains { $0.dosType == partition.dosType } ? partition.dosType : 0)
        }
        a.long(0)
        a.label("fileSystemResource"); a.string("FileSystem.resource")
        for (index, fileSystem) in fileSystems.enumerated() {
            a.label("fileSystemName\(index)"); a.string(fileSystem.name.isEmpty ? deviceName : fileSystem.name)
        }
        a.label("fileSystemTable")
        for (index, fileSystem) in fileSystems.enumerated() where fileSystem.dosType != 0 {
            // FileSysEntry from fse_DosType on; the segment list is filled in after loading.
            a.long(fileSystem.dosType, fileSystem.version, fileSystem.patchFlags)
            for (field, value) in fileSystem.fields.enumerated() { a.long(field == 7 ? 0 : value) }
            a.long(UInt32(fileSystem.program?.loadSize ?? 0),
                   fileSystem.program?.needsChipMemory == true ? 3 : 1, // MEMF_PUBLIC, MEMF_CHIP
                   base + UInt32(fileSystemRegisters + index * 4),
                   a.address("fileSystemName\(index)"))
        }
        a.long(0)
        return (a.bytes, a.labels)
    }
}

extension AmigaMemory {
    func readHardDiskBoard(offset: Int) -> UInt8 {
        if offset < hardDiskController.rom.count { return hardDiskController.rom[offset] }
        if offset == HardDiskController.requestRegister + 3 { return hardDiskController.requestPending ? 1 : 0 }
        return 0
    }

    /// Register bytes shift into a latch; the fourth byte of a long word triggers the action.
    mutating func writeHardDiskBoard(offset: Int, value: UInt8) {
        let fileSystem = (offset - HardDiskController.fileSystemRegisters) / 4
        guard offset >= HardDiskController.requestRegister,
              offset < HardDiskController.deviceRegister + 4
                || (offset >= HardDiskController.fileSystemRegisters && fileSystem < HardDiskController.fileSystemLimit) else { return }
        hardDiskController.latch = hardDiskController.latch << 8 | UInt32(value)
        guard offset & 3 == 3 else { return }
        let value = hardDiskController.latch
        switch offset & ~3 {
        case HardDiskController.fileSystemRegisters...:
            guard let systems = hardDisk?.fileSystems, fileSystem < systems.count, let program = systems[fileSystem].program else { return }
            for (index, byte) in program.loaded(at: value).enumerated() { try? writeByte(byte, at: value &+ UInt32(index)) }
        case HardDiskController.requestRegister:
            performHardDiskRequest(value)
        case HardDiskController.diagnosticRegister:
            guard let tag = hardDiskController.labels["romTag"], let end = hardDiskController.labels["copyEnd"] else { return }
            try? writeLong(value &+ UInt32(tag), at: value &+ UInt32(tag) &+ 2)   // rt_MatchTag
            try? writeLong(value &+ UInt32(end), at: value &+ UInt32(tag) &+ 6)   // rt_EndSkip
        default:
            guard let name = hardDiskController.address(of: "deviceName"),
                  let id = hardDiskController.address(of: "idString") else { return }
            try? writeByte(3, at: value &+ 8)        // ln_Type NT_DEVICE
            try? writeLong(name, at: value &+ 10)    // ln_Name
            try? writeByte(0x06, at: value &+ 14)    // lib_Flags LIBF_SUMUSED|LIBF_CHANGED
            try? writeLong(0x0001_0000, at: value &+ 20) // lib_Version 1, lib_Revision 0
            try? writeLong(id, at: value &+ 24)      // lib_IdString
        }
    }

    /// Runs the IORequest at `request` to completion and stores io_Error and io_Actual.
    private mutating func performHardDiskRequest(_ request: UInt32) {
        var status: Int8 = 0
        var actual: UInt32 = 0
        hardDiskController.requestPending = false
        do {
            guard let disk = hardDisk else { return }
            let command = try readWord(at: request &+ 28)
            let length = try readLong(at: request &+ 36)
            let data = try readLong(at: request &+ 40)
            let offset = try readLong(at: request &+ 44)
            let inRange = UInt64(offset) + UInt64(length) <= UInt64(disk.capacity)
            switch command {
            case 2: // CMD_READ
                guard inRange else { status = -4; break } // IOERR_BADLENGTH
                var address = data
                for byte in disk.read(at: Int(offset), count: Int(length)) {
                    try writeByte(byte, at: address)
                    address &+= 1
                }
                actual = length
            case 3, 11: // CMD_WRITE, TD_FORMAT
                guard inRange else { status = -4; break }
                guard !disk.isWriteProtected else { status = 28; break } // TDERR_WriteProt
                var bytes = [UInt8]()
                bytes.reserveCapacity(Int(length))
                for index in 0..<length { bytes.append(try readByte(at: data &+ index)) }
                disk.write(bytes, at: Int(offset))
                actual = length
            case 1, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 21:
                // CMD_RESET/UPDATE/CLEAR/STOP/START/FLUSH, TD_MOTOR/SEEK/REMOVE/CHANGENUM,
                // TD_CHANGESTATE (0 = disk present), TD_REMCHANGEINT: nothing to do.
                break
            case 15: // TD_PROTSTATUS
                actual = disk.isWriteProtected ? 1 : 0
            case 19: // TD_GETNUMTRACKS
                actual = UInt32(disk.cylinders)
            case 20: // TD_ADDCHANGEINT: kept until TD_REMCHANGEINT; the disk never changes
                hardDiskController.requestPending = true
                try writeByte(try readByte(at: request &+ 30) & ~0x01, at: request &+ 30) // not quick
                try writeByte(5, at: request &+ 8) // ln_Type NT_MESSAGE
                return
            case 22: // TD_GETGEOMETRY
                // dg_SectorSize, TotalSectors, Cylinders, CylSectors, Heads, TrackSectors, BufMemType, type and flags
                let cylinderBlocks = disk.surfaces * disk.sectorsPerTrack
                let geometry = [HardDisk.blockSize, disk.cylinders * cylinderBlocks, disk.cylinders, cylinderBlocks,
                                disk.surfaces, disk.sectorsPerTrack, 1, 0].map { UInt32($0) }
                for (index, value) in geometry.enumerated() { try writeLong(value, at: data &+ UInt32(index * 4)) }
                actual = 32
            default:
                status = -3 // IOERR_NOCMD
            }
        } catch {
            status = -5 // IOERR_BADADDRESS
        }
        try? writeByte(UInt8(bitPattern: status), at: request &+ 31)
        if request & 1 == 0 { try? writeLong(actual, at: request &+ 32) }
    }
}
