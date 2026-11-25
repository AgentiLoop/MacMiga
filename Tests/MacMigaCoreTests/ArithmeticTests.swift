import Testing
@testable import MacMigaCore

private func arithmeticMemory(_ words: [UInt16], at address: UInt32 = 0x100) throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024))
    memory.setOverlay(enabled: false)
    for (offset, word) in words.enumerated() {
        try memory.writeWord(word, at: address &+ UInt32(offset * 2))
    }
    return memory
}

/// Reference flags computed with wide signed/unsigned integers, independent of the CPU's bit tricks.
private func referenceFlags(_ destination: UInt32, _ source: UInt32, size: Int, subtract: Bool) -> (UInt32, UInt16) {
    let bits = size * 8
    let mask = (Int64(1) << bits) - 1
    let d = Int64(destination) & mask, s = Int64(source) & mask
    func signed(_ v: Int64) -> Int64 { v >= (Int64(1) << (bits - 1)) ? v - (Int64(1) << bits) : v }
    let unsigned = subtract ? d - s : d + s
    let signedResult = subtract ? signed(d) - signed(s) : signed(d) + signed(s)
    let result = unsigned & mask
    var flags: UInt16 = 0
    if unsigned < 0 || unsigned > mask { flags |= 0x11 }
    if signedResult < -(Int64(1) << (bits - 1)) || signedResult >= (Int64(1) << (bits - 1)) { flags |= 0x02 }
    if result == 0 { flags |= 0x04 }
    if signed(result) < 0 { flags |= 0x08 }
    return (UInt32(result), flags)
}

@Test func addSubByteExhaustiveFlagsAndPreservedBits() throws {
    for (opcode, subtract): (UInt16, Bool) in [(0xD001, false), (0x9001, true)] { // ADD.B/SUB.B D1,D0
        var memory = try arithmeticMemory([opcode])
        for destination in UInt32(0)...255 {
            for source in UInt32(0)...255 {
                var cpu = MC68000()
                cpu.programCounter = 0x100
                cpu.statusRegister = 0x2700 | (destination & 1 == 0 ? 0x1F : 0)
                cpu[data: 0] = 0xA5C3_E700 | destination
                cpu[data: 1] = 0x1234_5600 | source
                try cpu.step(memory: &memory)
                let (result, flags) = referenceFlags(destination, source, size: 1, subtract: subtract)
                #expect(cpu[data: 0] == 0xA5C3_E700 | result)
                #expect(cpu[data: 1] == 0x1234_5600 | source)
                #expect(cpu.statusRegister == 0x2700 | flags)
                #expect(cpu.programCounter == 0x102)
            }
        }
    }
}

@Test func addSubWordAndLongBoundaries() throws {
    let samples: [UInt32] = [0, 1, 2, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x1_0000,
                             0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_FFFE, 0xFFFF_FFFF, 0x1234_5678]
    let cases: [(UInt16, Int, Bool)] = [(0xD041, 2, false), (0xD081, 4, false), (0x9041, 2, true), (0x9081, 4, true)]
    for (opcode, size, subtract) in cases {
        var memory = try arithmeticMemory([opcode])
        let mask: UInt32 = size == 2 ? 0xFFFF : 0xFFFF_FFFF
        for destination in samples {
            for source in samples {
                var cpu = MC68000()
                cpu.programCounter = 0x100
                cpu[data: 0] = destination
                cpu[data: 1] = source
                try cpu.step(memory: &memory)
                let (result, flags) = referenceFlags(destination, source, size: size, subtract: subtract)
                #expect(cpu[data: 0] == (destination & ~mask) | result)
                #expect(cpu.statusRegister == 0x2700 | flags)
            }
        }
    }
}

@Test func quickFormsEveryDataValueAndSize() throws {
    for subtract in [false, true] {
        for data in UInt32(1)...8 {
            for (sizeCode, size) in [(0, 1), (1, 2), (2, 4)] {
                let opcode = UInt16(0x5000) | UInt16(data % 8) << 9 | (subtract ? 0x100 : 0)
                    | UInt16(sizeCode) << 6 | 3 // Dn = D3
                var memory = try arithmeticMemory([opcode])
                for start: UInt32 in [0, 0xFFFF_FFFF, 0x8000_0003, 0x7FFF_FFFC] {
                    var cpu = MC68000()
                    cpu.programCounter = 0x100
                    cpu[data: 3] = start
                    try cpu.step(memory: &memory)
                    let mask: UInt32 = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
                    let (result, flags) = referenceFlags(start, data, size: size, subtract: subtract)
                    #expect(cpu[data: 3] == (start & ~mask) | result)
                    #expect(cpu.statusRegister == 0x2700 | flags)
                    #expect(cpu.programCounter == 0x102)
                }
            }
        }
    }
}

@Test func addressDestinationsUseFull32BitsAndPreserveFlags() throws {
    let cases: [(words: [UInt16], a0: UInt32, d1: UInt32, expected: UInt32)] = [
        ([0x5248], 0x0000_FFFF, 0, 0x0001_0000),          // ADDQ.W #1,A0 acts on all 32 bits
        ([0x5188], 0x0000_0004, 0, 0xFFFF_FFFC),          // SUBQ.L #8,A0
        ([0xD0C1], 0x0001_0000, 0x1234_8000, 0x0000_8000), // ADDA.W D1,A0 sign-extends $8000
        ([0x90C1], 0x0001_0000, 0x0000_7FFF, 0x0000_8001), // SUBA.W D1,A0
        ([0xD1C1], 0xFFFF_FFFF, 0x0000_0001, 0x0000_0000), // ADDA.L D1,A0
        ([0x91C1], 0x0000_0000, 0x0000_0001, 0xFFFF_FFFF), // SUBA.L D1,A0
        ([0xD0FC, 0xFFFE], 0x100, 0, 0xFE)                 // ADDA.W #-2,A0
    ]
    for item in cases {
        for flags: UInt16 in [0, 0x1F] {
            var memory = try arithmeticMemory(item.words)
            var cpu = MC68000()
            cpu.programCounter = 0x100
            cpu.statusRegister = 0x2700 | flags
            cpu[address: 0] = item.a0
            cpu[data: 1] = item.d1
            try cpu.step(memory: &memory)
            #expect(cpu[address: 0] == item.expected)
            #expect(cpu.statusRegister == 0x2700 | flags)
            #expect(cpu.programCounter == 0x100 + UInt32(item.words.count * 2))
        }
    }
    // SUBQ.L #8,A7 adjusts only the active stack pointer.
    var memory = try arithmeticMemory([0x518F])
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu.userStackPointer = 0x800
    cpu.supervisorStackPointer = 0x900
    try cpu.step(memory: &memory)
    #expect(cpu.supervisorStackPointer == 0x8F8)
    #expect(cpu.userStackPointer == 0x800)
}

@Test func memoryOperandsReadModifyWriteAndUpdateRegisters() throws {
    var memory = try arithmeticMemory([
        0xD198,         // ADD.L D0,(A0)+
        0x9361,         // SUB.W D1,-(A1)
        0x5212,         // ADDQ.B #1,(A2)
        0xDA9B,         // ADD.L (A3)+,D5
        0xD07C, 0x1234, // ADD.W #$1234,D0
        0xD4BA, 0xFFF2  // ADD.L -14(PC),D2 -> reads the longword at $100
    ])
    try memory.writeLong(0x7FFF_FFFF, at: 0x300)
    try memory.writeWord(0, at: 0x400)
    try memory.writeByte(0xFF, at: 0x500)
    try memory.writeLong(0x10, at: 0x600)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[data: 0] = 1
    cpu[data: 1] = 1
    cpu[data: 5] = 0xFFFF_FFF0
    cpu[address: 0] = 0x300
    cpu[address: 1] = 0x402
    cpu[address: 2] = 0x500
    cpu[address: 3] = 0x600

    try cpu.step(memory: &memory)
    #expect(try memory.readLong(at: 0x300) == 0x8000_0000)
    #expect(cpu[address: 0] == 0x304)
    #expect(cpu.statusRegister == 0x270A) // N and V

    try cpu.step(memory: &memory)
    #expect(try memory.readWord(at: 0x400) == 0xFFFF)
    #expect(cpu[address: 1] == 0x400)
    #expect(cpu.statusRegister == 0x2719) // X, N, C

    try cpu.step(memory: &memory)
    #expect(try memory.readByte(at: 0x500) == 0)
    #expect(cpu.statusRegister == 0x2715) // X, Z, C

    try cpu.step(memory: &memory)
    #expect(cpu[data: 5] == 0)
    #expect(cpu[address: 3] == 0x604)
    #expect(cpu.statusRegister == 0x2715)

    try cpu.step(memory: &memory)
    #expect(cpu[data: 0] == 0x1235)
    #expect(cpu.statusRegister == 0x2700)

    try cpu.step(memory: &memory)
    #expect(cpu[data: 2] == 0xD198_9361)
    #expect(cpu.programCounter == 0x110)
}

@Test func arithmeticInvalidEncodingsFailBeforeSideEffects() throws {
    let invalid: [UInt16] = [
        0xD008, // ADD.B A0,D0
        0xD13C, // ADD.B D0,#imm
        0x917C, // SUB.W D0,#imm
        0xD17C, // ADD.W D0,#imm
        0xD17A, // ADD.W D0,(d16,PC)
        0x907D, // SUB.W mode 7/5
        0x5208, // ADDQ.B #1,A0
        0x527A, // ADDQ.W #1,(d16,PC)
        0x537C  // SUBQ.W #1,#imm
    ]
    for opcode in invalid {
        var memory = try arithmeticMemory([opcode], at: 0x1FFFFE)
        var cpu = MC68000()
        cpu.programCounter = 0x1FFFFE
        for index in 0..<8 { cpu[address: index] = 0x400; cpu[data: index] = 0x55 }
        let before = cpu
        #expect(throws: CPUError.unsupportedInstruction(opcode: opcode, address: 0x1FFFFE)) {
            try cpu.step(memory: &memory)
        }
        #expect(cpu == before)
    }
}

@Test func arithmeticFaultsPreserveCPU() throws {
    let cases: [(UInt16, MemoryBusError)] = [
        (0xD190, .unmappedAddress(0x200000)), // ADD.L D0,(A0)
        (0x9098, .unmappedAddress(0x200000)), // SUB.L (A0)+,D0: A0 not incremented on fault
        (0x5290, .unmappedAddress(0x200000))  // ADDQ.L #1,(A0)
    ]
    for (opcode, error) in cases {
        var memory = try arithmeticMemory([opcode])
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu[address: 0] = 0x200000
        let before = cpu
        #expect(throws: error) { try cpu.step(memory: &memory) }
        #expect(cpu == before)
    }
    // Odd word operand address.
    var memory = try arithmeticMemory([0xD150]) // ADD.W D0,(A0)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[address: 0] = 0x301
    let before = cpu
    #expect(throws: MemoryBusError.unalignedAddress(0x301)) { try cpu.step(memory: &memory) }
    #expect(cpu == before)
}

@Test func arithmeticSyntheticCountdownLoop() throws {
    var memory = try arithmeticMemory([
        0x7005, // $100: MOVEQ #5,D0
        0x5481, // $102: ADDQ.L #2,D1
        0x5380, // $104: SUBQ.L #1,D0
        0x6EFA  // $106: BGT $102
    ])
    var cpu = MC68000()
    cpu.programCounter = 0x100
    for _ in 0..<16 { try cpu.step(memory: &memory) }
    #expect(cpu[data: 0] == 0)
    #expect(cpu[data: 1] == 10)
    #expect(cpu.programCounter == 0x108)
    #expect(cpu.statusRegister & 0x1F == 0x04)
}
