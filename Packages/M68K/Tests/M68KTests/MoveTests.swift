import Testing
import M68K

private func moveMemory(_ words: [UInt16]) throws -> TestBus {
    var memory = TestBus()
    for (index, word) in words.enumerated() {
        try memory.writeWord(word, at: 0x100 + UInt32(index * 2))
    }
    return memory
}

@Test func moveRegisterSizesFlagsAndPreservedBits() throws {
    var memory = try moveMemory([])
    for (prefix, mask, sign): (UInt16, UInt32, UInt32) in [
        (0x1000, 0xFF, 0x80), (0x3000, 0xFFFF, 0x8000), (0x2000, 0xFFFF_FFFF, 0x8000_0000)
    ] {
        for source in 0..<8 {
            for destination in 0..<8 {
                for value in [UInt32(0), 1, sign, mask, ~mask] {
                    for extend: UInt16 in [0, 0x10] {
                        var cpu = MC68000()
                        cpu.programCounter = 0x100
                        cpu.statusRegister = 0xA70F | extend
                        cpu[data: destination] = 0xA5A5_A5A5
                        cpu[data: source] = value
                        var expected = cpu
                        let result = value & mask
                        expected[data: destination] = (cpu[data: destination] & ~mask) | result
                        expected.statusRegister = 0xA700 | extend | (result == 0 ? 4 : result & sign != 0 ? 8 : 0)
                        expected.programCounter = 0x102
                        try memory.writeWord(prefix | UInt16(destination << 9) | UInt16(source), at: 0x100)
                        try cpu.step(memory: &memory)
                        #expect(cpu == expected)
                    }
                }
            }
        }
    }
}

@Test func moveWordReadsEverySourceAddressingMode() throws {
    // All cases read $8001 into D0, preserving its upper word.
    let cases: [(UInt16, [UInt16], UInt32)] = [
        (0x3010, [], 0x300), (0x3018, [], 0x300), (0x3020, [], 0x2FE),
        (0x3028, [0xFFFC], 0x2FC), (0x3030, [0x10FE], 0x302),
        (0x3038, [0x0300], 0x300), (0x3039, [0xAB00, 0x0300], 0x300),
        (0x303A, [0xFFFC], 0xFE), (0x303B, [0x10FE], 0x104)
    ]
    for (opcode, extensions, target) in cases {
        var memory = try moveMemory([opcode] + extensions)
        try memory.writeWord(0x8001, at: target)
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu[address: 0] = 0x300
        cpu[data: 0] = 0x1234_5678
        cpu[data: 1] = 4
        cpu.statusRegister = 0x271F
        try cpu.step(memory: &memory)
        #expect(cpu[data: 0] == 0x1234_8001)
        #expect(cpu.statusRegister == 0x2718)
        #expect(cpu.programCounter == 0x102 + UInt32(extensions.count * 2))
        #expect(cpu[address: 0] == (opcode == 0x3018 ? 0x302 : opcode == 0x3020 ? 0x2FE : 0x300))
    }
}

@Test func moveImmediateToEveryMemoryDestination() throws {
    for (prefix, size, immediate): (UInt16, Int, [UInt16]) in [
        (0x1000, 1, [0xAB80]), (0x3000, 2, [0x8001]), (0x2000, 4, [0x8001, 0x2345])
    ] {
        for (mode, register, extensions, target): (Int, Int, [UInt16], UInt32) in [
            (2, 0, [], 0x300), (3, 0, [], 0x300), (4, 0, [], 0x300 - UInt32(size)),
            (5, 0, [0xFFFC], 0x2FC), (6, 0, [0x10FE], 0x302),
            (7, 0, [0x0300], 0x300), (7, 1, [0xAB00, 0x0300], 0x300)
        ] {
            let opcode = prefix | UInt16(register << 9) | UInt16(mode << 6) | 0x3C
            var memory = try moveMemory([opcode] + immediate + extensions)
            var cpu = MC68000()
            cpu.programCounter = 0x100
            cpu[address: 0] = 0x300
            cpu[data: 1] = 4
            cpu.statusRegister = 0x271F
            try cpu.step(memory: &memory)
            switch size {
            case 1: #expect(try memory.readByte(at: target) == 0x80)
            case 2: #expect(try memory.readWord(at: target) == 0x8001)
            default: #expect(try memory.readLong(at: target) == 0x8001_2345)
            }
            #expect(cpu.statusRegister == 0x2718)
            #expect(cpu.programCounter == 0x102 + UInt32((immediate.count + extensions.count) * 2))
            #expect(cpu[address: 0] == (mode == 3 ? 0x300 + UInt32(size) : mode == 4 ? target : 0x300))
        }
    }
}

@Test func moveAddressSignExtensionAndUnchangedStatus() throws {
    var memory = try moveMemory([])
    for register in 0..<8 {
        for value: UInt16 in [0, 0x7FFF, 0x8000, 0xFFFF] {
            for supervisor: UInt16 in [0, 0x2000] {
                try memory.writeWord(0x307C | UInt16(register << 9), at: 0x100)
                try memory.writeWord(value, at: 0x102)
                var cpu = MC68000()
                cpu.programCounter = 0x100
                cpu.statusRegister = supervisor | 0x801F
                var expected = cpu
                expected[address: register] = UInt32(bitPattern: Int32(Int16(bitPattern: value)))
                expected.programCounter = 0x104
                try cpu.step(memory: &memory)
                #expect(cpu == expected)
            }
        }
    }
    // MOVEA.L A1,A0; MOVE.W A0,D0; MOVE.L A0,D1.
    memory = try moveMemory([0x2049, 0x3008, 0x2208])
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[address: 1] = 0x8765_4321
    cpu.statusRegister = 0x271F
    try cpu.step(memory: &memory)
    #expect(cpu[address: 0] == 0x8765_4321)
    #expect(cpu.statusRegister == 0x271F)
    try cpu.step(memory: &memory)
    #expect(cpu[data: 0] == 0x4321)
    try cpu.step(memory: &memory)
    #expect(cpu[data: 1] == 0x8765_4321)
}

@Test func moveIndexedWordLongDataAddressAndReservedBits() throws {
    for pcRelative in [false, true] {
        for addressIndex in [false, true] {
            for longIndex in [false, true] {
                for register in 0..<8 {
                    for reserved: UInt16 in [0, 0x0700] {
                        let extensionWord = UInt16(register << 12) | (addressIndex ? 0x8000 : 0)
                            | (longIndex ? 0x0800 : 0) | reserved | 0xFE
                        var memory = try moveMemory([pcRelative ? 0x303B : 0x3030, extensionWord])
                        var cpu = MC68000()
                        cpu.programCounter = 0x100
                        cpu[address: 0] = 0x300
                        let index: UInt32 = longIndex ? 0xFFFF_FFFC : 0x1234_FFFC
                        if addressIndex { cpu[address: register] = index }
                        else { cpu[data: register] = index }
                        // If A0 is also the index, its new value is both base and index.
                        let base: UInt32 = pcRelative ? 0x102 : cpu[address: 0]
                        let target = base &- 6
                        // The A0 alias can resolve to ROM or an unmapped region; test it separately below.
                        if !pcRelative && addressIndex && register == 0 { continue }
                        try memory.writeWord(0x4321, at: target)
                        try cpu.step(memory: &memory)
                        #expect(cpu[data: 0] & 0xFFFF == 0x4321)
                        #expect(cpu.programCounter == 0x104)
                    }
                }
            }
        }
    }
    var memory = try moveMemory([0x3030, 0x88FC]) // MOVE.W (-4,A0,A0.L),D0
    try memory.writeWord(0x4321, at: 0x5FC)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[address: 0] = 0x300
    try cpu.step(memory: &memory)
    #expect(cpu[data: 0] == 0x4321)
}

@Test func moveStackByteStrideAndSharedRegisterOrdering() throws {
    for supervisor: UInt16 in [0, 0x2000] {
        var memory = try moveMemory([0x1EDF, 0x1F27]) // (A7)+,(A7)+ then -(A7),-(A7)
        try memory.writeByte(0x80, at: 0x300)
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu.statusRegister = supervisor
        cpu[address: 7] = 0x300
        try cpu.step(memory: &memory)
        #expect(cpu[address: 7] == 0x304)
        #expect(try memory.readByte(at: 0x302) == 0x80)
        #expect(try memory.readByte(at: 0x301) == 0)
        try cpu.step(memory: &memory)
        #expect(cpu[address: 7] == 0x300)
        #expect(try memory.readByte(at: 0x300) == 0x80)
    }
    var memory = try moveMemory([0x20D8, 0x2058]) // MOVE.L (A0)+,(A0)+; MOVEA.L (A0)+,A0
    try memory.writeLong(0x1234_5678, at: 0x300)
    try memory.writeLong(0xABCD_EF00, at: 0x308)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[address: 0] = 0x300
    try cpu.step(memory: &memory)
    #expect(cpu[address: 0] == 0x308)
    #expect(try memory.readLong(at: 0x304) == 0x1234_5678)
    try cpu.step(memory: &memory)
    #expect(cpu[address: 0] == 0xABCD_EF00)
}

@Test func moveAbsoluteShortSignExtensionAndROMProtection() throws {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom[0x3FFFC] = 0x80
    rom[0x3FFFD] = 0x01
    var memory = TestBus(rom: rom)
    // MOVE.W ($FFFC).W,D0; MOVE.W D0,($FFFC).W.
    for (offset, word): (UInt32, UInt16) in [(0, 0x3038), (2, 0xFFFC), (4, 0x31C0), (6, 0xFFFC)] {
        try memory.writeWord(word, at: 0x100 + offset)
    }
    var cpu = MC68000()
    cpu.programCounter = 0x100
    try cpu.step(memory: &memory)
    #expect(cpu[data: 0] == 0x8001)
    cpu[data: 0] = 0
    try cpu.step(memory: &memory)
    #expect(try memory.readWord(at: 0xFFFF_FFFC) == 0x8001)
    #expect(cpu.statusRegister & 15 == 4)
}

@Test func moveInvalidEncodingsFailBeforeSideEffects() throws {
    var memory = try moveMemory([])
    for opcode: UInt16 in 0x1000...0x3FFF {
        let byte = opcode >> 12 == 1
        let sm = (opcode >> 3) & 7, sr = opcode & 7
        let dm = (opcode >> 6) & 7, dr = (opcode >> 9) & 7
        let invalid = (byte && (sm == 1 || dm == 1)) || (sm == 7 && sr > 4) || (dm == 7 && dr > 1)
        if !invalid { continue }
        try memory.writeWord(opcode, at: 0x100)
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu.stopsOnIllegalInstruction = true
        let before = cpu
        #expect(throws: CPUError.unsupportedInstruction(opcode: opcode, address: 0x100)) {
            try cpu.step(memory: &memory)
        }
        #expect(cpu == before)
    }
}

@Test func moveFaultsPreserveCPUAndExposePartialBusWrites() throws {
    // Invalid source read, invalid destination write, and missing destination extension.
    for (opcode, source, destination): (UInt16, UInt32, UInt32) in [
        (0x2218, 0x200000, 0), (0x2218, 0x301, 0), (0x2298, 0x300, 0x200000)
    ] {
        var memory = try moveMemory([opcode])
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu[address: 0] = source
        cpu.stopsOnAddressError = true
        cpu[address: 1] = destination
        let before = cpu
        #expect(throws: (any Error).self) { try cpu.step(memory: &memory) }
        #expect(cpu == before)
    }
    var memory = try moveMemory([])
    try memory.writeWord(0x23D8, at: 0x1FFFFE) // MOVE.L (A0)+,absolute.L (extension unavailable)
    var cpu = MC68000()
    cpu.programCounter = 0x1FFFFE
    cpu[address: 0] = 0x300
    var before = cpu
    #expect(throws: TestBus.Fault.unmapped(0x200000)) { try cpu.step(memory: &memory) }
    #expect(cpu == before)
    try memory.writeWord(0x20C0, at: 0x100) // MOVE.L D0,(A0)+ crosses RAM boundary.
    cpu.programCounter = 0x100
    cpu[address: 0] = 0x1FFFFE
    cpu[data: 0] = 0x1234_5678
    before = cpu
    #expect(throws: TestBus.Fault.unmapped(0x200000)) { try cpu.step(memory: &memory) }
    #expect(cpu == before)
    #expect(try memory.readWord(at: 0x1FFFFE) == 0x1234)
}

@Test func moveSyntheticCopyProgram() throws {
    // Set source/destination pointers, copy two longwords, then load copied data into D0/D1.
    var memory = try moveMemory([0x207C, 0, 0x300, 0x227C, 0, 0x400,
                                 0x22D8, 0x22D8, 0x2039, 0, 0x400, 0x2239, 0, 0x404])
    try memory.writeLong(0x0123_4567, at: 0x300)
    try memory.writeLong(0x89AB_CDEF, at: 0x304)
    var cpu = MC68000()
    cpu.programCounter = 0x100
    for _ in 0..<6 { try cpu.step(memory: &memory) }
    #expect(cpu[data: 0] == 0x0123_4567)
    #expect(cpu[data: 1] == 0x89AB_CDEF)
    #expect(cpu[address: 0] == 0x308)
    #expect(cpu[address: 1] == 0x408)
    #expect(cpu.programCounter == 0x11C)
}
