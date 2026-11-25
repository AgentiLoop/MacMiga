import Testing
import M68K

private func cpuMemory(_ words: [UInt16], at address: UInt32 = 0x100) throws -> TestBus {
    var memory = TestBus()
    for (index, word) in words.enumerated() {
        try memory.writeWord(word, at: address &+ UInt32(index * 2))
    }
    return memory
}

@Test func cpuResetLoadsVectorsAndRetainsGeneralRegisters() throws {
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom.replaceSubrange(8..<12, with: [0x70, 0xFF, 0x4E, 0x71])
    var memory = TestBus(rom: rom)
    try memory.writeLong(0x08_0000, at: 0) // initial SSP
    try memory.writeLong(0xFC_0008, at: 4) // initial PC, in the ROM
    var cpu = MC68000()
    cpu.statusRegister = 0x8015
    cpu[data: 3] = 0x1234_5678
    cpu[address: 2] = 0x8765_4321
    cpu.userStackPointer = 0x1000
    try cpu.reset(memory: &memory)
    #expect(cpu.statusRegister == 0x2715)
    #expect(cpu.programCounter == 0xFC_0008)
    #expect(cpu[address: 7] == 0x08_0000)
    #expect(cpu.userStackPointer == 0x1000)
    #expect(cpu[data: 3] == 0x1234_5678)
    #expect(cpu[address: 2] == 0x8765_4321)
    try cpu.step(memory: &memory)
    #expect(cpu[data: 0] == 0xFFFF_FFFF)
    #expect(cpu.programCounter == 0xFC_000A)
    try cpu.step(memory: &memory)
    #expect(cpu.programCounter == 0xFC_000C)
}

@Test func cpuStackBanksAndStatusMask() {
    var cpu = MC68000()
    cpu[address: 7] = 0x200000
    cpu.statusRegister = 0
    cpu[address: 7] = 0x2000
    #expect(cpu.userStackPointer == 0x2000)
    #expect(cpu.supervisorStackPointer == 0x200000)
    cpu.statusRegister = 0xFFFF
    #expect(cpu.statusRegister == 0xA71F)
    #expect(cpu[address: 7] == 0x200000)
    for register in 0..<7 {
        cpu[address: register] = UInt32(register + 1)
        #expect(cpu[address: register] == UInt32(register + 1))
    }
}

@Test func moveQuickAllRegistersImmediatesAndExtendStates() throws {
    var memory = try cpuMemory([])
    for register in 0..<8 {
        for immediate in 0..<256 {
            for extend: UInt16 in [0, 0x10] {
                try memory.writeWord(0x7000 | UInt16(register << 9) | UInt16(immediate), at: 0x100)
                var cpu = MC68000()
                cpu.programCounter = 0x100
                cpu.statusRegister = 0xA700 | extend | 0x0F
                for index in 0..<8 { cpu[data: index] = 0xDEAD_BEEF }
                try cpu.step(memory: &memory)
                let expected = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(immediate))))
                #expect(cpu[data: register] == expected)
                #expect(cpu.statusRegister == 0xA700 | extend | (immediate == 0 ? 4 : immediate >= 128 ? 8 : 0))
                #expect(cpu.programCounter == 0x102)
                for index in 0..<8 where index != register {
                    #expect(cpu[data: index] == 0xDEAD_BEEF)
                }
            }
        }
    }
}

@Test func nopPreservesAllStateExceptPC() throws {
    var memory = try cpuMemory([0x4E71])
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu.statusRegister = 0xA71F
    cpu[data: 2] = 123
    cpu[address: 5] = 456
    var expected = cpu
    expected.programCounter = 0x102
    try cpu.step(memory: &memory)
    #expect(cpu == expected)
}

@Test func everyBranchConditionForEveryCCRAndBothLengths() throws {
    // Each mask's bit i gives the branch result for NZVC = i, independent of decoder logic.
    let truthMasks: [UInt16] = [0x0505, 0xFAFA, 0x5555, 0xAAAA, 0x0F0F, 0xF0F0,
                               0x3333, 0xCCCC, 0x00FF, 0xFF00, 0xCC33, 0x33CC, 0x0C03, 0xF3FC]
    var memory = try cpuMemory([])
    for condition in 2...15 {
        for flags: UInt16 in 0..<32 {
            for wordForm in [false, true] {
                try memory.writeWord(0x6000 | UInt16(condition << 8) | (wordForm ? 0 : 6), at: 0x100)
                try memory.writeWord(6, at: 0x102)
                var cpu = MC68000()
                cpu.programCounter = 0x100
                cpu.statusRegister = 0x2700 | flags
                let taken = truthMasks[condition - 2] & (1 << (flags & 15)) != 0
                var expected = cpu
                expected.programCounter = taken ? 0x108 : wordForm ? 0x104 : 0x102
                try cpu.step(memory: &memory)
                #expect(cpu == expected)
            }
        }
    }
}

@Test func branchDisplacementBoundariesAnd32BitPCWrap() throws {
    var memory = try cpuMemory([])
    let cases: [(UInt16, UInt16, UInt32)] = [
        (0x6002, 0, 0x104), (0x60FE, 0, 0x100), (0x6080, 0, 0x82),
        (0x607F, 0, 0x181), (0x60FF, 0x1234, 0x101),
        (0x6000, 0, 0x102), (0x6000, 0xFFFE, 0x100),
        (0x6000, 0x8000, 0xFFFF_8102), (0x6000, 0x7FFF, 0x8101)
    ]
    for (opcode, extensionWord, target) in cases {
        try memory.writeWord(opcode, at: 0x100)
        try memory.writeWord(extensionWord, at: 0x102)
        var cpu = MC68000()
        cpu.programCounter = 0x100
        cpu.stopsOnAddressError = true // odd targets stay in PC instead of being taken as address errors
        try cpu.step(memory: &memory)
        #expect(cpu.programCounter == target)
    }
    var rom = [UInt8](repeating: 0, count: 256 * 1024)
    rom[rom.count - 2] = 0x60
    rom[rom.count - 1] = 2
    memory = TestBus(rom: rom)
    var cpu = MC68000()
    cpu.programCounter = 0xFFFF_FFFE
    try cpu.step(memory: &memory)
    #expect(cpu.programCounter == 2)
}

@Test func subroutinePushAndReturnForBothStackBanksAndLengths() throws {
    for supervisor in [false, true] {
        for wordForm in [false, true] {
            var memory = try cpuMemory([wordForm ? 0x6100 : 0x6106, 6, 0x4E71, 0x4E71, 0x4E75])
            var cpu = MC68000()
            cpu.programCounter = 0x100
            cpu.statusRegister = supervisor ? 0x271F : 0x001F
            cpu.userStackPointer = 0x4000
            cpu.supervisorStackPointer = 0x200000
            let initial = cpu
            let sp = cpu[address: 7]
            let returnAddress: UInt32 = wordForm ? 0x104 : 0x102
            try cpu.step(memory: &memory)
            #expect(cpu.programCounter == 0x108)
            #expect(cpu[address: 7] == sp - 4)
            #expect(try memory.readLong(at: sp - 4) == returnAddress)
            #expect(cpu.statusRegister == initial.statusRegister)
            try cpu.step(memory: &memory)
            var expected = initial
            expected.programCounter = returnAddress
            #expect(cpu == expected)
        }
    }
}

@Test func syntheticProgramCallsSubroutineAndBranchesOnMoveQuickFlags() throws {
    // MOVEQ #0,D0; BNE skip; BSR sub; BRA end; sub: MOVEQ #-1,D1; RTS; end: NOP.
    var memory = try cpuMemory([0x7000, 0x6608, 0x6102, 0x6004, 0x72FF, 0x4E75, 0x4E71])
    var cpu = MC68000()
    cpu.programCounter = 0x100
    cpu[address: 7] = 0x200000
    for _ in 0..<7 { try cpu.step(memory: &memory) }
    #expect(cpu[data: 0] == 0)
    #expect(cpu[data: 1] == 0xFFFF_FFFF)
    #expect(cpu.programCounter == 0x10E)
    #expect(cpu[address: 7] == 0x200000)
}

@Test func unsupportedOpcodesDoNotSilentlyExecuteOrChangeCPU() throws {
    var memory = try cpuMemory([])
    for opcode: UInt16 in [0x7100, 0x7FFF, 0x4188, 0x4808, 0x483C] {
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

@Test func fetchExtensionAndStackErrorsPreserveCPUState() throws {
    var memory = try cpuMemory([0x6102, 0x4E75])
    var cpu = MC68000()
    cpu.stopsOnAddressError = true
    for address: UInt32 in [0x101, 0x200000] {
        cpu.programCounter = address
        let before = cpu
        #expect(throws: (any Error).self) { try cpu.step(memory: &memory) }
        #expect(cpu == before)
    }
    // Untaken BNE.W still needs its extension word.
    try memory.writeWord(0x6600, at: 0x1FFFFE)
    cpu.programCounter = 0x1FFFFE
    cpu.stopsOnAddressError = true
    cpu.statusRegister = 0x2704
    var before = cpu
    #expect(throws: TestBus.Fault.unmapped(0x200000)) { try cpu.step(memory: &memory) }
    #expect(cpu == before)
    for (pc, sp): (UInt32, UInt32) in [(0x100, 0x1001), (0x100, 0x200004), (0x102, 0x1001), (0x102, 0x200000)] {
        cpu.programCounter = pc
        cpu[address: 7] = sp
        before = cpu
        #expect(throws: (any Error).self) { try cpu.step(memory: &memory) }
        #expect(cpu == before)
    }
    try memory.writeWord(0x60FF, at: 0x100)
    cpu.programCounter = 0x100
    try cpu.step(memory: &memory)
    #expect(cpu.programCounter == 0x101)
    before = cpu
    #expect(throws: CPUError.addressError(address: 0x101, isWrite: false)) { try cpu.step(memory: &memory) }
    #expect(cpu == before)
}
