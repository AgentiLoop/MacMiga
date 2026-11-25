import Testing
@testable import MacMigaCore

private func syntheticROM(size: Int = 256 * 1024) -> [UInt8] {
    var rom = [UInt8](repeating: 0, count: size)
    rom.replaceSubrange(0..<8, with: [0x00, 0x08, 0x00, 0x00, 0x00, 0xFC, 0x00, 0xD2])
    rom[rom.count - 1] = 0xA5
    return rom
}

@Test func rejectsUnsupportedROMSizes() {
    for size in [0, 8, 256 * 1024 - 1, 256 * 1024 + 1, 1024 * 1024] {
        #expect(throws: MemoryBusError.invalidROMSize(size)) {
            try AmigaMemory(kickstart: [UInt8](repeating: 0, count: size))
        }
    }
}

@Test func resetFetchesBigEndianVectorsAndRestoresOverlay() throws {
    var memory = try AmigaMemory(kickstart: syntheticROM())
    #expect(memory.overlayEnabled)
    memory.setOverlay(enabled: false)
    try memory.writeLong(0xDEAD_BEEF, at: 0)
    let vectors = try memory.reset()
    #expect(vectors.supervisorStackPointer == 0x0008_0000)
    #expect(vectors.programCounter == 0x00FC_00D2)
    #expect(memory.overlayEnabled)
    memory.setOverlay(enabled: false)
    #expect(try memory.readLong(at: 0) == 0xDEAD_BEEF)
}

@Test func mirrors256KiBROMInBothWindows() throws {
    let memory = try AmigaMemory(kickstart: syntheticROM())
    #expect(try memory.readLong(at: 4) == 0x00FC_00D2)
    #expect(try memory.readLong(at: 0x04_0004) == 0x00FC_00D2)
    #expect(try memory.readLong(at: 0xF8_0004) == 0x00FC_00D2)
    #expect(try memory.readLong(at: 0xFC_0004) == 0x00FC_00D2)
    #expect(try memory.readByte(at: 0xFF_FFFF) == 0xA5)
}

@Test func preservesDistinctHalvesOf512KiBROM() throws {
    var rom = syntheticROM(size: 512 * 1024)
    rom[0x04_0000] = 0x7E
    let memory = try AmigaMemory(kickstart: rom)
    #expect(try memory.readByte(at: 0xF8_0000) == 0)
    #expect(try memory.readByte(at: 0xFC_0000) == 0x7E)
    #expect(try memory.readByte(at: 0x04_0000) == 0x7E)
    #expect(try memory.readByte(at: 0x07_FFFF) == 0xA5)
}

@Test func ignoresWritesToROMAndOverlaidRAM() throws {
    var memory = try AmigaMemory(kickstart: syntheticROM())
    try memory.writeLong(0xFFFF_FFFF, at: 0)
    try memory.writeLong(0xFFFF_FFFF, at: 0xFC_0000)
    #expect(try memory.readLong(at: 0) == 0x0008_0000)
    #expect(try memory.readLong(at: 0xFC_0000) == 0x0008_0000)
    memory.setOverlay(enabled: false)
    #expect(try memory.readLong(at: 0) == 0)
}

@Test func readsAndWritesBigEndianRAMAtBoundaries() throws {
    var memory = try AmigaMemory(kickstart: syntheticROM())
    memory.setOverlay(enabled: false)
    try memory.writeLong(0x1234_ABCD, at: 0)
    #expect(try memory.readByte(at: 0) == 0x12)
    #expect(try memory.readByte(at: 1) == 0x34)
    #expect(try memory.readWord(at: 2) == 0xABCD)
    #expect(try memory.readLong(at: 0) == 0x1234_ABCD)
    try memory.writeWord(0x9876, at: 0x07_FFFE)
    #expect(try memory.readByte(at: 0x07_FFFF) == 0x76)
    // Longwords need only word alignment on the 68000.
    try memory.writeLong(0x8765_4321, at: 6)
    #expect(try memory.readLong(at: 6) == 0x8765_4321)
}

@Test func masksAddressesTo24BitsIncludingWrites() throws {
    var memory = try AmigaMemory(kickstart: syntheticROM())
    #expect(try memory.readLong(at: 0xABFC_0004) == 0x00FC_00D2)
    memory.setOverlay(enabled: false)
    try memory.writeWord(0xCAFE, at: 0xFF00_0002)
    #expect(try memory.readWord(at: 2) == 0xCAFE)
}

@Test func wrapsLongwordAcrossPhysicalAddressLimit() throws {
    var rom = syntheticROM()
    rom[rom.count - 2] = 0x12
    rom[rom.count - 1] = 0x34
    var memory = try AmigaMemory(kickstart: rom)
    memory.setOverlay(enabled: false)
    try memory.writeWord(0x5678, at: 0)
    #expect(try memory.readLong(at: 0xFFFF_FFFE) == 0x1234_5678)
    try memory.writeLong(0xDEAD_BEEF, at: 0xFFFF_FFFE)
    #expect(try memory.readWord(at: 0xFF_FFFE) == 0x1234)
    #expect(try memory.readWord(at: 0) == 0xBEEF)
}

@Test func rejectsOddWordAndLongwordAccessWithoutMutation() throws {
    var memory = try AmigaMemory(kickstart: syntheticROM())
    memory.setOverlay(enabled: false)
    #expect(throws: MemoryBusError.unalignedAddress(1)) { try memory.readWord(at: 1) }
    #expect(throws: MemoryBusError.unalignedAddress(3)) { try memory.readLong(at: 3) }
    #expect(throws: MemoryBusError.unalignedAddress(1)) { try memory.writeWord(0xFFFF, at: 1) }
    #expect(throws: MemoryBusError.unalignedAddress(3)) { try memory.writeLong(0xFFFF_FFFF, at: 3) }
    #expect(try memory.readLong(at: 0) == 0)
    #expect(try memory.readLong(at: 4) == 0)
    try memory.writeByte(0xA5, at: 1)
    #expect(try memory.readByte(at: 1) == 0xA5)
}

@Test func reportsUnimplementedRegionsRatherThanInventingDeviceData() throws {
    var memory = try AmigaMemory(kickstart: syntheticROM())
    memory.setOverlay(enabled: false)
    for address: UInt32 in [0x08_0000, 0xBF_E001, 0xDF_F000, 0xEF_FFFF] {
        #expect(throws: MemoryBusError.unmappedAddress(address)) { try memory.readByte(at: address) }
        #expect(throws: MemoryBusError.unmappedAddress(address)) { try memory.writeByte(0xFF, at: address) }
    }
    #expect(throws: MemoryBusError.unmappedAddress(0x08_0000)) {
        try memory.readLong(at: 0x07_FFFE)
    }
}

@Test func emptyDiagnosticSlotReadsZeroAndIgnoresWrites() throws {
    var memory = try AmigaMemory(kickstart: syntheticROM())
    for address: UInt32 in [0xF0_0000, 0xF0_0002, 0xF4_1234, 0xF7_FFFC, 0xFFF0_0000] {
        try memory.writeLong(0x1111_1111, at: address)
        #expect(try memory.readLong(at: address) == 0)
    }
    #expect(try memory.readByte(at: 0xF7_FFFF) == 0)
    // The slot ends where the Kickstart window starts.
    #expect(try memory.readWord(at: 0xF8_0000) == UInt16(syntheticROM()[0]) << 8 | UInt16(syntheticROM()[1]))
}
