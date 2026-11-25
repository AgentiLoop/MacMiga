/// Everything a 68000 can address: the machine's RAM, ROM and memory-mapped devices.
///
/// A machine (Amiga, Macintosh, NeXT, …) implements this once for its memory map and passes
/// it to `MC68000.step(memory:)`. Values are big-endian; the bus decides how many of the 32
/// address bits it decodes (a 68000 drives 24). Methods are `mutating` because reads can
/// have side effects on devices. An error thrown here leaves the CPU's registers as they
/// were before the instruction and is rethrown by the CPU as a host diagnostic.
///
/// The CPU never asks for a word or long at an odd address; see `CPUError.addressError`.
public protocol M68KBus {
    mutating func readByte(at address: UInt32) throws -> UInt8
    mutating func readWord(at address: UInt32) throws -> UInt16
    mutating func readLong(at address: UInt32) throws -> UInt32
    mutating func writeByte(_ value: UInt8, at address: UInt32) throws
    mutating func writeWord(_ value: UInt16, at address: UInt32) throws
    mutating func writeLong(_ value: UInt32, at address: UInt32) throws
    /// The CPU executed RESET and drives its reset line: every device returns to its
    /// power-on state. The CPU itself and the contents of memory are not affected. The
    /// default does nothing.
    mutating func resetDevices()
}

extension M68KBus {
    @inlinable public mutating func resetDevices() {}
}

/// Word and long accesses as the 68000 makes them: an odd address is an address error and
/// never reaches the bus. The reported address is all 32 bits of the 68000's address, as the
/// exception frame holds them; only the low 24 would have reached the pins.
extension M68KBus {
    @inlinable mutating func readAlignedWord(at address: UInt32) throws -> UInt16 {
        guard address & 1 == 0 else { throw CPUError.addressError(address: address, isWrite: false) }
        return try readWord(at: address)
    }

    @inlinable mutating func readAlignedLong(at address: UInt32) throws -> UInt32 {
        guard address & 1 == 0 else { throw CPUError.addressError(address: address, isWrite: false) }
        return try readLong(at: address)
    }

    @inlinable mutating func writeAlignedWord(_ value: UInt16, at address: UInt32) throws {
        guard address & 1 == 0 else { throw CPUError.addressError(address: address, isWrite: true) }
        try writeWord(value, at: address)
    }

    @inlinable mutating func writeAlignedLong(_ value: UInt32, at address: UInt32) throws {
        guard address & 1 == 0 else { throw CPUError.addressError(address: address, isWrite: true) }
        try writeLong(value, at: address)
    }
}
