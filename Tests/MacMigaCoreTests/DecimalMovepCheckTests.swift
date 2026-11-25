import Testing
@testable import MacMigaCore

private func run(_ words: [UInt16], steps: Int = 1, setup: (inout MC68000, inout AmigaMemory) throws -> Void = { _, _ in })
    throws -> (MC68000, AmigaMemory) {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024))
    memory.setOverlay(enabled: false)
    for (offset, word) in words.enumerated() { try memory.writeWord(word, at: 0x100 + UInt32(offset * 2)) }
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu.supervisorStackPointer = 0x8000
    try setup(&cpu, &memory)
    for _ in 0..<steps { try cpu.step(memory: &memory) }
    return (cpu, memory)
}

@Test func abcdAddsPackedDecimalWithExtend() throws {
    // ABCD D1,D0: $45 + $38 + X = $84; then $99 + $01 = $00 with carry, Z kept clear.
    let (cpu, _) = try run([0xC101, 0xC503], steps: 2) { cpu, _ in
        cpu[data: 0] = 0xFFFF_FF45
        cpu[data: 1] = 0x38
        cpu[data: 2] = 0x99
        cpu[data: 3] = 0x01
        cpu.statusRegister = 0x2014 // X and Z set
    }
    #expect(cpu[data: 0] == 0xFFFF_FF84)
    #expect(cpu[data: 2] == 0x00)
    #expect(cpu.statusRegister & 0x15 == 0x11) // X C set, Z cleared by the nonzero first result
}

@Test func sbcdAndNbcdSubtractPackedDecimal() throws {
    // SBCD D1,D0: $42 - $17 = $25; NBCD D2: 0 - $01 = $99 borrow.
    let (cpu, _) = try run([0x8101, 0x4802], steps: 2) { cpu, _ in
        cpu[data: 0] = 0x42
        cpu[data: 1] = 0x17
        cpu[data: 2] = 0x01
        cpu.statusRegister = 0x2004
    }
    #expect(cpu[data: 0] == 0x25)
    #expect(cpu[data: 2] == 0x99)
    #expect(cpu.statusRegister & 0x15 == 0x11)
}

@Test func sbcdMemoryFormPredecrements() throws {
    // SBCD -(A1),-(A0): $50 - $01 = $49
    let (cpu, memory) = try run([0x8109]) { cpu, memory in
        cpu[address: 0] = 0x301
        cpu[address: 1] = 0x401
        try memory.writeByte(0x50, at: 0x300)
        try memory.writeByte(0x01, at: 0x400)
        cpu.statusRegister = 0x2000
    }
    var m = memory
    #expect(try m.readByte(at: 0x300) == 0x49)
    #expect(cpu[address: 0] == 0x300 && cpu[address: 1] == 0x400)
}

@Test func movepTransfersAlternateBytes() throws {
    // MOVEP.L D0,(0,A0); MOVEP.W (2,A0),D1
    let (cpu, memory) = try run([0x01C8, 0x0000, 0x0308, 0x0002], steps: 2) { cpu, _ in
        cpu[data: 0] = 0x1122_3344
        cpu[data: 1] = 0xAAAA_AAAA
        cpu[address: 0] = 0x301
    }
    var m = memory
    #expect(try m.readByte(at: 0x301) == 0x11)
    #expect(try m.readByte(at: 0x303) == 0x22)
    #expect(try m.readByte(at: 0x305) == 0x33)
    #expect(try m.readByte(at: 0x307) == 0x44)
    #expect(try m.readByte(at: 0x302) == 0x00)
    #expect(cpu[data: 1] == 0xAAAA_2233)
    #expect(cpu.programCounter == 0x108)
}

@Test func chkTrapsOutsideBounds() throws {
    // CHK #10,D0 with D0 = 5 (passes), then D1 = -1 (traps through vector 6 with N set).
    let (cpu, memory) = try run([0x41BC, 0x000A, 0x43BC, 0x000A], steps: 2) { cpu, memory in
        cpu[data: 0] = 5
        cpu[data: 1] = 0xFFFF
        cpu.statusRegister = 0x2000
        try memory.writeLong(0x2000, at: 6 * 4)
    }
    #expect(cpu.programCounter == 0x2000)
    var m = memory
    #expect(try m.readLong(at: 0x7FFC) == 0x108) // return to the next instruction
    #expect(try m.readWord(at: 0x7FFA) & 0x08 != 0) // stacked N
}

@Test func unassignedOpcodeTakesIllegalInstructionException() throws {
    // $4808 (LINK.L, a 68020 instruction) is not a 68000 opcode.
    let (cpu, memory) = try run([0x4808]) { cpu, memory in
        cpu.statusRegister = 0x0000
        cpu.userStackPointer = 0x6000
        try memory.writeLong(0x3000, at: 4 * 4)
    }
    #expect(cpu.programCounter == 0x3000)
    #expect(cpu.statusRegister & 0x2000 != 0)
    var m = memory
    #expect(try m.readLong(at: 0x7FFC) == 0x100) // stacked PC is the illegal opcode itself
    #expect(try m.readWord(at: 0x7FFA) == 0x0000)
}
