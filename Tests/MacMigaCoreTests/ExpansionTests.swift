import Testing
@testable import MacMigaCore

private func rom() -> [UInt8] {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom.replaceSubrange(0..<8, with: [0x00, 0x00, 0x80, 0x00, 0x00, 0xFC, 0x00, 0xD2])
    return rom
}

/// A 4-cylinder image whose byte at offset n is a function of n.
private func disk(writeProtected: Bool = false) throws -> HardDisk {
    let image = (0..<4 * HardDisk.cylinderSize).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) }
    return try HardDisk(image: image, writeProtected: writeProtected)
}

/// Reads logical byte `offset` of the board answering at `$E80000` the way expansion.library does.
private func identification(_ memory: inout AmigaMemory, _ offset: UInt32) throws -> UInt8 {
    let value = try memory.readByte(at: 0xE8_0000 + offset) & 0xF0 | memory.readByte(at: 0xE8_0002 + offset) >> 4
    return offset == 0 ? value : ~value
}

private func configure(_ memory: inout AmigaMemory, at page: UInt8) throws {
    try memory.writeByte(page << 4, at: 0xE8_004A)
    try memory.writeByte(page, at: 0xE8_0048)
}

/// A machine with the hard-disk board configured at `$E90000` and the overlay off.
private func hardDiskMachine(_ disk: HardDisk) throws -> AmigaMachine {
    var machine = try AmigaMachine(kickstart: rom(), slowRAMSize: 0, hardDisk: disk)
    machine.memory.setOverlay(enabled: false)
    try configure(&machine.memory, at: 0xE9)
    return machine
}

/// Stores an IORequest at `$1000` and hands it to the controller's request register.
private func request(_ memory: inout AmigaMemory, command: UInt16, offset: UInt32 = 0, length: UInt32 = 0,
                     data: UInt32 = 0x2000, flags: UInt8 = 1) throws -> (error: UInt8, actual: UInt32) {
    try memory.writeWord(command, at: 0x1000 + 28)
    try memory.writeByte(flags, at: 0x1000 + 30)
    try memory.writeByte(0x7F, at: 0x1000 + 31)
    try memory.writeLong(0xDEAD_BEEF, at: 0x1000 + 32)
    try memory.writeLong(length, at: 0x1000 + 36)
    try memory.writeLong(data, at: 0x1000 + 40)
    try memory.writeLong(offset, at: 0x1000 + 44)
    try memory.writeLong(0x1000, at: 0xE9_8000)
    return (try memory.readByte(at: 0x1000 + 31), try memory.readLong(at: 0x1000 + 32))
}

/// Calls the subroutine at `address` and runs until it returns.
private func call(_ machine: inout AmigaMachine, _ address: UInt32) throws {
    machine.cpu.statusRegister = 0x2700
    machine.cpu.supervisorStackPointer = 0x6FFC
    try machine.memory.writeLong(0x6000, at: 0x6FFC)
    machine.cpu.programCounter = address
    for _ in 0..<100 where machine.cpu.programCounter != 0x6000 { try machine.cpu.step(memory: &machine.memory) }
    #expect(machine.cpu.programCounter == 0x6000)
    #expect(machine.cpu.supervisorStackPointer == 0x7000)
}

@Test func autoconfigChainConfiguresFastRAMThenTheHardDiskBoard() throws {
    var memory = try AmigaMemory(kickstart: rom(), fastRAMSize: 8 << 20, hardDisk: disk())
    memory.setOverlay(enabled: false)
    // Board 1: Zorro II memory board, 8 MiB (size code 0), linked into the memory list.
    #expect(try identification(&memory, 0x00) == 0xE0)
    #expect(try identification(&memory, 0x04) == ExpansionBus.fastRAMProduct)
    #expect(try identification(&memory, 0x08) == 0x80)
    #expect(try UInt16(identification(&memory, 0x10)) << 8 | UInt16(identification(&memory, 0x14)) == 2011)
    #expect(throws: MemoryBusError.unmappedAddress(0x20_0000)) { try memory.readByte(at: 0x20_0000) }
    try configure(&memory, at: 0x20)
    try memory.writeLong(0x1234_5678, at: 0x20_0000)
    try memory.writeLong(0x9ABC_DEF0, at: 0x9F_FFFC)
    #expect(try memory.readLong(at: 0x20_0000) == 0x1234_5678)
    #expect(try memory.readLong(at: 0x9F_FFFC) == 0x9ABC_DEF0)
    // Board 2: 64 KiB Zorro II board with a DiagArea at $0100.
    #expect(try identification(&memory, 0x00) == 0xD1)
    #expect(try identification(&memory, 0x04) == ExpansionBus.hardDiskProduct)
    #expect(try identification(&memory, 0x08) == 0x40)
    #expect(try UInt16(identification(&memory, 0x28)) << 8 | UInt16(identification(&memory, 0x2C)) == 0x0100)
    try configure(&memory, at: 0xE9)
    #expect(memory.expansion.boards.map(\.base) == [0x20_0000, 0xE9_0000])
    #expect(try memory.readWord(at: 0xE9_0100) == 0x9000) // DAC_WORDWIDE | DAC_CONFIGTIME
    // The chain is exhausted: the window is empty again.
    #expect(try memory.readLong(at: 0xE8_0000) == 0)
    try memory.writeByte(0x30, at: 0xE8_0048)
    #expect(memory.expansion.boards.map(\.base) == [0x20_0000, 0xE9_0000])
}

@Test func smallerFastRAMBoardReportsItsSizeCode() throws {
    var memory = try AmigaMemory(kickstart: rom(), fastRAMSize: 1 << 20)
    #expect(try identification(&memory, 0x00) == 0xE5) // 1 MiB
    try configure(&memory, at: 0x40)
    try memory.writeByte(0x5A, at: 0x4F_FFFF)
    #expect(try memory.readByte(at: 0x4F_FFFF) == 0x5A)
    #expect(throws: MemoryBusError.unmappedAddress(0x50_0000)) { try memory.readByte(at: 0x50_0000) }
}

@Test func shutUpSkipsABoardAndResetUnconfiguresTheChain() throws {
    var memory = try AmigaMemory(kickstart: rom(), fastRAMSize: 1 << 20, hardDisk: disk())
    try memory.writeByte(0, at: 0xE8_004C) // shut up the RAM board
    #expect(try identification(&memory, 0x00) == 0xD1)
    try configure(&memory, at: 0xE9)
    #expect(memory.expansion.boards.map(\.base) == [nil, 0xE9_0000])
    #expect(try memory.readLong(at: 0xE8_0000) == 0)
    memory.setOverlay(enabled: false)
    try memory.writeLong(0xCAFE_F00D, at: 0x100)
    _ = try memory.reset()
    #expect(try identification(&memory, 0x00) == 0xE5)
    #expect(try memory.readByte(at: 0xE9_0100) == 0) // the hard-disk board is unmapped again
    try configure(&memory, at: 0x20)
    #expect(try identification(&memory, 0x00) == 0xD1)
}

@Test func hardDiskImageValidationAndGeometry() throws {
    #expect(throws: HardDiskError.invalidImageSize(1000)) { try HardDisk(image: [UInt8](repeating: 0, count: 1000)) }
    #expect(throws: HardDiskError.invalidImageSize(8192)) { try HardDisk(image: [UInt8](repeating: 0, count: 8192)) }
    var image = [UInt8](repeating: 0, count: 3 * HardDisk.cylinderSize + 512)
    image.replaceSubrange(0..<4, with: Array("RDSK".utf8))
    #expect(throws: HardDiskError.invalidPartitionTable(block: 0)) { try HardDisk(image: image) } // no checksum
    image.replaceSubrange(0..<4, with: [0x44, 0x4F, 0x53, 0x00])
    let ofs = try HardDisk(image: image)
    #expect(ofs.cylinders == 3)
    #expect(ofs.capacity == 3 * 16384)
    #expect(!ofs.isPartitioned)
    #expect(ofs.partitions.map(\.name) == ["DH0"])
    #expect(ofs.partitions[0].dosType == 0x444F_5300)
    #expect(ofs.partitions[0].firstBlock == 0 && ofs.partitions[0].blockCount == 96)
    #expect(try disk().partitions[0].dosType == 0x444F_5301) // no signature: mounted as FFS
}

@Test func hardDiskRequestsReadWriteAndReportErrors() throws {
    let disk = try disk()
    var machine = try hardDiskMachine(disk)
    // CMD_READ of two blocks from block 3.
    var result = try request(&machine.memory, command: 2, offset: 3 * 512, length: 1024)
    #expect(result.error == 0 && result.actual == 1024)
    for index in [0, 1, 511, 512, 1023] {
        #expect(try machine.memory.readByte(at: 0x2000 + UInt32(index)) == disk.bytes[3 * 512 + index])
    }
    #expect(try machine.memory.readLong(at: 0xE9_8000) == 0) // finished, not pending
    #expect(disk.blocksRead == 2)
    // CMD_WRITE of one block to block 5.
    for index in 0..<512 { try machine.memory.writeByte(UInt8(truncatingIfNeeded: index ^ 0xA5), at: 0x3000 + UInt32(index)) }
    result = try request(&machine.memory, command: 3, offset: 5 * 512, length: 512, data: 0x3000)
    #expect(result.error == 0 && result.actual == 512)
    #expect(disk.bytes[5 * 512 + 7] == 7 ^ 0xA5)
    #expect(disk.bytes[5 * 512 + 511] == UInt8(truncatingIfNeeded: 511 ^ 0xA5))
    #expect(disk.takeModifiedBlocks() == [5])
    #expect(disk.takeModifiedBlocks().isEmpty)
    // TD_FORMAT writes too.
    result = try request(&machine.memory, command: 11, offset: 0, length: 1024, data: 0x3000)
    #expect(result.error == 0 && disk.takeModifiedBlocks() == [0, 1])
    // Past the end of the disk: IOERR_BADLENGTH, nothing transferred.
    result = try request(&machine.memory, command: 2, offset: UInt32(disk.capacity) - 512, length: 1024)
    #expect(result.error == 0xFC && result.actual == 0)
    // Status commands.
    #expect(try request(&machine.memory, command: 14) == (0, 0)) // TD_CHANGESTATE: disk present
    #expect(try request(&machine.memory, command: 15) == (0, 0)) // TD_PROTSTATUS: writable
    #expect(try request(&machine.memory, command: 9, length: 1) == (0, 0)) // TD_MOTOR
    #expect(try request(&machine.memory, command: 19) == (0, 4)) // TD_GETNUMTRACKS
    result = try request(&machine.memory, command: 22, data: 0x4000) // TD_GETGEOMETRY
    #expect(result.error == 0)
    #expect(try machine.memory.readLong(at: 0x4000) == 512)
    #expect(try machine.memory.readLong(at: 0x4004) == 128) // total blocks
    #expect(try machine.memory.readLong(at: 0x4008) == 4)   // cylinders
    // Unknown command (HD_SCSICMD): IOERR_NOCMD.
    #expect(try request(&machine.memory, command: 28).error == 0xFD)
    // TD_ADDCHANGEINT stays with the device: not quick, no result written.
    result = try request(&machine.memory, command: 20)
    #expect(result.error == 0x7F && result.actual == 0xDEAD_BEEF)
    #expect(try machine.memory.readByte(at: 0x1000 + 30) == 0)
    #expect(try machine.memory.readLong(at: 0xE9_8000) == 1)
    #expect(try request(&machine.memory, command: 21) == (0, 0)) // TD_REMCHANGEINT
    #expect(try machine.memory.readLong(at: 0xE9_8000) == 0)
}

@Test func writeProtectedHardDiskRefusesWrites() throws {
    let disk = try disk(writeProtected: true)
    var machine = try hardDiskMachine(disk)
    let before = disk.bytes
    let result = try request(&machine.memory, command: 3, offset: 0, length: 512)
    #expect(result.error == 28 && result.actual == 0) // TDERR_WriteProt
    #expect(disk.bytes == before)
    #expect(try request(&machine.memory, command: 15) == (0, 1))
}

@Test func bootROMDescribesTheDiskAndFixesUpItsResidentTag() throws {
    let disk = try disk()
    var machine = try hardDiskMachine(disk)
    let controller = machine.memory.hardDiskController
    // MakeDosNode packet: DH0 on macmiga.device unit 0, then the environment.
    let packet = try #require(controller.address(of: "parameters0"))
    func string(at address: UInt32) throws -> String {
        var bytes = [UInt8](), address = address
        while let byte = try? machine.memory.readByte(at: address), byte != 0 { bytes.append(byte); address += 1 }
        return String(decoding: bytes, as: UTF8.self)
    }
    #expect(try string(at: machine.memory.readLong(at: packet)) == "DH0")
    #expect(try string(at: machine.memory.readLong(at: packet + 4)) == "macmiga.device")
    let environment = try (0..<17).map { try machine.memory.readLong(at: packet + 16 + UInt32($0 * 4)) }
    #expect(environment == [16, 128, 0, 1, 1, 32, 2, 0, 0, 0, 3, 30, 1, 0x7FFF_FFFF, 0x7FFF_FFFE, 0, 0x444F_5301])

    // Copy the DiagArea to RAM as expansion.library does, then run its DiagPoint.
    let size = UInt32(try machine.memory.readWord(at: 0xE9_0102))
    for offset in 0..<size { try machine.memory.writeByte(try machine.memory.readByte(at: 0xE9_0100 + offset), at: 0x3000 + offset) }
    machine.cpu[address: 2] = 0x3000
    try call(&machine, 0x3000 + UInt32(try machine.memory.readWord(at: 0x3004)))
    #expect(machine.cpu[data: 0] == 1)
    let tag: UInt32 = 0x3000 + 14
    #expect(try machine.memory.readWord(at: tag) == 0x4AFC)
    #expect(try machine.memory.readLong(at: tag + 2) == tag)
    #expect(try machine.memory.readLong(at: tag + 6) == 0x3000 + size)
    #expect(try machine.memory.readByte(at: tag + 10) == 0x81) // RTF_AUTOINIT | RTF_COLDSTART
    #expect(try machine.memory.readByte(at: tag + 12) == 3)    // NT_DEVICE
    #expect(try string(at: machine.memory.readLong(at: tag + 14)) == "macmiga.device")

    // The device register names the new device node.
    try machine.memory.writeLong(0x4000, at: 0xE9_8008)
    #expect(try machine.memory.readByte(at: 0x4008) == 3)
    #expect(try string(at: machine.memory.readLong(at: 0x400A)) == "macmiga.device")
    #expect(try machine.memory.readWord(at: 0x4014) == 1)
}

@Test func deviceVectorsRunOnTheCPU() throws {
    let disk = try disk()
    var machine = try hardDiskMachine(disk)
    let controller = machine.memory.hardDiskController
    let open = try #require(controller.address(of: "open"))
    let close = try #require(controller.address(of: "close"))
    let beginIO = try #require(controller.address(of: "beginIO"))
    // Open unit 0, then a unit that does not exist.
    machine.cpu[address: 6] = 0x4000
    machine.cpu[address: 1] = 0x1000
    machine.cpu[data: 0] = 0
    try machine.memory.writeByte(0x55, at: 0x1000 + 31)
    try call(&machine, open)
    #expect(try machine.memory.readWord(at: 0x4020) == 1)       // lib_OpenCnt
    #expect(try machine.memory.readLong(at: 0x1018) == 0x4000)  // io_Unit
    #expect(try machine.memory.readByte(at: 0x1000 + 31) == 0)
    machine.cpu[data: 0] = 1
    try call(&machine, open)
    #expect(try machine.memory.readByte(at: 0x1000 + 31) == 0xFF) // IOERR_OPENFAIL
    #expect(try machine.memory.readWord(at: 0x4020) == 1)
    try call(&machine, close)
    #expect(try machine.memory.readWord(at: 0x4020) == 0)

    // A fake exec whose ReplyMsg (LVO -378) counts calls in D7.
    try machine.memory.writeLong(0x5000, at: 4)
    try machine.memory.writeWord(0x5287, at: 0x5000 - 378) // addq.l #1,d7
    try machine.memory.writeWord(0x4E75, at: 0x5000 - 376) // rts
    func begin(command: UInt16, flags: UInt8) throws {
        try machine.memory.writeWord(command, at: 0x1000 + 28)
        try machine.memory.writeByte(flags, at: 0x1000 + 30)
        try machine.memory.writeLong(512, at: 0x1000 + 36)
        try machine.memory.writeLong(0x2000, at: 0x1000 + 40)
        try machine.memory.writeLong(512, at: 0x1000 + 44)
        machine.cpu[address: 1] = 0x1000
        machine.cpu[address: 6] = 0x4000
        try call(&machine, beginIO)
        #expect(machine.cpu[address: 6] == 0x4000)
    }
    machine.cpu[data: 7] = 0
    try begin(command: 2, flags: 1) // quick read: done in place, no reply
    #expect(machine.cpu[data: 7] == 0)
    #expect(try machine.memory.readByte(at: 0x2000) == disk.bytes[512])
    #expect(try machine.memory.readLong(at: 0x1000 + 32) == 512)
    try begin(command: 2, flags: 0) // queued read: replied
    #expect(machine.cpu[data: 7] == 1)
    try begin(command: 20, flags: 0) // TD_ADDCHANGEINT: kept, no reply
    #expect(machine.cpu[data: 7] == 1)
}
