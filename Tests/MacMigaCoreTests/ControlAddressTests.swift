import Testing
@testable import MacMigaCore

private func controlMemory(_ words: [UInt16], at address: UInt32 = 0x100) throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024))
    memory.setOverlay(enabled: false)
    for (offset, word) in words.enumerated() {
        try memory.writeWord(word, at: address &+ UInt32(offset * 2))
    }
    return memory
}

@Test func controlInstructionsEveryModeAndCCR() throws {
    let cases: [(ea: UInt16, extensions: [UInt16], target: UInt32)] = [
        (0x10, [], 0x300),                       // (A0)
        (0x28, [0xFFF0], 0x2F0),                // -16(A0)
        (0x30, [0x18FE], 0x31E),                // -2(A0,D1.L)
        (0x38, [0x8000], 0xFFFF8000),            // absolute short, sign-extended
        (0x39, [0x1234, 0x5679], 0x12345679),    // absolute long, no target read
        (0x3A, [0xFFFE], 0x100),                // -2(PC), extension-word base
        (0x3B, [0x18FE], 0x120)                 // -2(PC,D1.L)
    ]
    for base: UInt16 in [0x45C0, 0x4EC0, 0x4E80] { // LEA to A2, JMP, JSR
        for item in cases {
            for supervisor: UInt16 in [0, 0x2000] {
                for flags: UInt16 in 0..<32 {
                    var memory = try controlMemory([base | item.ea] + item.extensions)
                    var cpu = MC68000()
                    cpu.programCounter = 0x100
                    cpu.statusRegister = 0x8700 | supervisor | flags
                    cpu.userStackPointer = 0x800
                    cpu.supervisorStackPointer = 0x900
                    cpu[address: 0] = 0x300
                    cpu[data: 1] = 0x20
                    let returnAddress = UInt32(0x102 + item.extensions.count * 2)
                    let stack = cpu[address: 7]
                    try memory.writeLong(0xDEADBEEF, at: stack - 4)
                    var expected = cpu
                    if base == 0x45C0 {
                        expected[address: 2] = item.target
                        expected.programCounter = returnAddress
                    } else {
                        expected.programCounter = item.target
                        if base == 0x4E80 { expected[address: 7] = stack - 4 }
                    }
                    try cpu.step(memory: &memory)
                    #expect(cpu == expected)
                    #expect(try memory.readLong(at: stack - 4) == (base == 0x4E80 ? returnAddress : 0xDEADBEEF))
                }
            }
        }
    }
}

@Test func leaAllRegistersAndAliasedIndex() throws {
    for supervisor: UInt16 in [0, 0x2000] {
        for source in 0..<8 {
            for destination in 0..<8 {
                let opcode = UInt16(0x41E8 | (destination << 9) | source)
                var memory = try controlMemory([opcode, 0xFFFC])
                var cpu = MC68000()
                cpu.programCounter = 0x100
                cpu.statusRegister = supervisor | 0x1F
                for index in 0..<8 { cpu[address: index] = UInt32(index * 0x100 + 2) }
                var expected = cpu
                expected[address: destination] = cpu[address: source] &- 4
                expected.programCounter = 0x104
                try cpu.step(memory: &memory)
                #expect(cpu == expected)
            }
        }
    }
    // Destination, base and index all use A0; both word and long indices.
    for (extensionWord, target): (UInt16, UInt32) in [(0x8002, 0x1234FFFE), (0x8802, 0x2469FFFE)] {
        var memory = try controlMemory([0x41F0, extensionWord])
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu[address: 0] = 0x1234FFFE
        try cpu.step(memory: &memory)
        #expect(cpu[address: 0] == target)
        #expect(cpu.programCounter == 0x104)
    }
}

@Test func jsrResolvesStackBaseAndIndexBeforePush() throws {
    let cases: [(words: [UInt16], target: UInt32)] = [
        ([0x4E97], 0x800),             // (A7)
        ([0x4EAF, 0xFFFC], 0x7FC),     // -4(A7), target overlaps return address
        ([0x4EB7, 0xF8FE], 0xFFE),     // -2(A7,A7.L)
        ([0x4EBB, 0xF800], 0x902)      // 0(PC,A7.L)
    ]
    for supervisor: UInt16 in [0, 0x2000] {
        for item in cases {
            var memory = try controlMemory(item.words)
            var cpu = MC68000()
            cpu.statusRegister = supervisor | 0x1F
            cpu.programCounter = 0x100
            cpu[address: 7] = 0x800
            var expected = cpu
            expected[address: 7] = 0x7FC
            expected.programCounter = item.target
            try cpu.step(memory: &memory)
            #expect(cpu == expected)
            #expect(try memory.readLong(at: 0x7FC) == UInt32(0x100 + item.words.count * 2))
        }
    }
}

@Test func controlRejectsEveryNonControlEncodingBeforeSideEffects() throws {
    let bases: [UInt16] = (0..<8).map { 0x41C0 | UInt16($0 << 9) } + [0x4E80, 0x4EC0]
    // Explicit invalid EA encodings; instruction lies at RAM's end to detect extension reads.
    let invalid = Array(0x00...0x0F) + Array(0x18...0x27) + Array(0x3C...0x3F)
    for base in bases {
        for ea in invalid {
            let opcode = base | UInt16(ea)
            var memory = try controlMemory([opcode], at: 0x1FFFFE)
            var cpu = MC68000()
            cpu.programCounter = 0x1FFFFE
            for index in 0..<8 { cpu[address: index] = 0x400 }
            try memory.writeLong(0xDEADBEEF, at: 0x3FC)
            cpu.stopsOnIllegalInstruction = true
            let before = cpu
            #expect(throws: CPUError.unsupportedInstruction(opcode: opcode, address: 0x1FFFFE)) {
                try cpu.step(memory: &memory)
            }
            #expect(cpu == before)
            #expect(try memory.readLong(at: 0x3FC) == 0xDEADBEEF)
        }
    }
}

@Test func controlExtensionFaultsPreserveCPUAndStack() throws {
    for base: UInt16 in [0x41C0, 0x4E80, 0x4EC0] {
        for ea: UInt16 in [0x28, 0x30, 0x38, 0x39, 0x3A, 0x3B] {
            for partialLong in [false, true] {
                if partialLong && ea != 0x39 { continue }
                let start: UInt32 = partialLong ? 0x1FFFFC : 0x1FFFFE
                let words: [UInt16] = partialLong ? [base | ea, 0x1234] : [base | ea]
                var memory = try controlMemory(words, at: start)
                var cpu = MC68000()
                cpu.programCounter = start
                cpu[address: 7] = 0x400
                try memory.writeLong(0xDEADBEEF, at: 0x3FC)
                let before = cpu
                #expect(throws: MemoryBusError.unmappedAddress(0x200000)) {
                    try cpu.step(memory: &memory)
                }
                #expect(cpu == before)
                #expect(try memory.readLong(at: 0x3FC) == 0xDEADBEEF)
            }
        }
    }
}

@Test func jsrStackFaultsAndPartialWrites() throws {
    let cases: [(stack: UInt32, error: MemoryBusError)] = [
        (0x403, .unalignedAddress(0x3FF)),
        (0x200004, .unmappedAddress(0x200000)),
        (0x200002, .unmappedAddress(0x200000))
    ]
    for item in cases {
        var memory = try controlMemory([0x4EB9, 0, 0x300])
        try memory.writeWord(0xFFFF, at: 0x1FFFFE)
        var cpu = MC68000()
        cpu.programCounter = 0xAB000100
        cpu.stopsOnAddressError = true
        cpu[address: 7] = item.stack
        let before = cpu
        #expect(throws: item.error) { try cpu.step(memory: &memory) }
        #expect(cpu == before)
        #expect(try memory.readWord(at: 0x1FFFFE) == (item.stack == 0x200002 ? 0xAB00 : 0xFFFF))
    }
}

@Test func jumpTargetFaultsOccurOnNextFetch() throws {
    for opcode: UInt16 in [0x4EF9, 0x4EB9] {
        for (target, error): (UInt32, MemoryBusError) in [
            (0x301, .unalignedAddress(0x301)), (0x200000, .unmappedAddress(0x200000))
        ] {
            var memory = try controlMemory([opcode, UInt16(target >> 16), UInt16(truncatingIfNeeded: target)])
            var cpu = MC68000()
            cpu.programCounter = 0x100
            cpu.stopsOnAddressError = true
            cpu[address: 7] = 0x400
            try cpu.step(memory: &memory)
            #expect(cpu.programCounter == target)
            #expect(cpu[address: 7] == (opcode == 0x4EB9 ? 0x3FC : 0x400))
            if opcode == 0x4EB9 { #expect(try memory.readLong(at: 0x3FC) == 0x106) }
            let before = cpu
            #expect(throws: error) { try cpu.step(memory: &memory) }
            #expect(cpu == before)
        }
    }
}

@Test func controlExtensionCursorWrapsAt32Bits() throws {
    for opcode: UInt16 in [0x41FA, 0x4EFA, 0x4EBA, 0x4EB9] {
        var rom = [UInt8](repeating: 0, count: 256 * 1024)
        rom[rom.count - 4] = UInt8(opcode >> 8)
        rom[rom.count - 3] = UInt8(truncatingIfNeeded: opcode)
        rom[rom.count - 2] = opcode == 0x4EB9 ? 0x12 : 0
        rom[rom.count - 1] = opcode == 0x4EB9 ? 0x34 : 8
        var memory = try AmigaMemory(kickstart: rom)
        memory.setOverlay(enabled: false)
        try memory.writeWord(0x5678, at: 0)
        var cpu = MC68000()
        cpu.programCounter = 0xFFFFFFFC
        cpu[address: 7] = 0x400
        try cpu.step(memory: &memory)
        if opcode == 0x41FA {
            #expect(cpu[address: 0] == 6)
            #expect(cpu.programCounter == 0)
        } else {
            #expect(cpu.programCounter == (opcode == 0x4EB9 ? 0x12345678 : 6))
            if opcode != 0x4EFA {
                #expect(cpu[address: 7] == 0x3FC)
                #expect(try memory.readLong(at: 0x3FC) == (opcode == 0x4EB9 ? 2 : 0))
            }
        }
    }
}

@Test func controlSyntheticCallAndReturn() throws {
    var memory = try controlMemory([
        0x41FA, 0x000A, // $100: LEA $10C(PC),A0
        0x4E90,         // $104: JSR (A0), return to $106
        0x4EF8, 0x0110, // $106: JMP $110.W
        0x4AFC,         // $10A: unsupported sentinel, must be skipped
        0x702A,         // $10C: MOVEQ #42,D0
        0x4E75,         // $10E: RTS
        0x4E71          // $110: NOP
    ])
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[address: 7] = 0x800
    for _ in 0..<6 { try cpu.step(memory: &memory) }
    #expect(cpu[data: 0] == 42)
    #expect(cpu[address: 0] == 0x10C)
    #expect(cpu[address: 7] == 0x800)
    #expect(cpu.programCounter == 0x112)
    #expect(try memory.readLong(at: 0x7FC) == 0x106)
}
