import Testing
@testable import MacMigaCore

private func videoMemory() throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024), slowRAMSize: 0)
    memory.setOverlay(enabled: false)
    return memory
}

private func store(_ words: [UInt16], at address: UInt32, in memory: inout AmigaMemory) throws {
    for (offset, word) in words.enumerated() { try memory.writeWord(word, at: address + UInt32(offset * 2)) }
}

private func pixel(_ memory: AmigaMemory, row: Int, column: Int) -> UInt32 {
    memory.video.pixels[row * Video.width + column]
}

private let frame = CustomChips.colorClocksPerLine * CustomChips.linesPerFrame
private let red: UInt32 = 0xFFFF_0000, green: UInt32 = 0xFF00_FF00, white: UInt32 = 0xFFFF_FFFF, black: UInt32 = 0xFF00_0000

@Test func copperMovesWaitsAndRestartsEachFrame() throws {
    var memory = try videoMemory()
    // MOVE #$F00,COLOR00; WAIT line $40; MOVE #$0F0,COLOR00; WAIT $FFFF,$FFFE (end)
    try store([0x0180, 0x0F00, 0x4001, 0xFFFE, 0x0180, 0x00F0, 0xFFFF, 0xFFFE], at: 0x1000, in: &memory)
    try memory.writeLong(0x1000, at: 0xDFF080)   // COP1LC
    try memory.writeWord(0x8280, at: 0xDFF096)   // DMAEN | COPEN
    try memory.writeWord(0, at: 0xDFF088)        // COPJMP1
    memory.advanceChipset(colorClocks: frame * 2 - 10)
    #expect(memory.video.frameCount == 1)
    #expect(pixel(memory, row: 0x30, column: 0) == red)
    #expect(pixel(memory, row: 0x3F, column: 0) == red)
    #expect(pixel(memory, row: 0x40, column: 0) == green)
    #expect(pixel(memory, row: 0x100, column: 0) == green)
    #expect(memory.copper.state == .waiting(position: 0xFFFE, mask: 0xFFFE))
}

@Test func copperHaltsOnProtectedRegistersUnlessDangerBitAllowsThem() throws {
    for danger in [false, true] {
        var memory = try videoMemory()
        try store([0x0040, 0x09F0, 0x0180, 0x0F00, 0xFFFF, 0xFFFE], at: 0x1000, in: &memory) // BLTCON0
        try memory.writeLong(0x1000, at: 0xDFF080)
        try memory.writeWord(danger ? 0x0002 : 0, at: 0xDFF02E)   // COPCON CDANG
        try memory.writeWord(0x8280, at: 0xDFF096)
        try memory.writeWord(0, at: 0xDFF088)
        memory.advanceChipset(colorClocks: 20)
        #expect(memory.custom.register(0x040) == (danger ? 0x09F0 : 0))
        #expect(memory.custom.register(0x180) == (danger ? 0x0F00 : 0))
        #expect((memory.copper.state == .halted) == !danger)
    }
}

@Test func copperSkipJumpsOverNextInstructionOncePositionReached() throws {
    var memory = try videoMemory()
    // SKIP line 0 (always reached), MOVE red (skipped), MOVE green, end
    try store([0x0001, 0xFFFF, 0x0180, 0x0F00, 0x0180, 0x00F0, 0xFFFF, 0xFFFE], at: 0x1000, in: &memory)
    try memory.writeLong(0x1000, at: 0xDFF080)
    try memory.writeWord(0x8280, at: 0xDFF096)
    try memory.writeWord(0, at: 0xDFF088)
    memory.advanceChipset(colorClocks: 40)
    #expect(memory.custom.register(0x180) == 0x00F0)
}

private func setUpPlayfield(_ memory: inout AmigaMemory, hires: Bool) throws {
    try memory.writeWord(0x2C81, at: 0xDFF08E)                    // DIWSTRT
    try memory.writeWord(0x2CC1, at: 0xDFF090)                    // DIWSTOP (line $12C)
    try memory.writeWord(hires ? 0x3C : 0x38, at: 0xDFF092)       // DDFSTRT
    try memory.writeWord(hires ? 0xD4 : 0xD0, at: 0xDFF094)       // DDFSTOP
    try memory.writeWord(hires ? 0x9200 : 0x1200, at: 0xDFF100)   // one bitplane
    try memory.writeWord(0x0000, at: 0xDFF180)
    try memory.writeWord(0x0FFF, at: 0xDFF182)
    try memory.writeLong(0x2000, at: 0xDFF0E0)                    // BPL1PT
    try memory.writeWord(0x8300, at: 0xDFF096)                    // DMAEN | BPLEN
}

@Test func lowresBitplaneIsPlacedInDisplayWindowAndAdvancesPointer() throws {
    var memory = try videoMemory()
    try setUpPlayfield(&memory, hires: false)
    try store([0x8001], at: 0x2000, in: &memory)
    memory.advanceChipset(colorClocks: CustomChips.colorClocksPerLine * 0x2D)
    let first = (0x81 - Video.firstLowresColumn) * 2
    #expect(pixel(memory, row: 0x2B, column: first) == black)
    #expect(pixel(memory, row: 0x2C, column: first - 1) == black)
    #expect(pixel(memory, row: 0x2C, column: first) == white)
    #expect(pixel(memory, row: 0x2C, column: first + 1) == white)
    #expect(pixel(memory, row: 0x2C, column: first + 2) == black)
    #expect(pixel(memory, row: 0x2C, column: first + 30) == white)
    #expect(pixel(memory, row: 0x2C, column: first + 32) == black)
    #expect(memory.custom.bitplanePointers[0] == 0x2000 + 40)
}

@Test func hiresBitplaneUsesHalfWidthPixelsAndModulo() throws {
    var memory = try videoMemory()
    try setUpPlayfield(&memory, hires: true)
    try memory.writeWord(0xFFF0, at: 0xDFF108) // BPL1MOD -16
    try store([0xC000], at: 0x2000, in: &memory)
    memory.advanceChipset(colorClocks: CustomChips.colorClocksPerLine * 0x2D)
    let first = (0x81 - Video.firstLowresColumn) * 2
    #expect(pixel(memory, row: 0x2C, column: first) == white)
    #expect(pixel(memory, row: 0x2C, column: first + 1) == white)
    #expect(pixel(memory, row: 0x2C, column: first + 2) == black)
    #expect(memory.custom.bitplanePointers[0] == 0x2000 + 80 - 16)
}

@Test func holdAndModifyColours() throws {
    var memory = try videoMemory()
    try setUpPlayfield(&memory, hires: false)
    try memory.writeWord(0x6A00, at: 0xDFF100) // 6 planes, HAM
    try memory.writeWord(0x0123, at: 0xDFF182) // COLOR01
    for plane in 0..<6 { try memory.writeLong(0x2000 + UInt32(plane) * 0x100, at: 0xDFF0E0 + UInt32(plane) * 4) }
    // Pixel 0: palette 1 (plane 1); pixel 1: modify red to 15 (planes 6 = %10 control, data 15).
    // Pixel 2: modify blue to 5 (control %01 = plane 5; data planes 1 and 3).
    try store([0xE000], at: 0x2000, in: &memory)          // plane 1: pixels 0,1,2
    try store([0x4000], at: 0x2100, in: &memory)
    try store([0x6000], at: 0x2200, in: &memory)          // plane 3: pixels 1,2
    try store([0x4000], at: 0x2300, in: &memory)
    try store([0x2000], at: 0x2400, in: &memory)          // plane 5: pixel 2
    try store([0x4000], at: 0x2500, in: &memory)          // plane 6: pixel 1
    memory.advanceChipset(colorClocks: CustomChips.colorClocksPerLine * 0x2D)
    let first = (0x81 - Video.firstLowresColumn) * 2
    #expect(pixel(memory, row: 0x2C, column: first) == Video.argb(0x123))
    #expect(pixel(memory, row: 0x2C, column: first + 2) == Video.argb(0xF23))
    #expect(pixel(memory, row: 0x2C, column: first + 4) == Video.argb(0xF25)) // red held
}

@Test func copperColourChangeMidLineSplitsTheLine() throws {
    // Kickstart 3.1 pattern: set COLOR00 at the start of line $40, restore it at H $98.
    var memory = try videoMemory()
    try store([0x4001, 0xFFFE, 0x0180, 0x0F00, 0x4099, 0xFFFE, 0x0180, 0x0000, 0xFFFF, 0xFFFE],
              at: 0x2000, in: &memory)
    try memory.writeLong(0x2000, at: 0xDFF080) // COP1LC
    try memory.writeWord(0x8280, at: 0xDFF096) // DMAEN | COPEN
    memory.advanceChipset(colorClocks: frame + CustomChips.colorClocksPerLine * 0x42)
    let split = 0x98 * 4 - Video.firstLowresColumn * 2 // first column at colour clock $98
    #expect(pixel(memory, row: 0x40, column: split - 16) == red)
    #expect(pixel(memory, row: 0x40, column: split + 16) == black)
    #expect(pixel(memory, row: 0x41, column: split - 16) == black)
}
