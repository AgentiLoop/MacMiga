import Testing
import M68K

private func run(_ words: [UInt16], steps: Int = 1, setup: (inout MC68000, inout TestBus) throws -> Void = { _, _ in })
    throws -> (MC68000, TestBus) {
    var memory = TestBus()
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

@Test func oddWordWriteTakesAddressErrorWithGroupZeroFrame() throws {
    // MOVE.W D0,(A0) with A0 odd, in user mode.
    let (cpu, memory) = try run([0x3080]) { cpu, memory in
        cpu.statusRegister = 0x0000
        cpu[address: 0] = 0x301
        try memory.writeLong(0x3000, at: 3 * 4)
    }
    #expect(cpu.programCounter == 0x3000)
    #expect(cpu.supervisorStackPointer == 0x8000 - 14)
    var m = memory
    #expect(try m.readWord(at: 0x7FF2) == 0x3081)   // write, user data space; upper bits from the opcode
    #expect(try m.readLong(at: 0x7FF4) == 0x301)    // access address
    #expect(try m.readWord(at: 0x7FF8) == 0x3080)   // instruction register
    #expect(try m.readWord(at: 0x7FFA) == 0x0000)   // SR
    #expect(try m.readLong(at: 0x7FFC) == 0x102)    // PC
}

@Test func oddOpcodeFetchTakesAddressError() throws {
    // BRA.S *+1 fetches from an odd address before it ends: a supervisor program-space read
    // fault with the branch still in the instruction register. A branch stacks its own address
    // + 2 as PC (Rob Northen's Copylock depends on it).
    let (cpu, memory) = try run([0x60FF]) { _, memory in
        try memory.writeLong(0x3000, at: 3 * 4)
    }
    #expect(cpu.programCounter == 0x3000)
    #expect(cpu.supervisorStackPointer == 0x8000 - 14)
    var m = memory
    #expect(try m.readWord(at: 0x7FF2) == 0x60F6)   // read, supervisor program space
    #expect(try m.readLong(at: 0x7FF4) == 0x101)
    #expect(try m.readWord(at: 0x7FF8) == 0x60FF)   // instruction register
    #expect(try m.readLong(at: 0x7FFC) == 0x102)
}

@Test func jsrToAnOddAddressFaultsBeforeItPushes() throws {
    // JSR $00000301: the 68000 fetches from the target first, so no return address is pushed.
    let (cpu, memory) = try run([0x4EB9, 0x0000, 0x0301]) { _, memory in
        try memory.writeLong(0x3000, at: 3 * 4)
    }
    #expect(cpu.programCounter == 0x3000)
    #expect(cpu.supervisorStackPointer == 0x8000 - 14)
    var m = memory
    #expect(try m.readWord(at: 0x7FF2) == 0x4EB6)
    #expect(try m.readLong(at: 0x7FF4) == 0x301)
    #expect(try m.readWord(at: 0x7FF8) == 0x4EB9)
}

@Test func addressErrorFrameHoldsAll32BitsOfTheAddress() throws {
    // MOVE.W (A0),D0 with A0 = $12001001: only 24 bits would reach the pins, the frame has all 32.
    let (_, memory) = try run([0x3010]) { cpu, memory in
        cpu[address: 0] = 0x1200_1001
        try memory.writeLong(0x3000, at: 3 * 4)
    }
    var m = memory
    #expect(try m.readLong(at: 0x7FF4) == 0x1200_1001)
}

@Test func decimalArithmeticOnOperandsThatAreNotBCD() throws {
    // Expected values from the SingleStepTests 68000 set (github.com/SingleStepTests/680x0).
    // (opcode, destination register, destination, source register, source, SR, result, SR after)
    let cases: [(UInt16, Int, UInt32, Int, UInt32, UInt16, UInt32, UInt16)] = [
        (0xC102, 0, 0x2693_027E, 2, 0xBD0F_976B, 0x2701, 0x2693_024F, 0x2711), // ABCD D2,D0
        (0xC106, 0, 0x4109_0FB8, 6, 0x8D92_ADB4, 0x270B, 0x4109_0FD2, 0x271B), // ABCD D6,D0
        (0x8501, 2, 0x140C_B5EF, 1, 0x030D_A0BC, 0x2708, 0x140C_B533, 0x2700), // SBCD D1,D2
        (0x8500, 2, 0x1CD7_ECDF, 0, 0x8659_77A8, 0x271C, 0x1CD7_EC36, 0x2700), // SBCD D0,D2
        (0x4802, 2, 0x5278_DE0D, 2, 0x5278_DE0D, 0x2717, 0x5278_DE8C, 0x2719), // NBCD D2
        (0x4801, 1, 0x75B6_C01C, 1, 0x75B6_C01C, 0x270F, 0x75B6_C07E, 0x2713)  // NBCD D1
    ]
    for (opcode, destination, value, source, operand, status, result, statusAfter) in cases {
        let (cpu, _) = try run([opcode]) { cpu, _ in
            cpu[data: source] = operand
            cpu[data: destination] = value
            cpu.statusRegister = status
        }
        #expect(cpu[data: destination] == result)
        #expect(cpu.statusRegister == statusAfter)
    }
}

@Test func chkClearsNZVCWithoutATrap() throws {
    // CHK D7,D5 and CHK D0,D2 within bounds (SingleStepTests m68000 set). N follows the sign
    // of the register, so it is clear whenever CHK does not trap.
    for (opcode, bound, value, status, statusAfter) in [
        (UInt16(0x4B87), UInt32(0x36C6_5C8A), UInt32(0x8A75_0B62), UInt16(0x2008), UInt16(0x2000)),
        (0x4580, 0x37B4_5B3D, 0x3A40_0A31, 0xA51E, 0xA510)
    ] {
        let (cpu, _) = try run([opcode]) { cpu, _ in
            cpu[data: Int(opcode & 7)] = bound
            cpu[data: Int((opcode >> 9) & 7)] = value
            cpu.statusRegister = status
            cpu.stopsBeforeTrace = true // the sets end before the trace exception
        }
        #expect(cpu.programCounter == 0x102)
        #expect(cpu.statusRegister == statusAfter)
    }
}

@Test func divisionOverflowSetsNAndVAndClearsZAndC() throws {
    // DIVU D7,D0, DIVS D5,D3 and DIVS D3,D2 (SingleStepTests m68000 set): the register is
    // unchanged, and N and Z, which are documented as undefined, come out as 1 and 0.
    for (opcode, divisor, dividend, status, statusAfter) in [
        (UInt16(0x80C7), UInt32(0x9961_565E), UInt32(0x74C0_9614), UInt16(0x2606), UInt16(0x260A)),
        (0x87C5, 0x708B_EE80, 0x7C82_59CF, 0xA205, 0xA20A),
        (0x85C3, 0xE261_9026, 0x993C_AF16, 0x2014, 0x201A)
    ] {
        let (cpu, _) = try run([opcode]) { cpu, _ in
            cpu[data: Int(opcode & 7)] = divisor
            cpu[data: Int((opcode >> 9) & 7)] = dividend
            cpu.statusRegister = status
            cpu.stopsBeforeTrace = true // the sets end before the trace exception
        }
        #expect(cpu[data: Int((opcode >> 9) & 7)] == dividend)
        #expect(cpu.statusRegister == statusAfter)
    }
}

@Test func chkAndDivideByZeroTrapAfterThePostincrement() throws {
    // CHK (A0)+,D2 above its bound, then DIVU (A0)+,D0 by zero: A0 has moved on when the
    // exception is taken, and the stacked SR has Z, V and C clear (N too for these two).
    for (opcode, vector) in [(UInt16(0x4598), 6), (0x80D8, 5)] {
        let (cpu, memory) = try run([opcode]) { cpu, memory in
            cpu[address: 0] = 0x2000
            cpu[data: 2] = 0x4F0B
            cpu.statusRegister = 0x271F
            try memory.writeWord(opcode == 0x4598 ? 1 : 0, at: 0x2000)
            try memory.writeLong(0x3000, at: UInt32(vector * 4))
        }
        #expect(cpu.programCounter == 0x3000)
        #expect(cpu[address: 0] == 0x2002)
        var m = memory
        #expect(try m.readWord(at: 0x7FFA) == 0x2710)
        #expect(try m.readLong(at: 0x7FFC) == 0x102)
    }
}
