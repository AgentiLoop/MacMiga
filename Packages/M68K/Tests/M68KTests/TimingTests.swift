import Testing
import M68K

/// Runs one instruction at `$100` with A0–A6 = `$1000`, USP = `$4000`, SSP = `$8000`,
/// SR = `$2700` and all memory 0 (so every vector and every return address is 0), and returns
/// the CPU clocks `step` reports.
private func clocks(_ words: [UInt16], d0: UInt32 = 0, d1: UInt32 = 0, a0: UInt32 = 0x1000) throws -> Int {
    var memory = TestBus()
    for (offset, word) in words.enumerated() { try memory.writeWord(word, at: 0x100 + UInt32(offset * 2)) }
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu.supervisorStackPointer = 0x8000
    cpu.userStackPointer = 0x4000
    for register in 0..<7 { cpu[address: register] = 0x1000 }
    cpu[address: 0] = a0
    cpu[data: 0] = d0
    cpu[data: 1] = d1
    return try cpu.step(memory: &memory)
}

@Test func moveTakesFourClocksPlusItsOperands() throws {
    #expect(try clocks([0x3200]) == 4)                              // MOVE.W D0,D1
    #expect(try clocks([0x3210]) == 8)                              // MOVE.W (A0),D1
    #expect(try clocks([0x2210]) == 12)                             // MOVE.L (A0),D1
    #expect(try clocks([0x3220]) == 10)                             // MOVE.W -(A0),D1
    #expect(try clocks([0x3100]) == 8)                              // MOVE.W D0,-(A0): no extra 2
    #expect(try clocks([0x2100]) == 12)                             // MOVE.L D0,-(A0)
    #expect(try clocks([0x3230, 0x0000]) == 14)                     // MOVE.W 0(A0,D0.W),D1
    #expect(try clocks([0x33FC, 0x1234, 0x0000, 0x2000]) == 20)     // MOVE.W #$1234,$2000.L
    #expect(try clocks([0x23F9, 0x0000, 0x2000, 0x0000, 0x2004]) == 36) // MOVE.L $2000.L,$2004.L
    #expect(try clocks([0x7001]) == 4)                              // MOVEQ
    #expect(try clocks([0x48E7, 0xC000]) == 24)                     // MOVEM.L D0-D1,-(A7)
    #expect(try clocks([0x4CDF, 0x0003]) == 28)                     // MOVEM.L (A7)+,D0-D1
    #expect(try clocks([0x4CA8, 0x0001, 0x0000]) == 20)             // MOVEM.W 0(A0),D0
    #expect(try clocks([0x0188, 0x0000]) == 16)                     // MOVEP.W D0,0(A0)
    #expect(try clocks([0x01C8, 0x0000]) == 24)                     // MOVEP.L D0,0(A0)
}

@Test func arithmeticAndLogicTimes() throws {
    #expect(try clocks([0xD240]) == 4)          // ADD.W D0,D1
    #expect(try clocks([0xD280]) == 8)          // ADD.L D0,D1: 8 for a register source
    #expect(try clocks([0xD290]) == 14)         // ADD.L (A0),D1: 6 + 8
    #expect(try clocks([0xD350]) == 12)         // ADD.W D1,(A0)
    #expect(try clocks([0xD390]) == 20)         // ADD.L D1,(A0)
    #expect(try clocks([0xD2C0]) == 8)          // ADDA.W D0,A1
    #expect(try clocks([0xD3D0]) == 14)         // ADDA.L (A0),A1
    #expect(try clocks([0x5240]) == 4)          // ADDQ.W #1,D0
    #expect(try clocks([0x5280]) == 8)          // ADDQ.L #1,D0
    #expect(try clocks([0x5248]) == 8)          // ADDQ.W #1,A0
    #expect(try clocks([0x5288]) == 8)          // ADDQ.L #1,A0
    #expect(try clocks([0x5290]) == 20)         // ADDQ.L #1,(A0)
    #expect(try clocks([0x0640, 0x0001]) == 8)  // ADDI.W #1,D0
    #expect(try clocks([0x0680, 0x0000, 0x0001]) == 16) // ADDI.L #1,D0
    #expect(try clocks([0x0650, 0x0001]) == 16) // ADDI.W #1,(A0)
    #expect(try clocks([0xD380]) == 8)          // ADDX.L D0,D1
    #expect(try clocks([0xD388]) == 30)         // ADDX.L -(A0),-(A1)
    #expect(try clocks([0xC300]) == 6)          // ABCD D0,D1
    #expect(try clocks([0xC308]) == 18)         // ABCD -(A0),-(A1)
    #expect(try clocks([0xB240]) == 4)          // CMP.W D0,D1
    #expect(try clocks([0xB280]) == 6)          // CMP.L D0,D1
    #expect(try clocks([0xB2C0]) == 6)          // CMPA.W D0,A1
    #expect(try clocks([0x0C80, 0x0000, 0x0001]) == 14) // CMPI.L #1,D0
    #expect(try clocks([0xB348]) == 12)         // CMPM.W (A0)+,(A1)+
    #expect(try clocks([0xB388]) == 20)         // CMPM.L (A0)+,(A1)+
    #expect(try clocks([0xC240]) == 4)          // AND.W D0,D1
    #expect(try clocks([0xB380]) == 8)          // EOR.L D1,D0
    #expect(try clocks([0x4240]) == 4)          // CLR.W D0
    #expect(try clocks([0x4280]) == 6)          // CLR.L D0
    #expect(try clocks([0x4290]) == 20)         // CLR.L (A0)
    #expect(try clocks([0x4A50]) == 8)          // TST.W (A0)
    #expect(try clocks([0x4AC0]) == 4)          // TAS D0
    #expect(try clocks([0x4AD0]) == 14)         // TAS (A0)
    #expect(try clocks([0x4800]) == 6)          // NBCD D0
    #expect(try clocks([0x50C0]) == 6)          // ST D0
    #expect(try clocks([0x51C0]) == 4)          // SF D0
    #expect(try clocks([0x50D0]) == 12)         // ST (A0)
    #expect(try clocks([0xC141]) == 6)          // EXG D0,D1
    #expect(try clocks([0x4880]) == 4)          // EXT.W D0
    #expect(try clocks([0x4840]) == 4)          // SWAP D0
}

@Test func bitAndShiftTimesDependOnTheBitAndTheCount() throws {
    #expect(try clocks([0x0300]) == 6)                  // BTST D1,D0
    #expect(try clocks([0x0801, 0x0000]) == 10)         // BTST #0,D1
    #expect(try clocks([0x013C, 0x0000]) == 10)         // BTST D0,#0
    #expect(try clocks([0x0310]) == 8)                  // BTST D1,(A0)
    #expect(try clocks([0x0141]) == 6)                  // BCHG D0,D1, bit 0
    #expect(try clocks([0x0141], d0: 16) == 8)          // BCHG D0,D1, bit 16
    #expect(try clocks([0x0181]) == 8)                  // BCLR D0,D1, bit 0
    #expect(try clocks([0x0181], d0: 31) == 10)         // BCLR D0,D1, bit 31
    #expect(try clocks([0x08D0, 0x0000]) == 16)         // BSET #0,(A0)
    #expect(try clocks([0xE348]) == 8)                  // LSL.W #1,D0
    #expect(try clocks([0xE188]) == 24)                 // LSL.L #8,D0
    #expect(try clocks([0xE368]) == 6)                  // LSL.W D1,D0 by 0
    #expect(try clocks([0xE3A8], d1: 59) == 126)        // LSL.L D1,D0 by 59
    #expect(try clocks([0xE3D0]) == 12)                 // LSL (A0)
}

@Test func multiplyAndDivideTimesDependOnTheOperands() throws {
    #expect(try clocks([0xC2C0]) == 38)                         // MULU D0,D1 by 0
    #expect(try clocks([0xC2C0], d0: 0xFFFF) == 70)             // MULU: 2 for each 1
    #expect(try clocks([0xC3C0], d0: 0xFFFF) == 40)             // MULS: one change, between bit 0 and the 0 appended
    #expect(try clocks([0xC3C0], d0: 0x5555) == 70)             // MULS: 16 changes
    #expect(try clocks([0xC2D0]) == 42)                         // MULU (A0),D1
    #expect(try clocks([0x82C0], d0: 1, d1: 0x0001_0000) == 10) // DIVU overflow
    #expect(try clocks([0x82C0], d0: 1) == 136)                 // DIVU 0 / 1: the longest
    #expect(try clocks([0x82C0], d0: 1, d1: 0xFFFF) == 106)     // DIVU $FFFF / 1: a 1 in the quotient is 2 shorter
    #expect(try clocks([0x82C0], d0: 0xFFFF, d1: 0xFFFE_0001) == 76) // DIVU: the shortest
    #expect(try clocks([0x83C0], d0: 1, d1: 0x0001_0000) == 16) // DIVS overflow seen at once
    #expect(try clocks([0x83C0], d0: 1, d1: 0xFFFF_0000) == 18) // the same with a negative dividend
    #expect(try clocks([0x83C0], d0: 2, d1: 0x0001_8000) == 146) // DIVS overflow found after dividing
    #expect(try clocks([0x83C0], d0: 1) == 150)                 // DIVS 0 / 1
    #expect(try clocks([0x83C0], d0: 1, d1: 0xFFFF_FFFF) == 156) // DIVS -1 / 1: the longest
}

@Test func branchAndControlTimes() throws {
    #expect(try clocks([0x4E71]) == 4)                  // NOP
    #expect(try clocks([0x6002]) == 10)                 // BRA.S
    #expect(try clocks([0x6602]) == 10)                 // BNE.S, taken
    #expect(try clocks([0x6702]) == 8)                  // BEQ.S, not taken
    #expect(try clocks([0x6700, 0x0004]) == 12)         // BEQ.W, not taken
    #expect(try clocks([0x6102]) == 18)                 // BSR.S
    #expect(try clocks([0x50C8, 0xFFFE]) == 12)         // DBT: condition true
    #expect(try clocks([0x51C8, 0xFFFE], d0: 1) == 10)  // DBF: branches
    #expect(try clocks([0x51C8, 0xFFFE]) == 14)         // DBF: counter expired
    #expect(try clocks([0x43D0]) == 4)                  // LEA (A0),A1
    #expect(try clocks([0x43E8, 0x0000]) == 8)          // LEA 0(A0),A1
    #expect(try clocks([0x43F0, 0x0000]) == 12)         // LEA 0(A0,D0.W),A1
    #expect(try clocks([0x4850]) == 12)                 // PEA (A0)
    #expect(try clocks([0x4ED0]) == 8)                  // JMP (A0)
    #expect(try clocks([0x4EE8, 0x0000]) == 10)         // JMP 0(A0)
    #expect(try clocks([0x4EF0, 0x0000]) == 14)         // JMP 0(A0,D0.W)
    #expect(try clocks([0x4EF9, 0x0000, 0x2000]) == 12) // JMP $2000.L
    #expect(try clocks([0x4E90]) == 16)                 // JSR (A0)
    #expect(try clocks([0x4EB9, 0x0000, 0x2000]) == 20) // JSR $2000.L
    #expect(try clocks([0x4E75]) == 16)                 // RTS
    #expect(try clocks([0x4E73]) == 20)                 // RTE
    #expect(try clocks([0x4E77]) == 20)                 // RTR
    #expect(try clocks([0x4E56, 0x0000]) == 16)         // LINK A6,#0
    #expect(try clocks([0x4E5E]) == 12)                 // UNLK A6
    #expect(try clocks([0x40C0]) == 6)                  // MOVE SR,D0
    #expect(try clocks([0x44C0]) == 12)                 // MOVE D0,CCR
    #expect(try clocks([0x46FC, 0x2700]) == 16)         // MOVE #$2700,SR
    #expect(try clocks([0x003C, 0x0000]) == 20)         // ORI #0,CCR
    #expect(try clocks([0x4E68]) == 4)                  // MOVE USP,A0
    #expect(try clocks([0x4E72, 0x2700]) == 4)          // STOP
    #expect(try clocks([0x4E70]) == 132)                // RESET
}

@Test func exceptionTimes() throws {
    #expect(try clocks([0x4E40]) == 34)                         // TRAP #0
    #expect(try clocks([0x4AFC]) == 34)                         // ILLEGAL
    #expect(try clocks([0xA000]) == 34)                         // line A
    #expect(try clocks([0x4E76]) == 4)                          // TRAPV, V clear
    #expect(try clocks([0x4380], d0: 5, d1: 3) == 10)           // CHK D0,D1 within bounds
    #expect(try clocks([0x4380], d0: 5, d1: 6) == 38)           // above the bound
    #expect(try clocks([0x4380], d0: 5, d1: 0xFFFF) == 40)      // negative: tested second
    #expect(try clocks([0x4380], d0: 0x7FFF, d1: 0x8000) == 38) // negative, and bound - register overflows
    #expect(try clocks([0x4390], d1: 1) == 42)                  // CHK (A0),D1 above a bound of 0
    #expect(try clocks([0x82C0]) == 38)                         // DIVU D0,D1 by zero
    #expect(try clocks([0x82D0]) == 42)                         // DIVU (A0),D1 by zero
    #expect(try clocks([0x3010], a0: 0x1001) == 50)             // address error
}

@Test func aStoppedCPUTakesNoClocksAndTheCounterStaysOutOfComparisons() throws {
    var memory = TestBus()
    try memory.writeWord(0x4E72, at: 0x100) // STOP #$2700
    try memory.writeWord(0x2700, at: 0x102)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    #expect(try cpu.step(memory: &memory) == 4)
    #expect(cpu.isStopped)
    let stopped = cpu
    #expect(try cpu.step(memory: &memory) == 0)
    #expect(cpu == stopped)
    #expect(MC68000.interruptClocks == 44)
}
