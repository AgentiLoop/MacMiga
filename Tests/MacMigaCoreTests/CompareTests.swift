import Testing
@testable import MacMigaCore

private func compareMemory(_ words: [UInt16], at address: UInt32 = 0x100) throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024))
    memory.setOverlay(enabled: false)
    for (offset, word) in words.enumerated() {
        try memory.writeWord(word, at: address &+ UInt32(offset * 2))
    }
    return memory
}

/// NZVC of destination - source computed with wide integers; X is never touched by compares.
private func compareFlags(_ destination: UInt32, _ source: UInt32, bits: Int) -> UInt16 {
    let mask = (Int64(1) << bits) - 1
    let d = Int64(destination) & mask, s = Int64(source) & mask
    func signed(_ v: Int64) -> Int64 { v >= (Int64(1) << (bits - 1)) ? v - (Int64(1) << bits) : v }
    let difference = signed(d) - signed(s)
    let result = (d - s) & mask
    var flags: UInt16 = 0
    if s > d { flags |= 0x01 }
    if difference < -(Int64(1) << (bits - 1)) || difference >= (Int64(1) << (bits - 1)) { flags |= 0x02 }
    if result == 0 { flags |= 0x04 }
    if signed(result) < 0 { flags |= 0x08 }
    return flags
}

@Test func cmpByteExhaustivePreservesOperandsAndX() throws {
    var memory = try compareMemory([0xB001]) // CMP.B D1,D0
    for destination in UInt32(0)...255 {
        for source in UInt32(0)...255 {
            for x: UInt16 in [0, 0x10] {
                var cpu = MC68000()
                cpu.programCounter = 0x100
                cpu.statusRegister = 0x2700 | x | 0x0F
                cpu[data: 0] = 0xAB00_0000 | destination
                cpu[data: 1] = 0x00CD_0000 | source
                var expected = cpu
                expected.statusRegister = 0x2700 | x | compareFlags(destination, source, bits: 8)
                expected.programCounter = 0x102
                try cpu.step(memory: &memory)
                #expect(cpu == expected)
            }
        }
    }
}

@Test func cmpWordLongAndCMPABoundaries() throws {
    let samples: [UInt32] = [0, 1, 0x7F, 0x80, 0x7FFF, 0x8000, 0xFFFF, 0x1_0000,
                             0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x1234_8000]
    // (opcode, source size bits, compare bits, sign-extend word source, address destination)
    let cases: [(UInt16, Int, Bool, Bool)] = [
        (0xB041, 16, false, false), // CMP.W D1,D0
        (0xB081, 32, false, false), // CMP.L D1,D0
        (0xB0C1, 32, true, true),   // CMPA.W D1,A0
        (0xB1C1, 32, false, true)   // CMPA.L D1,A0
    ]
    for (opcode, bits, extend, toAddress) in cases {
        var memory = try compareMemory([opcode])
        for destination in samples {
            for source in samples {
                var cpu = MC68000()
                cpu.programCounter = 0x100
                if toAddress { cpu[address: 0] = destination } else { cpu[data: 0] = destination }
                cpu[data: 1] = source
                let effectiveSource = extend ? UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: source)))) : source
                var expected = cpu
                expected.statusRegister = 0x2700 | compareFlags(destination, effectiveSource, bits: bits)
                expected.programCounter = 0x102
                try cpu.step(memory: &memory)
                #expect(cpu == expected)
            }
        }
    }
}

@Test func cmpaRegisterAndMemorySourcesAsKickstartUses() throws {
    // CMPA.L A1,A0 then CMP.L (A2)+,D3 then CMP.W #$1234,D4
    var memory = try compareMemory([0xB1C9, 0xB69A, 0xB87C, 0x1234])
    try memory.writeLong(0x8000_0000, at: 0x300)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[address: 0] = 0x400
    cpu[address: 1] = 0x400
    cpu[address: 2] = 0x300
    cpu[data: 3] = 0x7FFF_FFFF
    cpu[data: 4] = 0xFFFF_1234
    try cpu.step(memory: &memory)
    #expect(cpu.statusRegister == 0x2704)
    try cpu.step(memory: &memory)
    #expect(cpu[address: 2] == 0x304)
    #expect(cpu.statusRegister == 0x270B) // N, V, C
    try cpu.step(memory: &memory)
    #expect(cpu.statusRegister == 0x2704)
    #expect(cpu.programCounter == 0x108)
}

@Test func cmpiEverySizeAndMemoryDestination() throws {
    let cases: [(words: [UInt16], flags: UInt16, end: UInt32)] = [
        ([0x0C00, 0x00FF], 0x04, 0x104),               // CMPI.B #$FF,D0 (D0.B = $FF)
        ([0x0C40, 0x0100], 0x09, 0x104),               // CMPI.W #$100,D0 (D0.W = $00FF)
        ([0x0C80, 0x0000, 0x00FF], 0x04, 0x106),       // CMPI.L #$FF,D0
        ([0x0C51, 0x1111], 0x04, 0x104),               // CMPI.W #$1111,(A1)
        ([0x0C79, 0x1111, 0x0000, 0x0300], 0x04, 0x108), // CMPI.W #$1111,$300.L
        ([0x0C38, 0x0011, 0x0301], 0x04, 0x106)        // CMPI.B #$11,$301.W, byte from word extension
    ]
    for item in cases {
        var memory = try compareMemory(item.words)
        try memory.writeWord(0x1111, at: 0x300)
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu.statusRegister = 0x2710
        cpu[data: 0] = 0x0000_00FF
        cpu[address: 1] = 0x300
        try cpu.step(memory: &memory)
        #expect(cpu.statusRegister == 0x2710 | item.flags)
        #expect(cpu.programCounter == item.end)
        #expect(cpu[data: 0] == 0xFF)
    }
}

@Test func dbccCountsLowWordAndHonorsCondition() throws {
    // DBF D1,-2 loops to itself until D1.W wraps to -1; upper word is preserved.
    var memory = try compareMemory([0x51C9, 0xFFFE])
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[data: 1] = 0xABCD_0003
    for expected: UInt32 in [0xABCD_0002, 0xABCD_0001, 0xABCD_0000] {
        try cpu.step(memory: &memory)
        #expect(cpu[data: 1] == expected)
        #expect(cpu.programCounter == 0x100)
    }
    try cpu.step(memory: &memory)
    #expect(cpu[data: 1] == 0xABCD_FFFF)
    #expect(cpu.programCounter == 0x104)

    // DBEQ: a true condition exits without decrementing; a false one decrements and branches.
    for (status, counter, pc): (UInt16, UInt32, UInt32) in [(0x2704, 5, 0x104), (0x2700, 4, 0x110)] {
        var memory = try compareMemory([0x57C8, 0x000E])
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu.statusRegister = status
        cpu[data: 0] = 5
        try cpu.step(memory: &memory)
        #expect(cpu[data: 0] == counter)
        #expect(cpu.programCounter == pc)
        #expect(cpu.statusRegister == status)
    }

    // DBT never decrements.
    var always = try compareMemory([0x50C8, 0xFFFE])
    var t = MC68000()
    t.programCounter = 0x100
    t[data: 0] = 0
    try t.step(memory: &always)
    #expect(t[data: 0] == 0)
    #expect(t.programCounter == 0x104)
}

@Test func dbccDisplacementFetchFaultPreservesCPU() throws {
    var memory = try compareMemory([0x51C8], at: 0x1FFFFE)
    var cpu = MC68000()
    cpu.programCounter = 0x1FFFFE
    cpu[data: 0] = 7
    let before = cpu
    #expect(throws: MemoryBusError.unmappedAddress(0x200000)) { try cpu.step(memory: &memory) }
    #expect(cpu == before)
}

@Test func compareInvalidEncodingsAndFaultsPreserveCPU() throws {
    let invalid: [UInt16] = [
        0xB008, // CMP.B A0,D0
        0xB03D, // CMP.B mode 7/5
        0x0C48, // CMPI.W #,A0
        0x0C7A, // CMPI.W #,(d16,PC) is not data alterable on the 68000
        0x0C7C, // CMPI.W #,#
        0xB17C  // EOR.W D0,#imm
    ]
    for opcode in invalid {
        var memory = try compareMemory([opcode], at: 0x1FFFFE)
        var cpu = MC68000()
        cpu.programCounter = 0x1FFFFE
        cpu.stopsOnIllegalInstruction = true
        let before = cpu
        #expect(throws: CPUError.unsupportedInstruction(opcode: opcode, address: 0x1FFFFE)) {
            try cpu.step(memory: &memory)
        }
        #expect(cpu == before)
    }
    // CMP.L (A0)+,D0 at an unmapped address leaves A0 unchanged.
    var memory = try compareMemory([0xB098])
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[address: 0] = 0x200000
    let before = cpu
    #expect(throws: MemoryBusError.unmappedAddress(0x200000)) { try cpu.step(memory: &memory) }
    #expect(cpu == before)
}

@Test func compareAndDBccSyntheticSearchLoop() throws {
    // Find the first word equal to $BEEF within 8 words starting at $300.
    var memory = try compareMemory([
        0x41F8, 0x0300, // $100: LEA $300.W,A0
        0x7007,         // $104: MOVEQ #7,D0
        0x0C58, 0xBEEF, // $106: CMPI.W #$BEEF,(A0)+
        0x57C8, 0xFFFA  // $10A: DBEQ D0,$106
    ])
    try memory.writeWord(0xBEEF, at: 0x306)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    while cpu.programCounter != 0x10E { try cpu.step(memory: &memory) }
    #expect(cpu[address: 0] == 0x308)
    #expect(cpu[data: 0] == 4)
    #expect(cpu.statusRegister & 0x04 != 0)
}
