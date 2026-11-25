import Testing
@testable import MacMigaCore

private func spriteMemory() throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024), slowRAMSize: 0)
    memory.setOverlay(enabled: false)
    try memory.writeWord(0x2C81, at: 0xDFF08E) // DIWSTRT
    try memory.writeWord(0x2CC1, at: 0xDFF090) // DIWSTOP
    try memory.writeWord(0x0F00, at: 0xDFF1A2) // COLOR17
    try memory.writeWord(0x00F0, at: 0xDFF1A4) // COLOR18
    try memory.writeWord(0x000F, at: 0xDFF1A6) // COLOR19
    return memory
}

private func store(_ words: [UInt16], at address: UInt32, in memory: inout AmigaMemory) throws {
    for (offset, word) in words.enumerated() { try memory.writeWord(word, at: address + UInt32(offset * 2)) }
}

private func pixel(_ memory: AmigaMemory, row: Int, lowres x: Int) -> UInt32 {
    memory.video.pixels[row * Video.width + (x - Video.firstLowresColumn) * 2]
}

@Test func spriteDMADrawsTwoLineSpriteAtItsPosition() throws {
    var memory = try spriteMemory()
    // VSTART $40, HSTART $90 (pos $40 48, ctl bit0 = 0), VSTOP $42; then end of list.
    try store([0x4048, 0x4200, 0xC000, 0x4000, 0x8000, 0x8000, 0x0000, 0x0000], at: 0x3000, in: &memory)
    try memory.writeLong(0x3000, at: 0xDFF120) // SPR0PT
    try memory.writeWord(0x8220, at: 0xDFF096) // DMAEN | SPREN
    memory.advanceChipset(colorClocks: CustomChips.colorClocksPerLine * 0x44)
    #expect(pixel(memory, row: 0x40, lowres: 0x90) == Video.argb(0xF00)) // A only -> COLOR17
    #expect(pixel(memory, row: 0x40, lowres: 0x91) == Video.argb(0x000F)) // A and B -> COLOR19
    #expect(pixel(memory, row: 0x40, lowres: 0x92) == Video.argb(0x000))
    #expect(pixel(memory, row: 0x41, lowres: 0x90) == Video.argb(0x00F))
    #expect(pixel(memory, row: 0x3F, lowres: 0x90) == Video.argb(0x000))
    #expect(pixel(memory, row: 0x42, lowres: 0x90) == Video.argb(0x000))
    #expect(memory.custom.spritePointers[0] == 0x3010)
}

@Test func attachedSpritesUseSixteenColours() throws {
    var memory = try spriteMemory()
    try memory.writeWord(0x0ABC, at: 0xDFF1BE) // COLOR31
    // Manual mode: write POS/CTL then DATB/DATA (arming) for sprites 0 and 1 (attached).
    for (base, ctl) in [(UInt32(0xDFF140), UInt16(0)), (0xDFF148, 0x0080)] {
        try memory.writeWord(0x0048, at: base)
        try memory.writeWord(ctl, at: base + 2)
        try memory.writeWord(0x8000, at: base + 6)
        try memory.writeWord(0x8000, at: base + 4)
    }
    memory.advanceChipset(colorClocks: CustomChips.colorClocksPerLine * 0x31)
    #expect(pixel(memory, row: 0x30, lowres: 0x90) == Video.argb(0xABC))
    #expect(pixel(memory, row: 0x30, lowres: 0x91) == Video.argb(0x000))
}

@Test func keyboardBytesWaitForHandshake() throws {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom.replaceSubrange(0..<8, with: [0x00, 0x00, 0x80, 0x00, 0x00, 0xFC, 0x00, 0xD2])
    var machine = try AmigaMachine(kickstart: rom, slowRAMSize: 0)
    try machine.memory.writeByte(0x88, at: 0xBFED01) // CIA-A ICR: enable SP
    machine.key(0x45, pressed: true)   // Esc down
    machine.key(0x45, pressed: false)  // Esc up
    machine.advance(cpuClocks: 10)
    func received(_ machine: inout AmigaMachine) throws -> UInt8 {
        let byte = try machine.memory.readByte(at: 0xBFEC01)
        let raw = ~byte
        return raw >> 1 | raw << 7
    }
    #expect(machine.memory.custom.intreq & 0x0008 != 0)
    #expect(try received(&machine) == 0x45)
    _ = try machine.memory.readByte(at: 0xBFED01)
    machine.advance(cpuClocks: 1000)
    #expect(try received(&machine) == 0x45)          // no handshake yet: second byte held
    try machine.memory.writeByte(0x40, at: 0xBFEE01) // SPMODE output (KDAT low)
    try machine.memory.writeByte(0x00, at: 0xBFEE01) // release
    machine.advance(cpuClocks: 10)
    #expect(try received(&machine) == 0xC5)          // key up
}

@Test func mouseAndJoystickPorts() throws {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom.replaceSubrange(0..<8, with: [0x00, 0x00, 0x80, 0x00, 0x00, 0xFC, 0x00, 0xD2])
    var machine = try AmigaMachine(kickstart: rom, slowRAMSize: 0)
    machine.mouse(dx: 5, dy: -3, left: true, right: true)
    #expect(try machine.memory.readWord(at: 0xDFF00A) == 0xFD05)
    #expect(try machine.memory.readByte(at: 0xBFE001) & 0x40 == 0)
    #expect(try machine.memory.readWord(at: 0xDFF016) & 0x0400 == 0)
    machine.mouse(dx: 300, left: false, right: false)
    #expect(try machine.memory.readWord(at: 0xDFF00A) == 0xFD31) // 5 + 300 wraps to $31
    #expect(try machine.memory.readByte(at: 0xBFE001) & 0x40 != 0)
    #expect(try machine.memory.readWord(at: 0xDFF016) & 0x0400 != 0)
    var stick = Joystick()
    stick.up = true
    stick.right = true
    machine.joystick(stick, fire: true)
    #expect(try machine.memory.readWord(at: 0xDFF00C) == 0x0102 | 0x0001) // right, up, down^right
    #expect(try machine.memory.readByte(at: 0xBFE001) & 0x80 == 0)
}
