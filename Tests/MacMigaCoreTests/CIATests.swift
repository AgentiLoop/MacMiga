import Testing
@testable import MacMigaCore

private func ciaMemory() throws -> AmigaMemory {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom[0] = 0xA5
    return try AmigaMemory(kickstart: rom)
}

@Test func portsCombineOutputsWithPulledUpInputs() {
    var cia = CIA8520()
    #expect(cia.read(register: 0) == 0xFF)
    cia.write(register: 0, value: 0x00)
    #expect(cia.read(register: 0) == 0xFF) // still inputs
    cia.write(register: 2, value: 0x0F)
    #expect(cia.read(register: 0) == 0xF0)
    #expect(cia.read(register: 2) == 0x0F)
    cia.inputA = 0x7F // e.g. fire button pressed on bit 7
    #expect(cia.read(register: 0) == 0x70)
    cia.write(register: 3, value: 0xFF)
    cia.write(register: 1, value: 0x5A)
    #expect(cia.read(register: 1) == 0x5A)
}

@Test func kickstartOverlaySequenceUnmapsROMFromChipRAM() throws {
    var memory = try ciaMemory()
    _ = try memory.reset()
    #expect(memory.overlayEnabled)
    #expect(try memory.readByte(at: 0) == 0xA5)
    // Kickstart 1.3: MOVE.B #3,$BFE201 (DDRA) then MOVE.B #2,$BFE001 (PRA: OVL low, LED high).
    try memory.writeByte(0x03, at: 0xBF_E201)
    #expect(!memory.overlayEnabled) // PA0 now drives the reset-cleared PRA latch (0)
    try memory.writeByte(0x02, at: 0xBF_E001)
    #expect(!memory.overlayEnabled)
    #expect(try memory.readByte(at: 0) == 0)
    try memory.writeByte(0x77, at: 0)
    #expect(try memory.readByte(at: 0) == 0x77)
    // Reset restores the overlay without clearing RAM.
    _ = try memory.reset()
    #expect(memory.overlayEnabled)
    memory.setOverlay(enabled: false)
    #expect(try memory.readByte(at: 0) == 0x77)
}

@Test func ciaAddressDecodingUsesA12A13AndByteLane() throws {
    var memory = try ciaMemory()
    // CIA-A: odd addresses with A12 low; mirrors throughout $A00000-$BFFFFF (3.1 uses $BFA001).
    try memory.writeByte(0x12, at: 0xBF_E301) // CIA-A DDRB
    #expect(memory.ciaA.directionB == 0x12)
    try memory.writeByte(0x34, at: 0xBF_A301)
    #expect(memory.ciaA.directionB == 0x34)
    try memory.writeByte(0x56, at: 0xA0_0301)
    #expect(memory.ciaA.directionB == 0x56)
    // CIA-B: even addresses with A13 low.
    try memory.writeByte(0x9A, at: 0xBF_D300)
    #expect(memory.ciaB.directionB == 0x9A)
    #expect(memory.ciaA.directionB == 0x56)
    // A12 high deselects CIA-A; A13 high deselects CIA-B: reads float to $FF here.
    try memory.writeByte(0xEE, at: 0xBF_D301)
    #expect(memory.ciaA.directionB == 0x56)
    #expect(try memory.readByte(at: 0xBF_D301) == 0xFF)
    #expect(try memory.readByte(at: 0xBF_E300) == 0xFF)
    // A word write hits CIA-B (high byte) and CIA-A (low byte) together when both selected.
    try memory.writeWord(0x1122, at: 0xBF_C300)
    #expect(memory.ciaB.directionB == 0x11)
    #expect(memory.ciaA.directionB == 0x22)
    #expect(try memory.readWord(at: 0xBF_C300) == 0x1122)
}

@Test func timerLatchLoadsAndContinuousUnderflow() {
    var cia = CIA8520()
    cia.write(register: 4, value: 0x10)
    #expect(cia.timerA == 0xFFFF) // low byte only latches
    cia.write(register: 5, value: 0x00)
    #expect(cia.timerA == 0x0010) // high byte loads a stopped timer
    cia.write(register: 0xD, value: 0x81) // enable TA interrupt
    cia.write(register: 0xE, value: 0x01) // start, continuous
    cia.tick(eClocks: 15)
    #expect(cia.timerA == 1)
    #expect(!cia.interruptRequested)
    cia.tick(eClocks: 1)
    #expect(cia.timerA == 0x10)
    #expect(cia.interruptRequested)
    #expect(cia.read(register: 0xD) == 0x81)
    #expect(cia.read(register: 0xD) == 0x00) // ICR read clears
    cia.tick(eClocks: 32)
    #expect(cia.timerA == 0x10)
    #expect(cia.read(register: 0xE) & 0x01 == 1)
    #expect(cia.read(register: 0xD) == 0x81)
    cia.write(register: 0xE, value: 0x00)
    cia.tick(eClocks: 5)
    #expect(cia.timerA == 0x10) // stopped
}

@Test func oneShotTimerStartsOnHighByteWriteAndStops() {
    var cia = CIA8520()
    cia.write(register: 0xF, value: 0x08) // timer B one-shot, stopped
    cia.write(register: 6, value: 0x05)
    cia.write(register: 7, value: 0x00)
    #expect(cia.read(register: 0xF) & 0x01 == 1) // 8520: high-byte write starts one-shot
    cia.tick(eClocks: 100)
    #expect(cia.read(register: 0xF) & 0x01 == 0)
    #expect(cia.timerB == 5)
    #expect(cia.read(register: 0xD) == 0x02) // masked: no IR bit
}

@Test func forceLoadAndTimerBCountsTimerAUnderflows() {
    var cia = CIA8520()
    cia.write(register: 4, value: 2)
    cia.write(register: 5, value: 0)
    cia.write(register: 6, value: 3)
    cia.write(register: 7, value: 0)
    cia.tick(eClocks: 1) // both stopped
    cia.write(register: 0xE, value: 0x11) // start + force load
    #expect(cia.read(register: 0xE) == 0x01) // LOAD strobe reads back clear
    cia.write(register: 0xF, value: 0x41) // start, count TA underflows
    cia.tick(eClocks: 4) // two TA underflows
    #expect(cia.timerB == 1)
    cia.tick(eClocks: 2)
    #expect(cia.timerB == 3)
    #expect(cia.read(register: 0xD) == 0x03)
}

@Test func todCountsLatchesHaltsAndAlarms() {
    var cia = CIA8520()
    cia.write(register: 0xA, value: 0x00) // writing high halts
    cia.write(register: 9, value: 0x01)
    cia.pulseTOD()
    #expect(cia.tod == 0x100)
    cia.write(register: 8, value: 0xFE) // writing low restarts
    cia.pulseTOD()
    #expect(cia.tod == 0x1FF)
    #expect(cia.read(register: 0xA) == 0x00) // latches
    cia.pulseTOD()
    #expect(cia.read(register: 9) == 0x01)
    #expect(cia.read(register: 8) == 0xFF) // latched value, then unlatches
    #expect(cia.read(register: 8) == 0x00)
    // Alarm: CRB bit 7 redirects TOD writes.
    cia.write(register: 0xF, value: 0x80)
    cia.write(register: 0xA, value: 0)
    cia.write(register: 9, value: 2)
    cia.write(register: 8, value: 2)
    #expect(cia.tod == 0x200)
    cia.write(register: 0xD, value: 0x84)
    cia.pulseTOD()
    cia.pulseTOD()
    #expect(cia.interruptRequested)
    #expect(cia.read(register: 0xD) == 0x84)
}

@Test func icrMaskSetAndClear() {
    var cia = CIA8520()
    cia.write(register: 0xD, value: 0x9F)
    #expect(cia.interruptMask == 0x1F)
    cia.write(register: 0xD, value: 0x05)
    #expect(cia.interruptMask == 0x1A)
    cia.write(register: 0xD, value: 0x80)
    #expect(cia.interruptMask == 0x1A)
}
