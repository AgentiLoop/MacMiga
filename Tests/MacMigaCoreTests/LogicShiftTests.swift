import Testing
@testable import MacMigaCore

private func program(_ words: [UInt16], at address: UInt32 = 0x100) throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024))
    memory.setOverlay(enabled: false)
    for (offset, word) in words.enumerated() {
        try memory.writeWord(word, at: address &+ UInt32(offset * 2))
    }
    return memory
}

private func run(_ words: [UInt16], steps: Int = 1, setup: (inout MC68000, inout AmigaMemory) throws -> Void = { _, _ in })
    throws -> (MC68000, AmigaMemory) {
    var memory = try program(words)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu.supervisorStackPointer = 0x8000
    try setup(&cpu, &memory)
    for _ in 0..<steps { try cpu.step(memory: &memory) }
    return (cpu, memory)
}

@Test func bitOperationsOnRegistersAndMemory() throws {
    // BTST #0,D0 (Kickstart 1.3's first), BSET D1,D0 (bit 33 -> 1), BCLR #7,(A0), BCHG #9,(A0) (9 mod 8 = 1)
    let (cpu, memory) = try run([0x0800, 0x0000, 0x03C0, 0x0890, 0x0007, 0x0850, 0x0009], steps: 4) { cpu, memory in
        cpu[data: 0] = 0x8000_0000
        cpu[data: 1] = 33
        cpu[address: 0] = 0x300
        try memory.writeByte(0x80, at: 0x300)
    }
    #expect(cpu[data: 0] == 0x8000_0002)
    #expect(try { var m = memory; return try m.readByte(at: 0x300) }() == 0x02)
    #expect(cpu.statusRegister & 0x04 != 0) // bit 1 was clear before BCHG
    #expect(cpu.programCounter == 0x10E)
}

@Test func btstSetsZeroFromTestedBitOnly() throws {
    for (value, expectZero) in [(UInt32(1), false), (UInt32(0xFFFF_FFFE), true)] {
        let (cpu, _) = try run([0x0800, 0x0020]) { cpu, _ in // BTST #32,D0 -> bit 0
            cpu[data: 0] = value
            cpu.statusRegister = 0x271B
        }
        #expect(cpu.statusRegister == (expectZero ? 0x271F : 0x271B))
    }
}

@Test func immediateLogicArithmeticAndCCR() throws {
    let (cpu, _) = try run([
        0x0040, 0x0F00, // ORI.W #$0F00,D0
        0x0280, 0x0000, 0xFF0F, // ANDI.L #$FF0F,D0
        0x0A00, 0x00FF, // EORI.B #$FF,D0
        0x0641, 0x0001, // ADDI.W #1,D1 ($FFFF -> 0: X C Z)
        0x023C, 0x00FB, // ANDI #$FB,CCR (clear Z)
        0x007C, 0x0700 // ORI #$0700,SR
    ], steps: 6) { cpu, _ in
        cpu[data: 0] = 0x1234_5678
        cpu[data: 1] = 0xAAAA_FFFF
        cpu.statusRegister = 0x2000
    }
    #expect(cpu[data: 0] == 0x0000_5FF7)
    #expect(cpu[data: 1] == 0xAAAA_0000)
    #expect(cpu.statusRegister == 0x2711)
}

@Test func singleOperandGroup() throws {
    let (cpu, memory) = try run([
        0x4239, 0x0000, 0x0300, // CLR.B $300 (Kickstart 3.1's first)
        0x4440,                 // NEG.W D0
        0x4681,                 // NOT.L D1
        0x4A82,                 // TST.L D2
        0x4843,                 // SWAP D3
        0x4884,                 // EXT.W D4
        0x48C5                  // EXT.L D5
    ], steps: 7) { cpu, memory in
        try memory.writeByte(0x55, at: 0x300)
        cpu[data: 0] = 0xFFFF_0001
        cpu[data: 1] = 0x0F0F_0F0F
        cpu[data: 2] = 0x8000_0000
        cpu[data: 3] = 0x1234_5678
        cpu[data: 4] = 0x1111_2280
        cpu[data: 5] = 0x0000_8000
    }
    var copy = memory
    #expect(try copy.readByte(at: 0x300) == 0)
    #expect(cpu[data: 0] == 0xFFFF_FFFF)
    #expect(cpu[data: 1] == 0xF0F0_F0F0)
    #expect(cpu[data: 3] == 0x5678_1234)
    #expect(cpu[data: 4] == 0x1111_FF80)
    #expect(cpu[data: 5] == 0xFFFF_8000)
    #expect(cpu.statusRegister & 0x0F == 0x08)
}

@Test func negAndNegxFlags() throws {
    let (zero, _) = try run([0x4400]) { cpu, _ in cpu[data: 0] = 0; cpu.statusRegister = 0x2700 }
    #expect(zero.statusRegister == 0x2704) // NEG 0: Z, no carry
    let (minimum, _) = try run([0x4400]) { cpu, _ in cpu[data: 0] = 0x80 }
    #expect(minimum.statusRegister == 0x271B) // X N V C
    // NEGX with X set on 0 gives -1 and keeps Z only if it was already set (here cleared by nonzero).
    let (negx, _) = try run([0x4080]) { cpu, _ in cpu[data: 0] = 0; cpu.statusRegister = 0x2714 }
    #expect(negx[data: 0] == 0xFFFF_FFFF)
    #expect(negx.statusRegister == 0x2719)
}

@Test func registerLogicMultiplyDivideAndExchange() throws {
    let (cpu, _) = try run([
        0x8041,         // OR.W D1,D0
        0xC481,         // AND.L D1,D2
        0xB343,         // EOR.W D1,D3
        0xC8C1,         // MULU.W D1,D4
        0xCBC1,         // MULS.W D1,D5
        0x8CC7,         // DIVU.W D7,D6
        0xC149          // EXG A0,A1
    ], steps: 7) { cpu, _ in
        cpu[data: 0] = 0x1111_0F00
        cpu[data: 1] = 0x0000_FFFE
        cpu[data: 2] = 0xF0F0_F0F0
        cpu[data: 3] = 0x0000_00FF
        cpu[data: 4] = 0xAAAA_0003
        cpu[data: 5] = 0x0000_0003
        cpu[data: 6] = 100_003
        cpu[data: 7] = 10
        cpu[address: 0] = 1
        cpu[address: 1] = 2
    }
    #expect(cpu[data: 0] == 0x1111_FFFE)
    #expect(cpu[data: 2] == 0x0000_F0F0)
    #expect(cpu[data: 3] == 0x0000_FF01)
    #expect(cpu[data: 4] == 3 * 0xFFFE)
    #expect(cpu[data: 5] == UInt32(bitPattern: -6))
    #expect(cpu[data: 6] == 3 << 16 | 10_000)
    #expect(cpu[address: 0] == 2 && cpu[address: 1] == 1)
}

@Test func divisionOverflowAndSignedRemainder() throws {
    let (overflow, _) = try run([0x80C1]) { cpu, _ in cpu[data: 0] = 0x0010_0000; cpu[data: 1] = 1 }
    #expect(overflow[data: 0] == 0x0010_0000)
    #expect(overflow.statusRegister & 0x03 == 0x02)
    let (signed, _) = try run([0x81C1]) { cpu, _ in cpu[data: 0] = UInt32(bitPattern: -7); cpu[data: 1] = 2 }
    #expect(signed[data: 0] == 0xFFFF_FFFD) // remainder -1, quotient -3
}

@Test func shiftsAndRotates() throws {
    func shifted(_ opcode: UInt16, _ value: UInt32, count: UInt32 = 0, x: Bool = false) throws -> (UInt32, UInt16) {
        let (cpu, _) = try run([opcode]) { cpu, _ in
            cpu[data: 0] = value
            cpu[data: 1] = count
            cpu.statusRegister = x ? 0x2710 : 0x2700
        }
        return (cpu[data: 0], cpu.statusRegister & 0x1F)
    }
    #expect(try shifted(0xE300, 0x40) == (0x80, 0x0A))                  // ASL.B #1: N V
    #expect(try shifted(0xE200, 0x81) == (0xC0, 0x19))                  // ASR.B #1: X N C
    #expect(try shifted(0xE348, 0x8001) == (0x0002, 0x11))              // LSL.W #1: X C
    #expect(try shifted(0xE088, 0x8000_0000) == (0x0080_0000, 0x00))    // LSR.L #8
    #expect(try shifted(0xE358, 0x8001) == (0x0003, 0x01))              // ROL.W #1: C, X kept clear
    #expect(try shifted(0xE258, 0x0001, x: true) == (0x8000, 0x19))     // ROR.W #1: X kept
    #expect(try shifted(0xE350, 0x8000, x: true) == (0x0001, 0x11))     // ROXL.W #1
    #expect(try shifted(0xE2A0, 0xFFFF_FFFF, count: 0, x: true) == (0xFFFF_FFFF, 0x18)) // ASR.L D1 count 0
    #expect(try shifted(0xE3A8, 1, count: 65) == (2, 0x00))             // LSL.L D1, count mod 64
    let (memoryShift, memory) = try run([0xE1D0]) { cpu, memory in      // ASL.W (A0)
        cpu[address: 0] = 0x300
        try memory.writeWord(0xC000, at: 0x300)
    }
    var copy = memory
    #expect(try copy.readWord(at: 0x300) == 0x8000)
    #expect(memoryShift.statusRegister & 0x1F == 0x19)
}

@Test func moveMultipleRoundTripAndPredecrementOrder() throws {
    let (cpu, memory) = try run([
        0x48E7, 0xC0C0, // MOVEM.L D0-D1/A0-A1,-(A7)
        0x4CDF, 0x0303  // MOVEM.L (A7)+,D0-D1/A0-A1
    ], steps: 1) { cpu, _ in
        cpu.statusRegister = 0x2700
        cpu[data: 0] = 0xD0; cpu[data: 1] = 0xD1
        cpu[address: 0] = 0xA0; cpu[address: 1] = 0xA1
    }
    var copy = memory
    #expect(cpu[address: 7] == 0x8000 - 16)
    #expect(try copy.readLong(at: 0x7FF0) == 0xD0)
    #expect(try copy.readLong(at: 0x7FFC) == 0xA1)
    var restored = cpu
    restored[data: 0] = 0; restored[data: 1] = 0; restored[address: 0] = 0; restored[address: 1] = 0
    try restored.step(memory: &copy)
    #expect(restored[data: 0] == 0xD0 && restored[data: 1] == 0xD1)
    #expect(restored[address: 0] == 0xA0 && restored[address: 1] == 0xA1)
    #expect(restored[address: 7] == 0x8000)
    // Word loads sign-extend into the full register.
    let (word, _) = try run([0x4C90, 0x0001]) { cpu, memory in // MOVEM.W (A0),D0
        cpu[address: 0] = 0x300
        try memory.writeWord(0x8001, at: 0x300)
    }
    #expect(word[data: 0] == 0xFFFF_8001)
}

@Test func linkUnlinkPeaSccAndStatusMoves() throws {
    let (cpu, memory) = try run([
        0x4E56, 0xFFF8, // LINK A6,#-8
        0x4878, 0x1234, // PEA $1234.W
        0x57C0,         // SEQ D0
        0x56C1,         // SNE D1
        0x40C2,         // MOVE SR,D2
        0x44FC, 0x001F, // MOVE #$1F,CCR
        0x4E5E          // UNLK A6
    ], steps: 7) { cpu, _ in
        cpu.statusRegister = 0x2704
        cpu[address: 6] = 0xCAFE
        cpu[data: 0] = 0x1111_1100
        cpu[data: 1] = 0x2222_22FF
    }
    var copy = memory
    #expect(try copy.readLong(at: 0x7FFC) == 0xCAFE)
    #expect(try copy.readLong(at: 0x7FF0) == 0x1234)
    #expect(cpu[data: 0] == 0x1111_11FF)
    #expect(cpu[data: 1] == 0x2222_2200)
    #expect(cpu[data: 2] & 0xFFFF == 0x2704)
    #expect(cpu.statusRegister == 0x271F)
    #expect(cpu[address: 6] == 0xCAFE)
    #expect(cpu[address: 7] == 0x8000)
}

@Test func trapAndRTERoundTripThroughVectorTable() throws {
    let (cpu, memory) = try run([0x4E41, 0x4E71], steps: 1) { cpu, memory in // TRAP #1
        cpu.statusRegister = 0x0015 // user mode
        cpu.userStackPointer = 0x4000
        try memory.writeLong(0x200, at: 33 * 4)
        try memory.writeWord(0x4E73, at: 0x200) // RTE
    }
    var copy = memory
    #expect(cpu.programCounter == 0x200)
    #expect(cpu.statusRegister == 0x2015)
    #expect(cpu.supervisorStackPointer == 0x8000 - 6)
    #expect(try copy.readWord(at: 0x7FFA) == 0x0015)
    #expect(try copy.readLong(at: 0x7FFC) == 0x102)
    var back = cpu
    try back.step(memory: &copy)
    #expect(back.programCounter == 0x102)
    #expect(back.statusRegister == 0x0015)
    #expect(back[address: 7] == 0x4000)
    #expect(back.supervisorStackPointer == 0x8000)
}

@Test func privilegeIllegalLineFAndDivideByZeroVectors() throws {
    // (program, user mode?, vector, stacked PC)
    let cases: [([UInt16], Bool, Int, UInt32)] = [
        ([0x46FC, 0x2700], true, 8, 0x100), // MOVE #,SR in user mode
        ([0x4E73], true, 8, 0x100),         // RTE in user mode
        ([0x4AFC], false, 4, 0x100),        // ILLEGAL
        ([0x4E7A, 0x0801], false, 4, 0x100),// MOVEC (68010+) used for CPU detection
        ([0xF200], false, 11, 0x100),       // line F
        ([0xA000], false, 10, 0x100),       // line A
        ([0x80C1], false, 5, 0x102)         // DIVU D1,D0 with D1 = 0: next instruction
    ]
    for (words, user, vector, stacked) in cases {
        let (cpu, memory) = try run(words) { cpu, memory in
            cpu.statusRegister = user ? 0x0000 : 0x2000
            cpu.userStackPointer = 0x4000
            try memory.writeLong(0x400 + UInt32(vector) * 4, at: UInt32(vector) * 4)
        }
        var copy = memory
        #expect(cpu.programCounter == 0x400 + UInt32(vector) * 4)
        #expect(cpu.statusRegister & 0x2000 != 0)
        #expect(try copy.readLong(at: 0x7FFC) == stacked)
    }
}
