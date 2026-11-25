import Testing
import M68K

/// The smallest possible machine: 64 KiB of RAM repeated through the address space, with
/// no alignment rule of its own. It counts the odd word/long accesses that reach it.
private struct RAM: M68KBus {
    var bytes = [UInt8](repeating: 0, count: 0x1_0000)
    var oddAccesses = 0

    mutating func readByte(at address: UInt32) throws -> UInt8 { bytes[Int(address & 0xFFFF)] }

    mutating func readWord(at address: UInt32) throws -> UInt16 {
        oddAccesses += Int(address & 1)
        return UInt16(try readByte(at: address)) << 8 | UInt16(try readByte(at: address &+ 1))
    }

    mutating func readLong(at address: UInt32) throws -> UInt32 {
        UInt32(try readWord(at: address)) << 16 | UInt32(try readWord(at: address &+ 2))
    }

    mutating func writeByte(_ value: UInt8, at address: UInt32) throws { bytes[Int(address & 0xFFFF)] = value }

    mutating func writeWord(_ value: UInt16, at address: UInt32) throws {
        oddAccesses += Int(address & 1)
        try writeByte(UInt8(value >> 8), at: address)
        try writeByte(UInt8(value & 0xFF), at: address &+ 1)
    }

    mutating func writeLong(_ value: UInt32, at address: UInt32) throws {
        try writeWord(UInt16(value >> 16), at: address)
        try writeWord(UInt16(value & 0xFFFF), at: address &+ 2)
    }

    /// Reset vectors SSP `$8000` and PC `$400`, with `program` at `$400`.
    init(program: [UInt16]) throws {
        try writeLong(0x8000, at: 0)
        try writeLong(0x400, at: 4)
        for (index, word) in program.enumerated() { try writeWord(word, at: 0x400 + UInt32(index * 2)) }
    }
}

private func start(_ program: [UInt16]) throws -> (MC68000, RAM) {
    var memory = try RAM(program: program)
    var cpu = MC68000()
    try cpu.reset(memory: &memory)
    return (cpu, memory)
}

@Test func resetLoadsTheVectorsFromTheBus() throws {
    let (cpu, _) = try start([])
    #expect(cpu.supervisorStackPointer == 0x8000)
    #expect(cpu.programCounter == 0x400)
    #expect(cpu.statusRegister == 0x2700)
    #expect(!cpu.isStopped)
}

@Test func programRunsOnAPlainRAMBusAndAnInterruptEndsStop() throws {
    var (cpu, memory) = try start([
        0x7000,         // $400 moveq #0,d0
        0x720A,         // $402 moveq #10,d1
        0xD081,         // $404 add.l d1,d0
        0x5381,         // $406 subq.l #1,d1
        0x66FA,         // $408 bne.s $404
        0x21C0, 0x1000, // $40A move.l d0,$1000.w
        0x6112,         // $40E bsr.s $422
        0x4E72, 0x2000  // $410 stop #$2000
    ])
    try memory.writeWord(0x5280, at: 0x422) // addq.l #1,d0
    try memory.writeWord(0x4E75, at: 0x424) // rts
    try memory.writeLong(0x500, at: 27 * 4) // level 3 autovector
    try memory.writeWord(0x4E73, at: 0x500) // rte

    #expect(try cpu.interrupt(level: 3, memory: &memory) == false) // masked at level 7 after reset
    for _ in 0..<100 where !cpu.isStopped { try cpu.step(memory: &memory) }
    #expect(cpu.isStopped)
    #expect(cpu[data: 0] == 56)
    #expect(cpu[data: 1] == 0)
    #expect(try memory.readLong(at: 0x1000) == 55)
    #expect(cpu.supervisorStackPointer == 0x8000)
    #expect(cpu.statusRegister == 0x2000)

    let resume = cpu.programCounter
    try cpu.step(memory: &memory) // stopped: nothing happens
    #expect(cpu.programCounter == resume)
    #expect(try cpu.interrupt(level: 3, memory: &memory))
    #expect(!cpu.isStopped)
    #expect(cpu.programCounter == 0x500)
    #expect(cpu.statusRegister == 0x2300)
    #expect(cpu.supervisorStackPointer == 0x8000 - 6)
    try cpu.step(memory: &memory) // rte
    #expect(cpu.programCounter == resume)
    #expect(cpu.statusRegister == 0x2000)
    #expect(cpu.supervisorStackPointer == 0x8000)
    #expect(memory.oddAccesses == 0)
}

@Test func oddWordAccessIsAnAddressErrorThatNeverReachesTheBus() throws {
    var (cpu, memory) = try start([0x3010]) // move.w (a0),d0
    try memory.writeLong(0x600, at: 3 * 4)
    cpu[address: 0] = 0x1001

    cpu.stopsOnAddressError = true
    let before = cpu
    #expect(throws: CPUError.addressError(address: 0x1001, isWrite: false)) { try cpu.step(memory: &memory) }
    #expect(cpu == before)

    cpu.stopsOnAddressError = false
    try cpu.step(memory: &memory)
    #expect(cpu.programCounter == 0x600)
    #expect(cpu.supervisorStackPointer == 0x8000 - 14)
    #expect(try memory.readWord(at: 0x7FF2) == 0x3015)      // read, supervisor data; upper bits from the opcode
    #expect(try memory.readLong(at: 0x7FF4) == 0x1001)      // access address
    #expect(try memory.readWord(at: 0x7FF8) == 0x3010)      // instruction register
    #expect(try memory.readWord(at: 0x7FFA) == 0x2700)      // SR
    #expect(try memory.readLong(at: 0x7FFC) == 0x402)       // PC
    #expect(memory.oddAccesses == 0)
}

@Test func illegalInstructionAndTrapGoThroughTheVectorTable() throws {
    var (cpu, memory) = try start([0x4AFC]) // illegal
    try memory.writeLong(0x700, at: 4 * 4)
    try memory.writeLong(0x800, at: 33 * 4)
    try memory.writeWord(0x4E41, at: 0x700) // trap #1
    try cpu.step(memory: &memory)
    #expect(cpu.programCounter == 0x700)
    #expect(try memory.readLong(at: 0x7FFC) == 0x400) // the opcode's own address
    #expect(try memory.readWord(at: 0x7FFA) == 0x2700)
    try cpu.step(memory: &memory)
    #expect(cpu.programCounter == 0x800)
    #expect(try memory.readLong(at: 0x7FF6) == 0x702) // the instruction after the trap
    #expect(cpu.supervisorStackPointer == 0x8000 - 12)

    // An unassigned opcode takes the same vector, or stops for decoder diagnostics.
    try memory.writeWord(0x7100, at: 0x800)
    cpu.stopsOnIllegalInstruction = true
    #expect(throws: CPUError.unsupportedInstruction(opcode: 0x7100, address: 0x800)) { try cpu.step(memory: &memory) }
    cpu.stopsOnIllegalInstruction = false
    try cpu.step(memory: &memory)
    #expect(cpu.programCounter == 0x700)
    #expect(try memory.readLong(at: 0x7FF0) == 0x800)
}

/// RAM whose `$400`–`$FFF` is hidden behind ILLEGAL opcodes after a reset, the way a boot
/// ROM overlay hides low memory. It counts the resets it is given.
private struct OverlayBus: M68KBus {
    var ram: RAM
    var resets = 0
    var hidden = false

    init(program: [UInt16]) throws { ram = try RAM(program: program) }

    mutating func readByte(at address: UInt32) throws -> UInt8 {
        hidden && (0x400..<0x1000).contains(address) ? (address & 1 == 0 ? 0x4A : 0xFC) : try ram.readByte(at: address)
    }
    mutating func readWord(at address: UInt32) throws -> UInt16 {
        UInt16(try readByte(at: address)) << 8 | UInt16(try readByte(at: address &+ 1))
    }
    mutating func readLong(at address: UInt32) throws -> UInt32 {
        UInt32(try readWord(at: address)) << 16 | UInt32(try readWord(at: address &+ 2))
    }
    mutating func writeByte(_ value: UInt8, at address: UInt32) throws { try ram.writeByte(value, at: address) }
    mutating func writeWord(_ value: UInt16, at address: UInt32) throws { try ram.writeWord(value, at: address) }
    mutating func writeLong(_ value: UInt32, at address: UInt32) throws { try ram.writeLong(value, at: address) }

    mutating func resetDevices() {
        resets += 1
        hidden = true
    }
}

@Test func resetInstructionResetsTheDevicesAndKeepsThePrefetchedOpcode() throws {
    var memory = try OverlayBus(program: [0x4E70, 0x4ED0]) // $400 reset ; $402 jmp (a0)
    try memory.writeWord(0x7007, at: 0x2000)               // moveq #7,d0
    var cpu = MC68000()
    try cpu.reset(memory: &memory)
    cpu[address: 0] = 0x2000
    try cpu.step(memory: &memory)
    #expect(memory.resets == 1)
    #expect(cpu.programCounter == 0x402)
    #expect(cpu.statusRegister == 0x2700 && cpu.supervisorStackPointer == 0x8000) // the CPU is not reset
    #expect(try memory.readWord(at: 0x402) == 0x4AFC)      // the code is hidden now…
    try cpu.step(memory: &memory)                          // …but JMP (A0) was already fetched
    #expect(cpu.programCounter == 0x2000)
    try cpu.step(memory: &memory)
    #expect(cpu[data: 0] == 7)
    #expect(memory.resets == 1)
}

@Test func resetIsPrivilegedAndAnInterruptDiscardsThePrefetch() throws {
    var memory = try OverlayBus(program: [0x4E70, 0x4ED0])
    try memory.writeLong(0x3000, at: 8 * 4)                // privilege violation
    try memory.writeLong(0x3000, at: 31 * 4)               // level 7 autovector
    try memory.writeWord(0x4E73, at: 0x3000)               // rte
    try memory.writeLong(0x3100, at: 4 * 4)                // illegal instruction
    var cpu = MC68000()
    try cpu.reset(memory: &memory)
    cpu.statusRegister = 0x0000                            // user mode
    cpu.userStackPointer = 0x7000
    try cpu.step(memory: &memory)
    #expect(memory.resets == 0)
    #expect(cpu.programCounter == 0x3000)
    #expect(try memory.readLong(at: 0x8000 - 4) == 0x400)

    cpu = MC68000()
    try cpu.reset(memory: &memory)
    try cpu.step(memory: &memory)                          // RESET in supervisor mode
    #expect(memory.resets == 1)
    #expect(try cpu.interrupt(level: 7, memory: &memory))
    try cpu.step(memory: &memory)                          // rte, back to $402
    #expect(cpu.programCounter == 0x402)
    try cpu.step(memory: &memory)                          // fetched from the bus now: ILLEGAL
    #expect(cpu.programCounter == 0x3100)
}

@Test func resetOnABusWithoutDevicesOnlyMovesOn() throws {
    var (cpu, memory) = try start([0x4E70, 0x7001])        // reset ; moveq #1,d0
    try cpu.step(memory: &memory)
    #expect(cpu.programCounter == 0x402)
    try cpu.step(memory: &memory)
    #expect(cpu[data: 0] == 1)
}
