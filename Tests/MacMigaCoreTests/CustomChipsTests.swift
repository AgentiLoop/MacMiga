import Testing
@testable import MacMigaCore

private func customMemory() throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024))
    memory.setOverlay(enabled: false)
    return memory
}

@Test func setClearRegistersAndReadBack() throws {
    var memory = try customMemory()
    // Kickstart 1.3: MOVE.W #$7FFF to INTENA, INTREQ, DMACON clears everything.
    try memory.writeWord(0xC123, at: 0xDF_F09A)
    #expect(try memory.readWord(at: 0xDF_F01C) == 0x4123)
    try memory.writeWord(0x0003, at: 0xDF_F09A)
    #expect(try memory.readWord(at: 0xDF_F01C) == 0x4120)
    try memory.writeWord(0x7FFF, at: 0xDF_F09A)
    #expect(try memory.readWord(at: 0xDF_F01C) == 0)
    try memory.writeWord(0xFFFF, at: 0xDF_F09C)
    #expect(try memory.readWord(at: 0xDF_F01E) == 0x3FFF) // INTREQ bits 14 unused
    try memory.writeWord(0xFFFF, at: 0xDF_F096)
    #expect(try memory.readWord(at: 0xDF_F002) == 0x07FF) // BBUSY/BZERO not writable
    try memory.writeWord(0x8400, at: 0xDF_F09E)
    #expect(try memory.readWord(at: 0xDF_F010) == 0x0400)
}

@Test func wordWritesAreNotSplitAndRegistersMirror() throws {
    var memory = try customMemory()
    try memory.writeWord(0x0200, at: 0xDF_F100) // BPLCON0
    #expect(memory.custom.written[0x100 >> 1] == 0x0200)
    try memory.writeLong(0x0444_0555, at: 0xDF_F180) // COLOR00, COLOR01
    #expect(memory.custom.written[0x180 >> 1] == 0x0444)
    #expect(memory.custom.written[0x182 >> 1] == 0x0555)
    try memory.writeWord(0x8001, at: 0xDF_F29A) // $DFF29A mirrors INTENA
    #expect(memory.custom.intena == 0x0001)
    // A byte write puts the byte on both halves of the data bus.
    try memory.writeByte(0x12, at: 0xDF_F181)
    #expect(memory.custom.written[0x180 >> 1] == 0x1212)
}

@Test func interruptLevelFollowsPaulaPriorities() {
    var chips = CustomChips()
    chips.requestInterrupt(bits: 0x0020) // VERTB
    #expect(chips.interruptLevel == 0)
    chips.writeWord(offset: 0x9A, value: 0x8020)
    #expect(chips.interruptLevel == 0) // master INTEN still clear
    chips.writeWord(offset: 0x9A, value: 0xC000)
    #expect(chips.interruptLevel == 3)
    chips.writeWord(offset: 0x9A, value: 0x8008) // PORTS
    chips.requestInterrupt(bits: 0x0008)
    #expect(chips.interruptLevel == 3)
    chips.writeWord(offset: 0x9C, value: 0x0020)
    #expect(chips.interruptLevel == 2)
    chips.writeWord(offset: 0x9A, value: 0xA000) // EXTER
    chips.requestInterrupt(bits: 0x2000)
    #expect(chips.interruptLevel == 6)
}

@Test func beamCounterWrapsAndRaisesVerticalBlank() throws {
    var memory = try customMemory()
    let first = memory.custom.advance(colorClocks: 227 * 2 + 5)
    #expect(first.lines == 2 && first.frames == 0)
    #expect(try memory.readWord(at: 0xDF_F006) == 0x0205)
    memory.custom.advance(colorClocks: 227 * 254)
    #expect(try memory.readWord(at: 0xDF_F004) & 1 == 1) // V8 set on line 256
    #expect(try memory.readWord(at: 0xDF_F006) == 0x0005)
    let wrap = memory.custom.advance(colorClocks: 227 * 56)
    #expect(wrap.frames == 1)
    #expect(memory.custom.verticalPosition == 0)
    #expect(memory.custom.intreq & 0x0020 != 0)
}

@Test func emptyA500IORangeReadsZeroForGayleProbe() throws {
    var memory = try customMemory()
    try memory.writeByte(0x00, at: 0xDA_8000) // Kickstart 3.1 Gayle probe
    #expect(try memory.readByte(at: 0xDA_8000) == 0)
    #expect(try memory.readWord(at: 0xDE_1000) == 0)
    #expect(try memory.readLong(at: 0xD8_0000) == 0)
    #expect(throws: MemoryBusError.unmappedAddress(0xE0_0000)) { try memory.readByte(at: 0xE0_0000) }
}
