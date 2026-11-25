import Testing
@testable import MacMigaCore

private func machine() throws -> AmigaMachine {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom.replaceSubrange(0..<8, with: [0x00, 0x00, 0x80, 0x00, 0x00, 0xFC, 0x00, 0xD2])
    var machine = try AmigaMachine(kickstart: rom, slowRAMSize: 0)
    machine.memory.setOverlay(enabled: false)
    return machine
}

private func store(_ words: [UInt16], at address: UInt32, in memory: inout AmigaMemory) throws {
    for (offset, word) in words.enumerated() { try memory.writeWord(word, at: address + UInt32(offset * 2)) }
}

@Test func interruptsAreMaskedByStatusRegisterExceptLevelSeven() throws {
    var machine = try machine()
    try machine.memory.writeLong(0x500, at: 0x6C) // level 3 autovector
    try machine.memory.writeLong(0x700, at: 0x7C) // level 7 autovector
    machine.cpu.programCounter = 0x200
    machine.cpu.statusRegister = 0x2315
    #expect(try machine.cpu.interrupt(level: 3, memory: &machine.memory) == false)
    #expect(try machine.cpu.interrupt(level: 0, memory: &machine.memory) == false)
    machine.cpu.statusRegister = 0x0215 // user mode, mask 2
    machine.cpu.userStackPointer = 0x3000
    #expect(try machine.cpu.interrupt(level: 3, memory: &machine.memory))
    #expect(machine.cpu.programCounter == 0x500)
    #expect(machine.cpu.statusRegister == 0x2315)
    #expect(machine.cpu.supervisorStackPointer == 0x8000 - 6)
    #expect(try machine.memory.readWord(at: 0x7FFA) == 0x0215)
    #expect(try machine.memory.readLong(at: 0x7FFC) == 0x200)
    machine.cpu.statusRegister = 0x2700
    #expect(try machine.cpu.interrupt(level: 7, memory: &machine.memory))
    #expect(machine.cpu.programCounter == 0x700)
    #expect(machine.cpu.statusRegister == 0x2700)
}

@Test func stopWaitsForVerticalBlankInterruptAndRTEResumes() throws {
    var machine = try machine()
    try machine.memory.writeLong(0x400, at: 0x6C)
    // Handler: MOVE.W #$0020,$DFF09C (acknowledge VERTB); RTE
    try store([0x33FC, 0x0020, 0x00DF, 0xF09C, 0x4E73], at: 0x400, in: &machine.memory)
    // Main: STOP #$2000; MOVEQ #1,D0; BRA.S *
    try store([0x4E72, 0x2000, 0x7001, 0x60FE], at: 0x200, in: &machine.memory)
    try machine.memory.writeWord(0xC020, at: 0xDFF09A) // INTEN | VERTB
    machine.cpu.programCounter = 0x200
    try machine.step()
    #expect(machine.cpu.isStopped)
    #expect(machine.cpu.statusRegister == 0x2000)
    var steps = 0
    while machine.cpu[data: 0] != 1 && steps < 100_000 {
        try machine.step()
        steps += 1
    }
    #expect(machine.cpu[data: 0] == 1)
    #expect(!machine.cpu.isStopped)
    #expect(machine.cpu.statusRegister & 0x2700 == 0x2000) // RTE restored the mask
    #expect(machine.memory.custom.intreq & 0x0020 == 0)
    let frame = UInt64(CustomChips.colorClocksPerLine * CustomChips.linesPerFrame * 2)
    #expect(machine.clock >= frame && machine.clock < frame + 100)
}

@Test func stopIsPrivileged() throws {
    var machine = try machine()
    try machine.memory.writeLong(0x600, at: 0x20)
    try store([0x4E72, 0x2000], at: 0x200, in: &machine.memory)
    machine.cpu.programCounter = 0x200
    machine.cpu.userStackPointer = 0x3000
    machine.cpu.statusRegister = 0x0000
    try machine.step()
    #expect(!machine.cpu.isStopped)
    #expect(machine.cpu.programCounter == 0x600)
}

@Test func ciaTimerUnderflowsRaisePortsAndExterInterrupts() throws {
    var machine = try machine()
    try machine.memory.writeWord(0xC000 | 0x2008, at: 0xDFF09A) // INTEN | EXTER | PORTS
    for (base, bit, level) in [(UInt32(0xBFE001), UInt16(0x0008), 2), (UInt32(0xBFD000), UInt16(0x2000), 6)] {
        try machine.memory.writeByte(0x81, at: base + 0xD00) // ICR: enable timer A
        try machine.memory.writeByte(10, at: base + 0x400)   // TALO
        try machine.memory.writeByte(0, at: base + 0x500)    // TAHI
        try machine.memory.writeByte(0x01, at: base + 0xE00) // CRA: start, continuous
        machine.advance(cpuClocks: 90)
        #expect(machine.memory.custom.intreq & bit == 0)
        machine.advance(cpuClocks: 20)
        #expect(machine.memory.custom.intreq & bit != 0)
        #expect(machine.memory.custom.interruptLevel == level)
        _ = try machine.memory.readByte(at: base + 0xD00) // reading ICR releases /IRQ
        try machine.memory.writeWord(bit, at: 0xDFF09C)
        machine.advance(cpuClocks: 10)
        #expect(machine.memory.custom.intreq & bit == 0)
    }
}

@Test func beamDrivesTimeOfDayCounters() throws {
    var machine = try machine()
    let line = CustomChips.colorClocksPerLine * 2
    machine.advance(cpuClocks: line * CustomChips.linesPerFrame)
    #expect(machine.memory.ciaA.read(register: 0x8) == 1)          // one VSYNC
    #expect(machine.memory.ciaB.read(register: 0x8) == UInt8(CustomChips.linesPerFrame & 0xFF))
}

@Test func powerOnAndResetLoadTheVectorsThroughTheROMOverlay() throws {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom.replaceSubrange(0..<8, with: [0, 8, 0, 0, 0, 0xFC, 0, 8])
    rom.replaceSubrange(8..<12, with: [0x70, 0xFF, 0x4E, 0x71]) // moveq #-1,d0 ; nop
    var machine = try AmigaMachine(kickstart: rom)
    #expect(machine.memory.overlayEnabled)
    #expect(machine.cpu.programCounter == 0xFC_0008)
    #expect(machine.cpu.supervisorStackPointer == 0x08_0000)
    #expect(machine.cpu.statusRegister == 0x2700)
    try machine.step()
    #expect(machine.cpu[data: 0] == 0xFFFF_FFFF)
    #expect(machine.cpu.programCounter == 0xFC_000A)
    // With the overlay off, address 4 is chip RAM; a reset brings the ROM's vectors back.
    machine.memory.setOverlay(enabled: false)
    try machine.memory.writeLong(0x0012_3456, at: 4)
    _ = try machine.memory.reset()
    try machine.cpu.reset(memory: &machine.memory)
    #expect(machine.memory.overlayEnabled)
    #expect(machine.cpu.programCounter == 0xFC_0008)
    #expect(machine.cpu[data: 0] == 0xFFFF_FFFF) // general registers are kept
}

@Test func resetInstructionResetsTheChipsTheOverlayAndTheExpansionBoards() throws {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom.replaceSubrange(0..<8, with: [0, 8, 0, 0, 0, 0xFC, 0, 8])
    rom.replaceSubrange(8..<10, with: [0x70, 0x2A])         // $FC0008 moveq #42,d0
    var machine = try AmigaMachine(kickstart: rom, fastRAMSize: 1 << 20)
    machine.memory.setOverlay(enabled: false)
    try machine.memory.writeByte(0x00, at: 0xE8_004A)       // configure the fast RAM board at $200000
    try machine.memory.writeByte(0x20, at: 0xE8_0048)
    try machine.memory.writeLong(0xCAFE_F00D, at: 0x20_0000)
    try machine.memory.writeWord(0x8200, at: 0xDF_F096)     // DMACON DMAEN
    try machine.memory.writeWord(0xC020, at: 0xDF_F09A)     // INTENA
    // Code in chip RAM that the overlay will hide: reset ; jmp (a0)
    try machine.memory.writeWord(0x4E70, at: 0x1000)
    try machine.memory.writeWord(0x4ED0, at: 0x1002)
    machine.cpu.programCounter = 0x1000
    machine.cpu[address: 0] = 0xFC_0008
    try machine.step()
    #expect(machine.memory.overlayEnabled)
    #expect(machine.memory.custom.dmacon == 0 && machine.memory.custom.intena == 0)
    #expect(machine.memory.expansion.boards.map(\.base) == [nil])
    #expect(try machine.memory.readLong(at: 0x20_0000) == 0) // the board is off the bus
    #expect(try machine.memory.readWord(at: 0x1002) != 0x4ED0) // ROM is in front of the code
    #expect(machine.cpu.statusRegister == 0x2700)
    try machine.step()                                       // the prefetched jmp (a0)
    #expect(machine.cpu.programCounter == 0xFC_0008)
    try machine.step()
    #expect(machine.cpu[data: 0] == 42)
    // The fast RAM kept its contents and comes back where it is configured.
    try machine.memory.writeByte(0x00, at: 0xE8_004A)
    try machine.memory.writeByte(0x20, at: 0xE8_0048)
    #expect(try machine.memory.readLong(at: 0x20_0000) == 0xCAFE_F00D)
}
