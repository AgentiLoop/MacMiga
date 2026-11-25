import Testing
@testable import MacMigaCore

private func chipMemory(_ size: Int) throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024), chipRAMSize: size, slowRAMSize: 0)
    memory.setOverlay(enabled: false)
    return memory
}

/// Sets the D pointer and runs whatever blit `start` begins. Returns whether a blit ran.
private func blit(_ memory: inout AmigaMemory, to destination: UInt32, start: (inout AmigaMemory) throws -> Void) throws -> Bool {
    try memory.writeWord(0x8240, at: 0xDFF096) // DMAEN | BLTEN
    try memory.writeWord(0x0040, at: 0xDFF09C) // clear INTREQ BLIT
    try memory.writeLong(destination, at: 0xDFF054)
    try memory.writeWord(0, at: 0xDFF066)      // BLTDMOD
    try start(&memory)
    memory.advanceChipset(colorClocks: 1)
    return memory.custom.intreq & 0x0040 != 0
}

@Test func chipRAMSizeSelectsMirrorsAndAgnus() throws {
    var half = try chipMemory(512 * 1024)
    #expect(half.chipRAMSize == 0x8_0000 && half.custom.agnus == .ocs)
    try half.writeLong(0x1111_1111, at: 0x400)
    try half.writeLong(0x2222_2222, at: 0x8_0400)
    #expect(try half.readLong(at: 0x400) == 0x2222_2222)
    #expect(try half.readWord(at: 0xDF_F004) & 0x7F00 == 0)        // PAL 8371

    var one = try chipMemory(1024 * 1024)
    #expect(one.chipRAMSize == 0x10_0000 && one.custom.agnus == .ecs)
    try one.writeLong(0x1111_1111, at: 0x400)
    try one.writeLong(0x2222_2222, at: 0x8_0400)
    #expect(try one.readLong(at: 0x400) == 0x1111_1111)
    #expect(try one.readLong(at: 0x10_0400) == 0x1111_1111)
    #expect(try one.readLong(at: 0x18_0400) == 0x2222_2222)
    try one.writeWord(0xBEEF, at: 0x1F_FFFE)
    #expect(try one.readWord(at: 0x0F_FFFE) == 0xBEEF)
    #expect(try one.readWord(at: 0x07_FFFE) == 0)
    #expect(try one.readWord(at: 0xDF_F004) & 0x7F00 == 0x2000)    // PAL 8372A
    // The overlay hides only the first 512 KiB; a reset keeps the RAM and the Agnus.
    _ = try one.reset()
    #expect(one.overlayEnabled)
    #expect(try one.readLong(at: 0x400) == 0)                      // ROM
    #expect(try one.readLong(at: 0x8_0400) == 0x2222_2222)
    #expect(one.custom.agnus == .ecs)
    #expect(try one.readWord(at: 0xDF_F004) & 0x7F00 == 0x2000)

    var two = try chipMemory(2048 * 1024)
    #expect(two.chipRAMSize == 0x20_0000 && two.custom.agnus == .ecs)
    try two.writeLong(0x1111_1111, at: 0x400)
    try two.writeLong(0x3333_3333, at: 0x10_0400)
    try two.writeWord(0xBEEF, at: 0x1F_FFFE)
    #expect(try two.readLong(at: 0x400) == 0x1111_1111)
    #expect(try two.readLong(at: 0x10_0400) == 0x3333_3333)
    #expect(try two.readWord(at: 0x1F_FFFE) == 0xBEEF)
    #expect(try two.readWord(at: 0x0F_FFFE) == 0)
}

@Test func chipDMAReachesAllOfChipRAM() throws {
    for size in [512, 1024] {
        var memory = try chipMemory(size * 1024)
        // Blitter: copy two words from $90000 to $A0000.
        try memory.writeLong(0xCAFE_F00D, at: 0x9_0000)
        try memory.writeWord(0x09F0, at: 0xDFF040) // A -> D
        try memory.writeWord(0, at: 0xDFF042)
        try memory.writeLong(0xFFFF_FFFF, at: 0xDFF044)
        try memory.writeLong(0x9_0000, at: 0xDFF050)
        try memory.writeWord(0, at: 0xDFF064)
        let copied = try blit(&memory, to: 0xA_0000) { try $0.writeWord(1 << 6 | 2, at: 0xDFF058) }
        #expect(copied)
        #expect(try memory.readLong(at: 0xA_0000) == 0xCAFE_F00D)
        // With 512 KiB, $A0000 is $20000 again; with 1 MiB it is memory of its own.
        #expect(try memory.readLong(at: 0x2_0000) == (size == 512 ? 0xCAFE_F00D : 0))
        // Copper: a list at $98000 sets COLOR00.
        try memory.writeLong(0x0180_0F00, at: 0x9_8000)
        try memory.writeLong(0xFFFF_FFFE, at: 0x9_8004)
        try memory.writeLong(0x0180_00F0, at: 0x1_8000) // the same memory only with 512 KiB
        try memory.writeLong(0x9_8000, at: 0xDFF080)
        try memory.writeWord(0x8280, at: 0xDFF096)
        try memory.writeWord(0, at: 0xDFF088)
        memory.advanceChipset(colorClocks: 64)
        #expect(memory.custom.register(0x180) == (size == 512 ? 0x00F0 : 0x0F00))
    }
}

@Test func ecsAgnusBigBlitsAndMintermRegister() throws {
    var memory = try chipMemory(1024 * 1024)
    // BLTCON0L replaces the minterm byte only: D enabled, all ones.
    try memory.writeWord(0x0100, at: 0xDFF040)
    try memory.writeWord(0xAAFF, at: 0xDFF05A)
    #expect(memory.custom.register(0x040) == 0x01FF)
    try memory.writeWord(0, at: 0xDFF042)
    // 1100 lines of one word: more than BLTSIZE's 1024.
    let tall = try blit(&memory, to: 0x9_0000) {
        try $0.writeWord(1100, at: 0xDFF05C)
        guard !$0.custom.blitPending else { return } // BLTSIZV alone starts nothing
        try $0.writeWord(1, at: 0xDFF05E)
    }
    #expect(tall)
    #expect(try memory.readWord(at: 0x9_0000) == 0xFFFF)
    #expect(try memory.readWord(at: 0x9_0000 + 1099 * 2) == 0xFFFF)
    #expect(try memory.readWord(at: 0x9_0000 + 1100 * 2) == 0)
    #expect(memory.custom.blitterPointers[3] == 0x9_0000 + 1100 * 2)
    // 70 words wide: more than BLTSIZE's 64.
    let wide = try blit(&memory, to: 0xA_0000) {
        try $0.writeWord(2, at: 0xDFF05C)
        try $0.writeWord(70, at: 0xDFF05E)
    }
    #expect(wide)
    #expect(try memory.readWord(at: 0xA_0000 + 139 * 2) == 0xFFFF)
    #expect(try memory.readWord(at: 0xA_0000 + 140 * 2) == 0)
    // BLTSIZV keeps its value for the next BLTSIZH.
    let again = try blit(&memory, to: 0xB_0000) { try $0.writeWord(3, at: 0xDFF05E) }
    #expect(again)
    #expect(try memory.readWord(at: 0xB_0000 + 5 * 2) == 0xFFFF)
    #expect(try memory.readWord(at: 0xB_0000 + 6 * 2) == 0)
    // BLTSIZE works as before.
    let classic = try blit(&memory, to: 0xC_0000) { try $0.writeWord(3 << 6 | 1, at: 0xDFF058) }
    #expect(classic)
    #expect(try memory.readWord(at: 0xC_0000 + 2 * 2) == 0xFFFF)
    #expect(try memory.readWord(at: 0xC_0000 + 3 * 2) == 0)
}

@Test func ocsAgnusHasNoBigBlitRegisters() throws {
    var memory = try chipMemory(512 * 1024)
    try memory.writeWord(0x0100, at: 0xDFF040)
    try memory.writeWord(0x00FF, at: 0xDFF05A)
    #expect(memory.custom.register(0x040) == 0x0100)
    try memory.writeWord(0x01FF, at: 0xDFF040)
    try memory.writeWord(0, at: 0xDFF042)
    let big = try blit(&memory, to: 0x1_0000) {
        try $0.writeWord(4, at: 0xDFF05C)
        try $0.writeWord(1, at: 0xDFF05E)
    }
    #expect(!big)
    #expect(try memory.readWord(at: 0x1_0000) == 0)
    let classic = try blit(&memory, to: 0x1_0000) { try $0.writeWord(1 << 6 | 1, at: 0xDFF058) }
    #expect(classic)
    #expect(try memory.readWord(at: 0x1_0000) == 0xFFFF)
}
