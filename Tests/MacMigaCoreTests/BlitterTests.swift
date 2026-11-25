import Testing
@testable import MacMigaCore

private func blitterMemory() throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024), slowRAMSize: 0)
    memory.setOverlay(enabled: false)
    try memory.writeWord(0x8240, at: 0xDFF096) // DMAEN | BLTEN
    return memory
}

private func words(_ memory: inout AmigaMemory, at address: UInt32, count: Int) throws -> [UInt16] {
    try (0..<count).map { try memory.readWord(at: address + UInt32($0 * 2)) }
}

/// Writes the common blitter registers, then BLTSIZE, then lets the chipset run once.
private func blit(_ memory: inout AmigaMemory, con0: UInt16, con1: UInt16 = 0, a: UInt32 = 0, b: UInt32 = 0,
                  c: UInt32 = 0, d: UInt32 = 0, masks: (UInt16, UInt16) = (0xFFFF, 0xFFFF),
                  modulos: [UInt16] = [0, 0, 0, 0], size: UInt16) throws {
    try memory.writeWord(con0, at: 0xDFF040)
    try memory.writeWord(con1, at: 0xDFF042)
    try memory.writeWord(masks.0, at: 0xDFF044)
    try memory.writeWord(masks.1, at: 0xDFF046)
    for (index, pointer) in [c, b, a, d].enumerated() { try memory.writeLong(pointer, at: 0xDFF048 + UInt32(index * 4)) }
    for (index, modulo) in modulos.enumerated() { try memory.writeWord(modulo, at: 0xDFF060 + UInt32(index * 2)) } // C B A D
    try memory.writeWord(size, at: 0xDFF058)
    memory.advanceChipset(colorClocks: 1)
}

@Test func areaCopyShiftsAndMasksChannelA() throws {
    var memory = try blitterMemory()
    try memory.writeLong(0xFFFF_FFFF, at: 0x1000)
    try blit(&memory, con0: 0x49F0, a: 0x1000, d: 0x2000, masks: (0xFFFF, 0xFF00), size: 1 << 6 | 2)
    #expect(try words(&memory, at: 0x2000, count: 2) == [0x0FFF, 0xFFF0])
    #expect(memory.custom.blitterPointers[2] == 0x1004)
    #expect(memory.custom.blitterPointers[3] == 0x2004)
    #expect(memory.custom.intreq & 0x0040 != 0)
    #expect(try memory.readWord(at: 0xDFF002) & 0x6000 == 0) // not busy, not zero
}

@Test func mintermCombinesThreeSourcesAndModulosSkipWords() throws {
    var memory = try blitterMemory()
    for row in 0..<2 {
        let offset = UInt32(row * 4)
        try memory.writeWord(0xFF00, at: 0x1000 + offset)
        try memory.writeWord(0xF0F0, at: 0x1100 + offset)
        try memory.writeWord(0x0F0F, at: 0x1200 + offset)
    }
    // D = A·B + ¬A·C (cookie cut), one word per row, every source and D skipping one word.
    try blit(&memory, con0: 0x0FCA, a: 0x1000, b: 0x1100, c: 0x1200, d: 0x2000,
             modulos: [2, 2, 2, 2], size: 2 << 6 | 1)
    #expect(try words(&memory, at: 0x2000, count: 3) == [0xF00F, 0x0000, 0xF00F])
}

@Test func descendingFillInclusiveExclusiveAndCarryIn() throws {
    for (con1, expected) in [(UInt16(0x000A), UInt16(0x0FF0)), (0x0012, 0x07F0), (0x0016, 0xF80F)] {
        var memory = try blitterMemory()
        try memory.writeWord(0x0810, at: 0x1000)
        try blit(&memory, con0: 0x09F0, con1: con1, a: 0x1000, d: 0x2000, size: 1 << 6 | 1)
        #expect(try memory.readWord(at: 0x2000) == expected)
        #expect(memory.custom.blitterPointers[3] == 0x1FFE) // descending
    }
}

@Test func clearSetsBlitterZeroFlag() throws {
    var memory = try blitterMemory()
    try memory.writeLong(0xFFFF_FFFF, at: 0x2000)
    try blit(&memory, con0: 0x0100, d: 0x2000, size: 2 << 6 | 1)
    #expect(try memory.readLong(at: 0x2000) == 0)
    #expect(try memory.readWord(at: 0xDFF002) & 0x2000 != 0)
}

@Test func blitWaitsUntilBlitterDMAIsEnabled() throws {
    var memory = try blitterMemory()
    try memory.writeWord(0x0040, at: 0xDFF096) // BLTEN off
    try memory.writeWord(0x1234, at: 0x1000)
    try blit(&memory, con0: 0x09F0, a: 0x1000, d: 0x2000, size: 1 << 6 | 1)
    #expect(try memory.readWord(at: 0x2000) == 0)
    try memory.writeWord(0x8040, at: 0xDFF096)
    memory.advanceChipset(colorClocks: 1)
    #expect(try memory.readWord(at: 0x2000) == 0x1234)
}

@Test func lineModeDrawsBresenhamLine() throws {
    var memory = try blitterMemory()
    // Line (0,0)-(3,1) in a 40-byte-wide bitplane: dx = 3, dy = 1, X major (SUD), SIGN.
    try memory.writeWord(0x8000, at: 0xDFF074) // BLTADAT
    try memory.writeWord(0xFFFF, at: 0xDFF072) // BLTBDAT texture
    try blit(&memory, con0: 0x0BCA, con1: 0x0051, a: 0xFFFE, c: 0x3000, d: 0x3000,
             modulos: [40, 4, 0xFFF8, 40], size: 4 << 6 | 2)
    #expect(try memory.readWord(at: 0x3000) == 0xC000)
    #expect(try memory.readWord(at: 0x3028) == 0x3000)
    #expect(try memory.readWord(at: 0x3002) == 0)
}
