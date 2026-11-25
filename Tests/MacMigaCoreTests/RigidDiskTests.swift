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

/// Sets the checksum at offset 8 so that the block's first 64 long words add up to zero.
private func seal(_ image: inout [UInt8], _ block: Int) {
    put(0, &image, block, 8)
    var sum: UInt32 = 0
    for index in 0..<64 {
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
    #expect(try longs(&machine.memory, at: table, count: 5) == [first, 0, second, 0xFFFF_FF80, 0])
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
private func initialize(_ machine: inout AmigaMachine, expansionVersion: UInt16) throws -> [UInt32] {
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

    let entry = try #require(machine.memory.hardDiskController.address(of: "initialize"))
    machine.cpu.statusRegister = 0x2700
    machine.cpu.supervisorStackPointer = 0x6FFC
    try machine.memory.writeLong(0x6000, at: 0x6FFC)
    machine.cpu.programCounter = entry
    machine.cpu[data: 0] = 0x4000 // the new device
    machine.cpu[data: 2] = 0xD2D2_D2D2
    for register in 2...4 { machine.cpu[address: register] = 0xA0A0_A0A0 + UInt32(register) }
    machine.cpu[address: 5] = log
    machine.cpu[address: 6] = exec
    for _ in 0..<1000 where machine.cpu.programCounter != 0x6000 { try machine.cpu.step(memory: &machine.memory) }
    #expect(machine.cpu.programCounter == 0x6000)
    #expect(machine.cpu.supervisorStackPointer == 0x7000)
    #expect(machine.cpu[data: 0] == 0x4000)
    #expect(machine.cpu[data: 2] == 0xD2D2_D2D2)
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
