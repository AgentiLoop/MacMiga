import Testing
@testable import MacMigaCore

private struct TestPartition {
    var name: String
    var low: Int
    var high: Int
    /// pb_Flags: bit 0 bootable, bit 1 no automount.
    var flags: UInt32 = 1
    var bootPriority: Int32 = 0
    var dosType: UInt32 = 0x444F_5301
    var tableSize: UInt32 = 16
    var sizeBlock: UInt32 = 128
    var deviceFlags: UInt32 = 0
}

private func put(_ value: UInt32, _ image: inout [UInt8], _ block: Int, _ offset: Int) {
    for index in 0..<4 { image[block * 512 + offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(24 - index * 8)) }
}

/// Sets the checksum at offset 8 so that the block's first `longs` long words add up to zero.
private func seal(_ image: inout [UInt8], _ block: Int, longs: Int = 64) {
    put(0, &image, block, 8)
    var sum: UInt32 = 0
    for index in 0..<longs {
        let at = block * 512 + index * 4
        sum &+= UInt32(image[at]) << 24 | UInt32(image[at + 1]) << 16 | UInt32(image[at + 2]) << 8 | UInt32(image[at + 3])
    }
    put(0 &- sum, &image, block, 8)
}

private func dataByte(_ offset: Int) -> UInt8 { UInt8(truncatingIfNeeded: offset &* 13 &+ offset >> 9) }

/// A disk of 2 heads and 16 sectors whose byte at offset n is `dataByte(n)`, with a Rigid
/// Disk Block in block `first` and the partition blocks behind it.
private func rigidDisk(cylinders: Int = 20, at first: Int = 0, _ partitions: [TestPartition]) -> [UInt8] {
    var image = (0..<cylinders * 32 * 512).map(dataByte)
    for block in first...first + partitions.count { image.replaceSubrange(block * 512..<(block + 1) * 512, with: [UInt8](repeating: 0, count: 512)) }
    image.replaceSubrange(first * 512..<first * 512 + 4, with: Array("RDSK".utf8))
    put(64, &image, first, 4)                                   // rdb_SummedLongs
    put(7, &image, first, 12)                                   // rdb_HostID
    put(512, &image, first, 16)                                 // rdb_BlockBytes
    for offset in stride(from: 24, to: 64, by: 4) { put(0xFFFF_FFFF, &image, first, offset) } // lists, reserved
    if !partitions.isEmpty { put(UInt32(first + 1), &image, first, 28) } // rdb_PartitionList
    put(UInt32(cylinders), &image, first, 64)
    put(16, &image, first, 68)                                  // rdb_Sectors
    put(2, &image, first, 72)                                   // rdb_Heads
    seal(&image, first)
    for (index, partition) in partitions.enumerated() {
        let block = first + 1 + index
        image.replaceSubrange(block * 512..<block * 512 + 4, with: Array("PART".utf8))
        put(64, &image, block, 4)
        put(7, &image, block, 12)
        put(index + 1 < partitions.count ? UInt32(block + 1) : 0xFFFF_FFFF, &image, block, 16) // pb_Next
        put(partition.flags, &image, block, 20)
        put(partition.deviceFlags, &image, block, 32)
        let name = partition.name.unicodeScalars.map { UInt8($0.value) }
        image[block * 512 + 36] = UInt8(name.count)
        image.replaceSubrange(block * 512 + 37..<block * 512 + 37 + name.count, with: name)
        let environment: [UInt32] = [partition.tableSize, partition.sizeBlock, 0, 2, 1, 16, 2, 0, 0,
                                     UInt32(partition.low), UInt32(partition.high), 30, 1, 0x7FFF_FFFF, 0x7FFF_FFFE,
                                     UInt32(bitPattern: partition.bootPriority), partition.dosType, 0x1111, 0x2222, 2]
        for (entry, value) in environment.enumerated() { put(value, &image, block, 128 + entry * 4) }
        seal(&image, block)
    }
    return image
}

private let twoPartitions = [
    TestPartition(name: "DH0", low: 2, high: 9),
    TestPartition(name: "Work", low: 10, high: 17, flags: 0, bootPriority: 3, dosType: 0x444F_5303, tableSize: 19,
                  deviceFlags: 0x55),
    TestPartition(name: "Hidden", low: 18, high: 19, flags: 3)
]

@Test func partitionTableIsRead() throws {
    for first in [0, 3, 15] {
        let image = rigidDisk(at: first, twoPartitions)
        let disk = try HardDisk(image: image)
        #expect(disk.isPartitioned)
        #expect(disk.capacity == image.count)
        #expect(disk.cylinders == 20 && disk.surfaces == 2 && disk.sectorsPerTrack == 16)
        #expect(disk.partitions.map(\.name) == ["DH0", "Work"]) // "Hidden" is flagged no automount
        #expect(disk.partitions.map(\.bootPriority) == [0, -128]) // "Work" is not flagged bootable
        #expect(disk.partitions.map(\.firstBlock) == [64, 320])
        #expect(disk.partitions.map(\.blockCount) == [256, 256])
        #expect(disk.partitions.map(\.dosType) == [0x444F_5301, 0x444F_5303])
        #expect(disk.partitions.map(\.deviceFlags) == [0, 0x55])
        #expect(disk.partitions[0].environment == [16, 128, 0, 2, 1, 16, 2, 0, 0, 2, 9, 30, 1, 0x7FFF_FFFF, 0x7FFF_FFFE, 0, 0x444F_5301])
        #expect(disk.partitions[1].environment.count == 20)
        #expect(disk.partitions[1].environment.suffix(4) == [0x444F_5303, 0x1111, 0x2222, 2])
    }
    // Bootable partitions keep their priority; an unnamed one is named after its position.
    let disk = try HardDisk(image: rigidDisk([TestPartition(name: "A", low: 1, high: 4, bootPriority: -5),
                                              TestPartition(name: "", low: 5, high: 8, bootPriority: 4)]))
    #expect(disk.partitions.map(\.name) == ["A", "DH1"])
    #expect(disk.partitions.map(\.bootPriority) == [-5, 4])
    // A table longer than the DosEnvec that is known is cut to 20 entries.
    let long = try HardDisk(image: rigidDisk([TestPartition(name: "A", low: 1, high: 4, tableSize: 40)]))
    #expect(long.partitions[0].environment.count == 20 && long.partitions[0].environment[0] == 19)
}

@Test func damagedOrUnsupportedPartitionTablesAreRejected() throws {
    func check(_ expected: HardDiskError, _ partitions: [TestPartition] = twoPartitions, cylinders: Int = 20,
               _ damage: (inout [UInt8]) -> Void = { _ in }) {
        var image = rigidDisk(cylinders: cylinders, partitions)
        damage(&image)
        #expect(throws: expected) { try HardDisk(image: image) }
    }
    check(.invalidPartitionTable(block: 0)) { $0[100] ^= 1 }                        // RDSK checksum
    check(.invalidPartitionTable(block: 2)) { $0[2 * 512 + 200] ^= 1 }              // PART checksum
    check(.invalidPartitionTable(block: 2)) { $0[2 * 512] = 0x58; seal(&$0, 2) }    // not "PART"
    check(.invalidPartitionTable(block: 1)) { put(1, &$0, 2, 16); seal(&$0, 2) }    // chain returns to block 1
    check(.invalidPartitionTable(block: 5000)) { put(5000, &$0, 1, 16); seal(&$0, 1) } // chain leaves the disk
    check(.invalidPartitionTable(block: 1), [TestPartition(name: "A", low: 1, high: 4, tableSize: 9)])
    check(.unsupportedBlockSize(1024)) { put(1024, &$0, 0, 16); seal(&$0, 0) }
    check(.unsupportedBlockSize(1024), [TestPartition(name: "A", low: 1, high: 4, sizeBlock: 256)])
    check(.partitionOutsideImage("Work"), cylinders: 17)
    check(.partitionOutsideImage("A"), [TestPartition(name: "A", low: 5, high: 4)])
    check(.noPartitions, [TestPartition(name: "A", low: 1, high: 4, flags: 2)])
    check(.noPartitions, [])
    // A file system in block 0 makes the image a hardfile, whatever follows.
    var hardfile = rigidDisk(at: 1, twoPartitions)
    hardfile.replaceSubrange(0..<4, with: [0x44, 0x4F, 0x53, 0x01])
    let disk = try HardDisk(image: hardfile)
    #expect(!disk.isPartitioned && disk.partitions.map(\.name) == ["DH0"])
    // "RDSK" beyond the first 16 blocks is not a partition table either.
    #expect(try !HardDisk(image: rigidDisk(at: 16, twoPartitions)).isPartitioned)
}

// MARK: The controller with a partitioned disk

private func rom() -> [UInt8] {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom.replaceSubrange(0..<8, with: [0x00, 0x00, 0x80, 0x00, 0x00, 0xFC, 0x00, 0xD2])
    return rom
}

/// A machine with the hard-disk board configured at `$E90000` and the overlay off.
private func boardMachine(_ disk: HardDisk) throws -> AmigaMachine {
    var machine = try AmigaMachine(kickstart: rom(), slowRAMSize: 0, hardDisk: disk)
    machine.memory.setOverlay(enabled: false)
    try machine.memory.writeByte(0x90, at: 0xE8_004A)
    try machine.memory.writeByte(0xE9, at: 0xE8_0048)
    return machine
}

private func string(_ memory: inout AmigaMemory, at address: UInt32) -> String {
    var bytes: [UInt8] = [], address = address
    while let byte = try? memory.readByte(at: address), byte != 0 { bytes.append(byte); address += 1 }
    return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
}

private func longs(_ memory: inout AmigaMemory, at address: UInt32, count: Int) throws -> [UInt32] {
    try (0..<count).map { try memory.readLong(at: address + UInt32($0 * 4)) }
}

@Test func bootROMCarriesOnePacketPerPartition() throws {
    var partitions = twoPartitions
    partitions[1].name = "Daten\u{FC}"
    var machine = try boardMachine(HardDisk(image: rigidDisk(partitions)))
    let controller = machine.memory.hardDiskController
    let first = try #require(controller.address(of: "parameters0"))
    let second = try #require(controller.address(of: "parameters1"))
    #expect(controller.address(of: "parameters2") == nil)
    let device = try #require(controller.address(of: "deviceName"))

    var packet = try longs(&machine.memory, at: first, count: 4 + 17)
    #expect(string(&machine.memory, at: packet[0]) == "DH0")
    #expect(packet[1] == device && packet[2] == 0 && packet[3] == 0)
    #expect(Array(packet[4...]) == [16, 128, 0, 2, 1, 16, 2, 0, 0, 2, 9, 30, 1, 0x7FFF_FFFF, 0x7FFF_FFFE, 0, 0x444F_5301])
    packet = try longs(&machine.memory, at: second, count: 4 + 20)
    #expect(string(&machine.memory, at: packet[0]) == "Datenü")
    #expect(packet[1] == device && packet[2] == 0 && packet[3] == 0x55)
    #expect(Array(packet[4...]) == [19, 128, 0, 2, 1, 16, 2, 0, 0, 10, 17, 30, 1, 0x7FFF_FFFF, 0x7FFF_FFFE, 3, 0x444F_5303,
                                   0x1111, 0x2222, 2])
    let table = try #require(controller.address(of: "partitionTable"))
    // Packet, boot priority, and no file system from the partition table to look up.
    #expect(try longs(&machine.memory, at: table, count: 7) == [first, 0, 0, second, 0xFFFF_FF80, 0, 0])
    let fileSystems = try #require(controller.address(of: "fileSystemTable"))
    #expect(try machine.memory.readLong(at: fileSystems) == 0)
}

@Test func requestsReachEveryBlockOfAPartitionedDisk() throws {
    let disk = try HardDisk(image: rigidDisk(twoPartitions))
    var machine = try boardMachine(disk)
    func request(command: UInt16, offset: UInt32 = 0, length: UInt32 = 0) throws -> (error: UInt8, actual: UInt32) {
        try machine.memory.writeWord(command, at: 0x1000 + 28)
        try machine.memory.writeByte(1, at: 0x1000 + 30)
        try machine.memory.writeLong(length, at: 0x1000 + 36)
        try machine.memory.writeLong(0x2000, at: 0x1000 + 40)
        try machine.memory.writeLong(offset, at: 0x1000 + 44)
        try machine.memory.writeLong(0x1000, at: 0xE9_8000)
        return (try machine.memory.readByte(at: 0x1000 + 31), try machine.memory.readLong(at: 0x1000 + 32))
    }
    // The second partition's first block, and the last block of the disk.
    let work = UInt32(disk.partitions[1].firstBlock * 512)
    #expect(try request(command: 2, offset: work, length: 512) == (0, 512))
    #expect(try machine.memory.readByte(at: 0x2000 + 5) == dataByte(Int(work) + 5))
    let last = UInt32(disk.bytes.count - 512)
    #expect(try request(command: 2, offset: last, length: 512) == (0, 512))
    #expect(try machine.memory.readByte(at: 0x2000 + 511) == dataByte(disk.bytes.count - 1))
    #expect(try request(command: 2, offset: last, length: 1024) == (0xFC, 0)) // IOERR_BADLENGTH
    // A write lands at the absolute offset.
    try machine.memory.writeLong(0xCAFE_F00D, at: 0x2000)
    #expect(try request(command: 3, offset: work + 1024, length: 512) == (0, 512))
    #expect(Array(disk.bytes[Int(work) + 1024..<Int(work) + 1028]) == [0xCA, 0xFE, 0xF0, 0x0D])
    #expect(disk.takeModifiedBlocks() == [322])
    // Geometry comes from the Rigid Disk Block.
    #expect(try request(command: 19) == (0, 20)) // TD_GETNUMTRACKS
    #expect(try request(command: 22) == (0, 32)) // TD_GETGEOMETRY
    #expect(try longs(&machine.memory, at: 0x2000, count: 6) == [512, 640, 20, 32, 2, 16])
}

/// Runs the boot ROM's device initialisation against stand-in exec and expansion libraries
/// whose functions log their arguments through A5. Returns the log.
///
/// With `fileSystems`, the stand-ins are those the installation of file systems needs:
/// OpenResource logs the name and returns `resource`; AllocMem logs size and type and hands
/// out memory from `$10000` on in multiples of 8; AddResource logs the resource; Forbid and
/// Permit log `FORB` and `PERM`; AddHead logs list and node and links the node in; and
/// MakeDosNode returns nodes in RAM, `$7800`, `$7840` and so on, instead of the packet.
private func initialize(_ machine: inout AmigaMachine, expansionVersion: UInt16, fileSystems: Bool = false,
                        resource: UInt32 = 0) throws -> [UInt32] {
    let exec: UInt32 = 0x5000, expansion: UInt32 = 0x5800, log: UInt32 = 0x7000
    var code: UInt32 = 0x6100
    func stub(_ base: UInt32, _ offset: Int32, _ words: [UInt16]) throws {
        let vector = UInt32(bitPattern: Int32(base) + offset)
        try machine.memory.writeWord(0x4EF9, at: vector) // jmp (code).l
        try machine.memory.writeLong(code, at: vector + 2)
        for word in words { try machine.memory.writeWord(word, at: code); code += 2 }
    }
    try machine.memory.writeLong(exec, at: 4)
    try machine.memory.writeWord(expansionVersion, at: expansion + 20)
    try machine.memory.writeLong(0x6900, at: 0x6800) // next AllocMem result
    try stub(exec, -552, [0x203C, 0x0000, 0x5800, 0x4E75])                       // OpenLibrary: d0 = expansion
    try stub(exec, -414, [0x2AC9, 0x4E75])                                       // CloseLibrary: log a1
    try stub(exec, -198, [0x2039, 0x0000, 0x6800,                                // AllocMem: d0 = next, next += $20
                          0x06B9, 0x0000, 0x0020, 0x0000, 0x6800, 0x4E75])
    try stub(exec, -270, [0x2AC8, 0x2AC9, 0x4E75])                               // Enqueue: log a0, a1
    try stub(expansion, -72, [0x2AC0, 0x2AC1, 0x203C, 0x0000, 0x5A00, 0x4E75])   // FindConfigDev: log d0, d1
    try stub(expansion, -144, [0x2AC8, 0x2008, 0x4E75])                          // MakeDosNode: log a0, d0 = a0
    try stub(expansion, -36, [0x2AC8, 0x2AC9, 0x2AC0, 0x2AC1, 0x7001, 0x4E75])   // AddBootNode: log a0, a1, d0, d1
    if fileSystems {
        try machine.memory.writeLong(0x1_0000, at: 0x6800)  // next AllocMem result
        try machine.memory.writeLong(0x7800, at: 0x6804)    // next MakeDosNode result
        try machine.memory.writeLong(resource, at: 0x6808)  // OpenResource result
        try stub(exec, -498, [0x2AC9, 0x2039, 0x0000, 0x6808, 0x4E75])           // OpenResource: log a1
        try stub(exec, -198, [0x2AC0, 0x2AC1, 0x2200, 0x5E81, 0x0201, 0x00F8,    // AllocMem: log d0, d1; d1 = d0 rounded up
                              0x2039, 0x0000, 0x6800, 0xD3B9, 0x0000, 0x6800, 0x4E75]) // d0 = next, next += d1
        try stub(exec, -486, [0x2AC9, 0x4E75])                                   // AddResource: log a1
        try stub(exec, -132, [0x2AFC, 0x464F, 0x5242, 0x4E75])                   // Forbid
        try stub(exec, -138, [0x2AFC, 0x5045, 0x524D, 0x4E75])                   // Permit
        try stub(exec, -240, [0x2AC8, 0x2AC9,                                    // AddHead: log a0, a1, then as exec does:
                              0x2010, 0x2089, 0x48D1, 0x0101, 0x2040, 0x2149, 0x0004, 0x4E75])
        try stub(expansion, -144, [0x2AC8, 0x2039, 0x0000, 0x6804,               // MakeDosNode: log a0; d0 = next node
                                   0x06B9, 0x0000, 0x0040, 0x0000, 0x6804, 0x4E75])
    }

    let entry = try #require(machine.memory.hardDiskController.address(of: "initialize"))
    machine.cpu.statusRegister = 0x2700
    machine.cpu.supervisorStackPointer = 0x6FFC
    try machine.memory.writeLong(0x6000, at: 0x6FFC)
    machine.cpu.programCounter = entry
    machine.cpu[data: 0] = 0x4000 // the new device
    for register in 2...4 { machine.cpu[data: register] = 0xD0D0_D0D0 + UInt32(register) }
    for register in 2...4 { machine.cpu[address: register] = 0xA0A0_A0A0 + UInt32(register) }
    machine.cpu[address: 5] = log
    machine.cpu[address: 6] = exec
    for _ in 0..<5000 where machine.cpu.programCounter != 0x6000 { try machine.cpu.step(memory: &machine.memory) }
    #expect(machine.cpu.programCounter == 0x6000)
    #expect(machine.cpu.supervisorStackPointer == 0x7000)
    #expect(machine.cpu[data: 0] == 0x4000)
    #expect((2...4).map { machine.cpu[data: $0] } == [0xD0D0_D0D2, 0xD0D0_D0D3, 0xD0D0_D0D4])
    #expect((2...4).map { machine.cpu[address: $0] } == [0xA0A0_A0A2, 0xA0A0_A0A3, 0xA0A0_A0A4])
    #expect(machine.cpu[address: 6] == exec)
    #expect(try machine.memory.readByte(at: 0x4008) == 3) // the device node was filled in
    return try longs(&machine.memory, at: log, count: Int(machine.cpu[address: 5] - log) / 4)
}

@Test func initialisationQueuesEveryPartitionWithItsPriority() throws {
    var partitions = twoPartitions
    partitions[0].bootPriority = 2
    var machine = try boardMachine(HardDisk(image: rigidDisk(partitions)))
    let controller = machine.memory.hardDiskController
    let first = try #require(controller.address(of: "parameters0"))
    let second = try #require(controller.address(of: "parameters1"))
    // Kickstart 2.0 and newer: AddBootNode(priority, ADNF_STARTPROC, node, ConfigDev).
    #expect(try initialize(&machine, expansionVersion: 40) == [
        2011, 2,                                    // FindConfigDev(manufacturer, product)
        first, first, 0x5A00, 2, 1,                 // MakeDosNode, AddBootNode
        second, second, 0x5A00, 0xFFFF_FF80, 1,
        0x5800                                      // CloseLibrary(expansion)
    ])
    // Kickstart 1.3: a BootNode per partition on eb_MountList.
    #expect(try initialize(&machine, expansionVersion: 34) == [
        2011, 2,
        first, 0x5800 + 0x4A, 0x6900,               // MakeDosNode, Enqueue(list, node)
        second, 0x5800 + 0x4A, 0x6920,
        0x5800
    ])
    for (node, packet, priority): (UInt32, UInt32, UInt8) in [(0x6900, first, 2), (0x6920, second, 0x80)] {
        #expect(try machine.memory.readByte(at: node + 8) == 0x10)      // NT_BOOTNODE
        #expect(try machine.memory.readByte(at: node + 9) == priority)
        #expect(try machine.memory.readLong(at: node + 10) == 0x5A00)   // ConfigDev
        #expect(try machine.memory.readLong(at: node + 16) == packet)   // the device node (stand-in)
    }
    // A hardfile takes the same path with its single partition.
    var plain = try boardMachine(HardDisk(image: [UInt8](repeating: 0, count: 4 * HardDisk.cylinderSize)))
    let only = try #require(plain.memory.hardDiskController.address(of: "parameters0"))
    #expect(try initialize(&plain, expansionVersion: 40) == [2011, 2, only, only, 0x5A00, 0, 1, 0x5800])
}

// MARK: File systems in the partition table

private struct TestFileSystem {
    var dosType: UInt32 = 0x5046_5303 // PFS\3
    var version: UInt32 = 0x0013_0002
    var patchFlags: UInt32 = 0x190    // stack size, segment list, global vector
    /// fhb_Type … fhb_GlobalVec.
    var fields: [UInt32] = [0x10, 0x20, 0x30, 0x40, 4000, 0x60, 0x70, 0, 0xFFFF_FFFF]
    var name = "test-handler"
    var program: [UInt8] = testProgram
}

private func bytes(_ longs: [UInt32]) -> [UInt8] {
    longs.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - $0 * 8)) } }
}

/// A load file of three hunks: code of 3 long words in 4, with relocations to hunk 1 and to
/// itself and a symbol; data of 2 long words with a short relocation to hunk 2 and a debug
/// block; and 5 long words of BSS that ask for chip memory.
private let testProgram: [UInt8] = bytes([
    0x3F3, 0, 3, 0, 2, 4, 2, 0x4000_0005,
    0x3E9, 3, 0x1111_1111, 4, 8,
    0x3EC, 1, 1, 4, 1, 0, 8, 0,
    0x3F0, 1, 0x6162_6364, 0x1234, 0,
    0x3F2,
    0x3EA, 2, 0x2222_2222, 0,
    0x3FC, 0x0001_0002, 0x0004_0000,
    0x3F1, 2, 0xDEAD_BEEF, 0xDEAD_BEEF,
    0x3F2,
    0x3EB, 5,
    0x3F2
])

/// Puts file systems into the partition table of `image`: a header block each from block
/// `first` on, followed by its program in LoadSeg blocks.
private func addFileSystems(_ systems: [TestFileSystem], to image: inout [UInt8], rigid: Int = 0, from first: Int = 8) {
    var block = first
    for (index, system) in systems.enumerated() {
        let chunks = stride(from: 0, to: system.program.count, by: 492).map { Array(system.program[$0..<min($0 + 492, system.program.count)]) }
        let header = block
        image.replaceSubrange(header * 512..<(header + 1 + chunks.count) * 512, with: [UInt8](repeating: 0, count: (1 + chunks.count) * 512))
        image.replaceSubrange(header * 512..<header * 512 + 4, with: Array("FSHD".utf8))
        put(64, &image, header, 4)
        put(7, &image, header, 12)
        put(index + 1 < systems.count ? UInt32(header + 1 + chunks.count) : 0xFFFF_FFFF, &image, header, 16) // fhb_Next
        put(system.dosType, &image, header, 32)
        put(system.version, &image, header, 36)
        put(system.patchFlags, &image, header, 40)
        for (field, value) in system.fields.enumerated() { put(value, &image, header, 44 + field * 4) }
        put(chunks.isEmpty ? 0xFFFF_FFFF : UInt32(header + 1), &image, header, 72)  // fhb_SegListBlocks
        image.replaceSubrange(header * 512 + 172..<header * 512 + 172 + system.name.utf8.count, with: Array(system.name.utf8))
        seal(&image, header)
        for (number, chunk) in chunks.enumerated() {
            let data = header + 1 + number
            image.replaceSubrange(data * 512..<data * 512 + 4, with: Array("LSEG".utf8))
            put(128, &image, data, 4)
            put(7, &image, data, 12)
            put(number + 1 < chunks.count ? UInt32(data + 1) : 0xFFFF_FFFF, &image, data, 16)         // lsb_Next
            image.replaceSubrange(data * 512 + 20..<data * 512 + 20 + chunk.count, with: chunk)
            seal(&image, data, longs: 128)
        }
        block = header + 1 + chunks.count
    }
    put(systems.isEmpty ? 0xFFFF_FFFF : UInt32(first), &image, rigid, 32) // rdb_FileSysHeaderList
    seal(&image, rigid)
}

@Test func loadFileIsParsedAndLaidOutAsASegmentList() throws {
    let file = try HunkFile(testProgram)
    #expect(file.hunks.map(\.size) == [16, 8, 20])
    #expect(file.hunks.map(\.needsChipMemory) == [false, false, true])
    #expect(file.hunks.map(\.data.count) == [12, 8, 0])
    #expect(file.hunks[0].relocations == [HunkFile.Relocation(target: 1, offsets: [4]), HunkFile.Relocation(target: 0, offsets: [8])])
    #expect(file.hunks[1].relocations == [HunkFile.Relocation(target: 2, offsets: [4])])
    #expect(file.needsChipMemory)
    // Segments of 24, 16 and 32 bytes: length, BPTR to the next, contents.
    #expect(file.loadSize == 72)
    let at: UInt32 = 0x2_0000
    #expect(file.loaded(at: at) == bytes([
        24, (at + 24 + 4) / 4, 0x1111_1111, 4 + at + 24 + 8, 8 + at + 8, 0,
        16, (at + 40 + 4) / 4, 0x2222_2222, at + 40 + 8,
        32, 0, 0, 0, 0, 0, 0, 0
    ]))
    // The last hunk may end with the file, and a program need not have relocations.
    let plain = try HunkFile(bytes([0x3F3, 0, 1, 0, 0, 1, 0x3E9, 1, 0x4E75_4E71]))
    #expect(plain.loadSize == 16 && !plain.needsChipMemory)
    #expect(plain.loaded(at: 0x100) == bytes([16, 0, 0x4E75_4E71, 0]))
    // A size with both memory bits set is followed by the memory attributes.
    #expect(try HunkFile(bytes([0x3F3, 0, 1, 0, 0, 0xC000_0001, 2, 0x3EB, 1, 0x3F2])).needsChipMemory)

    func check(_ expected: HunkFileError, _ longs: [UInt32]) {
        #expect(throws: expected) { try HunkFile(bytes(longs)) }
    }
    check(.notALoadFile, [0x3E7, 0, 1, 0, 0, 1])                             // a link library
    check(.notALoadFile, [0x3F3, 1, 0x6162_6364, 0, 1, 0, 0, 1])             // names a resident library
    check(.notALoadFile, [0x3F3, 0, 2, 1, 1, 1])                             // hunks not numbered from 0
    check(.truncated, [0x3F3, 0, 1, 0, 0, 2, 0x3E9, 2, 0x4E75_4E71])         // data cut short
    check(.truncated, [0x3F3, 0, 2, 0, 1, 1, 1, 0x3E9, 1, 0, 0x3F2])         // second hunk missing
    check(.unsupportedBlock(0x3F5), [0x3F3, 0, 1, 0, 0, 1, 0x3F5, 0])        // an overlay
    check(.inconsistent, [0x3F3, 0, 1, 0, 0, 1, 0x3E9, 2, 0, 0, 0x3F2])      // more data than the header's size
    check(.inconsistent, [0x3F3, 0, 1, 0, 0, 1, 0x3E9, 1, 0, 0x3EC, 1, 0, 2, 0, 0x3F2]) // relocation past the end
    check(.inconsistent, [0x3F3, 0, 1, 0, 0, 1, 0x3E9, 1, 0, 0x3EC, 1, 1, 0, 0, 0x3F2]) // relocation to hunk 1 of 1
}

@Test func fileSystemsOfThePartitionTableAreRead() throws {
    // A second program long enough for three LoadSeg blocks.
    let filler = [UInt32](repeating: 0x4E71_4E71, count: 300)
    let long = bytes([0x3F3, 0, 1, 0, 0, 300, 0x3E9, 300] + filler + [0x3F2])
    let systems = [TestFileSystem(), TestFileSystem(dosType: 0x444F_5303, version: 0x002D_0001, patchFlags: 0x180, name: "", program: long)]
    var image = rigidDisk(twoPartitions)
    addFileSystems(systems, to: &image)
    let disk = try HardDisk(image: image)
    #expect(disk.partitions.map(\.name) == ["DH0", "Work"])
    #expect(disk.fileSystems.map(\.dosType) == [0x5046_5303, 0x444F_5303])
    #expect(disk.fileSystems.map(\.version) == [0x0013_0002, 0x002D_0001])
    #expect(disk.fileSystems.map(\.patchFlags) == [0x190, 0x180])
    #expect(disk.fileSystems.map(\.name) == ["test-handler", ""])
    #expect(disk.fileSystems[0].fields == [0x10, 0x20, 0x30, 0x40, 4000, 0x60, 0x70, 9, 0xFFFF_FFFF]) // SegList: block 9
    #expect(try disk.fileSystems[0].program == HunkFile(testProgram))
    #expect(disk.fileSystems[1].program?.hunks.map(\.data) == [bytes(filler)])
    // A hardfile has none, and neither has a table without the list.
    #expect(try HardDisk(image: [UInt8](repeating: 0, count: 4 * HardDisk.cylinderSize)).fileSystems.isEmpty)
    #expect(try HardDisk(image: rigidDisk(twoPartitions)).fileSystems.isEmpty)

    // A damaged LoadSeg block, a chain that runs into another block, or blocks that are no
    // load file: the file system is listed without a program.
    for damage: (inout [UInt8]) -> Void in [
        { $0[12 * 512 + 300] ^= 1 },                                  // checksum of the second program's block 2
        { put(1, &$0, 13, 16); seal(&$0, 13, longs: 128) },           // lsb_Next leads to a partition block
        { put(0x3E7, &$0, 11, 20); seal(&$0, 11, longs: 128) }        // not HUNK_HEADER
    ] {
        var damaged = image
        damage(&damaged)
        let disk = try HardDisk(image: damaged)
        #expect(disk.fileSystems.count == 2 && disk.fileSystems[0].program != nil && disk.fileSystems[1].program == nil)
    }
    // A damaged header block ends the list; the partitions stay usable.
    var damaged = image
    damaged[10 * 512 + 40] ^= 1
    #expect(try HardDisk(image: damaged).fileSystems.map(\.dosType) == [0x5046_5303])
    damaged = image
    put(8, &damaged, 10, 16)                                          // fhb_Next returns to the first header
    seal(&damaged, 10)
    let looped = try HardDisk(image: damaged)
    #expect(looped.fileSystems.count == 2 && looped.partitions.count == 2)
}

/// FileSystem.resource at `$8000` holding one entry at `$8100`.
private func makeResource(_ memory: inout AmigaMemory, dosType: UInt32, version: UInt32, patchFlags: UInt32,
                          fields: [UInt32]) throws {
    try memory.writeLong(0x8100, at: 0x8012)        // lh_Head
    try memory.writeLong(0, at: 0x8016)             // lh_Tail
    try memory.writeLong(0x8100, at: 0x801A)        // lh_TailPred
    try memory.writeLong(0x8016, at: 0x8100)        // ln_Succ
    try memory.writeLong(0x8012, at: 0x8104)        // ln_Pred
    for (index, value) in ([dosType, version, patchFlags] + fields).enumerated() {
        try memory.writeLong(value, at: 0x810E + UInt32(index * 4))
    }
}

private let pfsPartitions = [
    TestPartition(name: "DH0", low: 2, high: 9),
    TestPartition(name: "PDH1", low: 10, high: 17, flags: 0, dosType: 0x5046_5303)
]

@Test func initialisationInstallsAFileSystemFromThePartitionTable() throws {
    var image = rigidDisk(pfsPartitions)
    addFileSystems([TestFileSystem()], to: &image)
    let disk = try HardDisk(image: image)
    let program = try #require(disk.fileSystems[0].program)
    var machine = try boardMachine(disk)
    let controller = machine.memory.hardDiskController
    let first = try #require(controller.address(of: "parameters0"))
    let second = try #require(controller.address(of: "parameters1"))
    let table = try #require(controller.address(of: "partitionTable"))
    #expect(try longs(&machine.memory, at: table, count: 7) == [first, 0, 0, second, 0xFFFF_FF80, 0x5046_5303, 0])
    let resourceName = try #require(controller.address(of: "fileSystemResource"))
    #expect(string(&machine.memory, at: resourceName) == "FileSystem.resource")

    // The resource has PFS\3 in an older version and with other fields.
    try makeResource(&machine.memory, dosType: 0x5046_5303, version: 0x0013_0001, patchFlags: 0x1FF,
                     fields: [1, 2, 3, 4, 5, 6, 7, 0x1234, 9])
    // Marks in the two device nodes, to see what the patch leaves alone.
    for node: UInt32 in [0x7800, 0x7840] {
        for offset in stride(from: UInt32(0), to: 44, by: 4) { try machine.memory.writeLong(0xEEEE_0000 + offset, at: node + offset) }
    }
    #expect(try initialize(&machine, expansionVersion: 40, fileSystems: true, resource: 0x8000) == [
        resourceName,                               // OpenResource
        72, 3,                                      // AllocMem(program, MEMF_PUBLIC|MEMF_CHIP)
        62, 0x0001_0001,                            // AllocMem(FileSysEntry, MEMF_PUBLIC|MEMF_CLEAR)
        0x464F_5242, 0x8012, 0x1_0048, 0x5045_524D, // Forbid, AddHead(entries, entry), Permit
        2011, 2,                                    // FindConfigDev
        first, 0x7800, 0x5A00, 0, 1,                // MakeDosNode, AddBootNode
        second, 0x7840, 0x5A00, 0xFFFF_FF80, 1,
        0x5800                                      // CloseLibrary(expansion)
    ])
    // The program is in memory as a segment list.
    #expect(try (0..<72).map { try machine.memory.readByte(at: 0x1_0000 + $0) } == program.loaded(at: 0x1_0000))
    // The new entry heads the list, in front of the old one.
    #expect(try machine.memory.readLong(at: 0x8012) == 0x1_0048)
    #expect(try longs(&machine.memory, at: 0x1_0048, count: 2) == [0x8100, 0x8012])
    #expect(try machine.memory.readLong(at: 0x8104) == 0x1_0048)
    #expect(string(&machine.memory, at: try machine.memory.readLong(at: 0x1_0048 + 10)) == "test-handler")
    #expect(try longs(&machine.memory, at: 0x1_0048 + 14, count: 12) == [
        0x5046_5303, 0x0013_0002, 0x190, 0x10, 0x20, 0x30, 0x40, 4000, 0x60, 0x70, 0x1_0004 / 4, 0xFFFF_FFFF
    ])
    // DH0 (DOS\1, no file system in the table) is untouched; PDH1 took the stack size,
    // the segment list and the global vector, as the patch flags $190 say.
    #expect(try longs(&machine.memory, at: 0x7800, count: 11) == (0..<11).map { 0xEEEE_0000 + UInt32($0 * 4) })
    #expect(try longs(&machine.memory, at: 0x7840, count: 11) == [
        0xEEEE_0000, 0xEEEE_0004, 0xEEEE_0008, 0xEEEE_000C, 0xEEEE_0010, 4000, 0xEEEE_0018, 0xEEEE_001C,
        0x1_0004 / 4, 0xFFFF_FFFF, 0xEEEE_0028
    ])
}

@Test func aNewerFileSystemInTheResourceIsUsedInstead() throws {
    for resourceVersion: UInt32 in [0x0013_0002, 0x0014_0000] { // the same version, and a newer one
        var image = rigidDisk(pfsPartitions)
        addFileSystems([TestFileSystem()], to: &image)
        var machine = try boardMachine(HardDisk(image: image))
        let controller = machine.memory.hardDiskController
        let first = try #require(controller.address(of: "parameters0"))
        let second = try #require(controller.address(of: "parameters1"))
        try makeResource(&machine.memory, dosType: 0x5046_5303, version: resourceVersion, patchFlags: 0x1FF,
                         fields: [1, 2, 3, 4, 5, 6, 7, 0x1234, 9])
        #expect(try initialize(&machine, expansionVersion: 34, fileSystems: true, resource: 0x8000) == [
            try #require(controller.address(of: "fileSystemResource")),
            2011, 2,
            first, 20, 0x0001_0001, 0x5800 + 0x4A, 0x1_0000,    // MakeDosNode, AllocMem(BootNode), Enqueue
            second, 20, 0x0001_0001, 0x5800 + 0x4A, 0x1_0018,
            0x5800
        ])
        #expect(try machine.memory.readLong(at: 0x8012) == 0x8100) // nothing was added
        // Every field of the node from dn_Type on comes from the resource's entry.
        #expect(try longs(&machine.memory, at: 0x7840, count: 11) == [0, 1, 2, 3, 4, 5, 6, 7, 0x1234, 9, 0])
        #expect(try longs(&machine.memory, at: 0x7800, count: 11) == [UInt32](repeating: 0, count: 11))
    }
}

@Test func theResourceIsMadeWhenKickstartHasNone() throws {
    // Two file systems: the first cannot be read, the second is DOS\3 for "Work".
    var image = rigidDisk(twoPartitions)
    addFileSystems([TestFileSystem(program: bytes([0x3E7, 0])),
                    TestFileSystem(dosType: 0x444F_5303, patchFlags: 0x180, name: "")], to: &image)
    let disk = try HardDisk(image: image)
    #expect(disk.fileSystems.map { $0.program == nil } == [true, false])
    var machine = try boardMachine(disk)
    let controller = machine.memory.hardDiskController
    let first = try #require(controller.address(of: "parameters0"))
    let second = try #require(controller.address(of: "parameters1"))
    let resourceName = try #require(controller.address(of: "fileSystemResource"))
    #expect(try initialize(&machine, expansionVersion: 40, fileSystems: true) == [
        resourceName,                               // OpenResource finds nothing
        32, 0x0001_0001, 0x1_0000,                  // AllocMem(FileSysResource), AddResource
        72, 3, 62, 0x0001_0001,                     // the second file system and its entry
        0x464F_5242, 0x1_0012, 0x1_0068, 0x5045_524D,
        2011, 2,
        first, 0x7800, 0x5A00, 0, 1,
        second, 0x7840, 0x5A00, 0xFFFF_FF80, 1,
        0x5800
    ])
    // The resource: NT_RESOURCE, its name, and a list holding the one entry.
    #expect(try machine.memory.readByte(at: 0x1_0008) == 8)
    #expect(try machine.memory.readLong(at: 0x1_000A) == resourceName)
    #expect(try longs(&machine.memory, at: 0x1_0012, count: 3) == [0x1_0068, 0, 0x1_0068])
    #expect(try longs(&machine.memory, at: 0x1_0068, count: 2) == [0x1_0016, 0x1_0012])
    // Without a name in the table, the entry is named after the device.
    #expect(string(&machine.memory, at: try machine.memory.readLong(at: 0x1_0068 + 10)) == "macmiga.device")
    // "Work" got the segment list and the global vector; DH0 nothing (the table's PFS\3 is unreadable, and DH0 is DOS\1).
    #expect(try longs(&machine.memory, at: 0x7840 + 32, count: 2) == [0x1_0024 / 4, 0xFFFF_FFFF])
    #expect(try longs(&machine.memory, at: 0x7800, count: 11) == [UInt32](repeating: 0, count: 11))
    #expect(try machine.memory.readLong(at: 0x7840 + 20) == 0) // the stack size is not in patch flags $180

    // An unreadable program for a partition's own type: nothing is loaded and the node is
    // left to Kickstart.
    var unreadable = rigidDisk(pfsPartitions)
    addFileSystems([TestFileSystem(program: bytes([0x3E7, 0]))], to: &unreadable)
    var other = try boardMachine(HardDisk(image: unreadable))
    let log = try initialize(&other, expansionVersion: 40, fileSystems: true)
    #expect(Array(log[0..<4]) == [try #require(other.memory.hardDiskController.address(of: "fileSystemResource")), 32, 0x0001_0001, 0x1_0000])
    #expect(log[4] == 2011)
    #expect(try longs(&other.memory, at: 0x7840, count: 11) == [UInt32](repeating: 0, count: 11))
}

// MARK: Bad-block lists

/// Chains a BADB block for each list of (bad, replacement) pairs from block `first` on.
private func addBadBlocks(_ lists: [[(Int, Int)]], to image: inout [UInt8], from first: Int = 5) {
    for (index, pairs) in lists.enumerated() {
        let block = first + index
        image.replaceSubrange(block * 512..<(block + 1) * 512, with: [UInt8](repeating: 0, count: 512))
        image.replaceSubrange(block * 512..<block * 512 + 4, with: Array("BADB".utf8))
        put(UInt32(6 + 2 * pairs.count), &image, block, 4)
        put(7, &image, block, 12)
        put(index + 1 < lists.count ? UInt32(block + 1) : 0xFFFF_FFFF, &image, block, 16) // bbb_Next
        for (pair, (bad, good)) in pairs.enumerated() {
            put(UInt32(bad), &image, block, 24 + pair * 8)
            put(UInt32(good), &image, block, 28 + pair * 8)
        }
        seal(&image, block, longs: 6 + 2 * pairs.count)
    }
    put(lists.isEmpty ? 0xFFFF_FFFF : UInt32(first), &image, 0, 24) // rdb_BadBlockList
    seal(&image, 0)
}

@Test func badBlocksAreReadAndWrittenThroughTheirReplacements() throws {
    var image = rigidDisk(twoPartitions)
    addBadBlocks([[(100, 600), (101, 601), (7, 7)], [(200, 602), (5000, 603)]], to: &image)
    let disk = try HardDisk(image: image)
    #expect(disk.badBlocks == [100: 600, 101: 601, 200: 602]) // no self-mapping or block off the disk
    func blocks(_ numbers: [Int]) -> [UInt8] { numbers.flatMap { image[$0 * 512..<($0 + 1) * 512] } }
    #expect(Array(disk.read(at: 99 * 512, count: 4 * 512)) == blocks([99, 600, 601, 102]))
    #expect(Array(disk.read(at: 100 * 512 + 10, count: 20)) == Array(image[600 * 512 + 10..<600 * 512 + 30]))
    #expect(Array(disk.read(at: 50 * 512, count: 512)) == blocks([50]))

    let data = (0..<3 * 512).map { UInt8(truncatingIfNeeded: $0 &* 7) }
    disk.write(data, at: 199 * 512)
    #expect(disk.takeModifiedBlocks() == [199, 201, 602])
    #expect(Array(disk.bytes[602 * 512..<603 * 512]) == Array(data[512..<1024]))
    #expect(Array(disk.bytes[200 * 512..<201 * 512]) == blocks([200])) // the bad block itself is untouched
    #expect(Array(disk.read(at: 199 * 512, count: 3 * 512)) == data)

    // A damaged BADB block ends the list; the disk stays usable.
    var damaged = image
    damaged[6 * 512 + 30] ^= 1
    #expect(try HardDisk(image: damaged).badBlocks == [100: 600, 101: 601])
    #expect(try HardDisk(image: rigidDisk(twoPartitions)).badBlocks.isEmpty)
}
