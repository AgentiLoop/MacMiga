import M68K

/// The memory map the instruction tests run on. It is not a model of any machine:
/// 2 MiB of RAM at `$000000`, 256 KiB of ROM at `$FC0000`–`$FFFFFF` (writes are ignored)
/// and nothing in between, where every access throws `Fault.unmapped` with the address of
/// the byte concerned. Only 24 address bits are decoded, as with a 68000's pins. Words and
/// longs are made of byte accesses, high byte first, so a multi-byte write that runs into
/// the hole leaves its first bytes behind.
struct TestBus: M68KBus {
    enum Fault: Error, Equatable {
        case unmapped(UInt32)
    }

    static let ramSize: UInt32 = 0x20_0000
    static let romStart: UInt32 = 0xFC_0000

    var ram = [UInt8](repeating: 0, count: Int(ramSize))
    let rom: [UInt8]

    init(rom: [UInt8] = [UInt8](repeating: 0, count: 256 * 1024)) {
        precondition(rom.count == 256 * 1024)
        self.rom = rom
    }

    mutating func readByte(at address: UInt32) throws -> UInt8 {
        let physical = address & 0xFF_FFFF
        if physical < Self.ramSize { return ram[Int(physical)] }
        if physical >= Self.romStart { return rom[Int(physical - Self.romStart)] }
        throw Fault.unmapped(physical)
    }

    mutating func writeByte(_ value: UInt8, at address: UInt32) throws {
        let physical = address & 0xFF_FFFF
        if physical < Self.ramSize { ram[Int(physical)] = value; return }
        if physical >= Self.romStart { return }
        throw Fault.unmapped(physical)
    }

    mutating func readWord(at address: UInt32) throws -> UInt16 {
        UInt16(try readByte(at: address)) << 8 | UInt16(try readByte(at: address &+ 1))
    }

    mutating func readLong(at address: UInt32) throws -> UInt32 {
        UInt32(try readWord(at: address)) << 16 | UInt32(try readWord(at: address &+ 2))
    }

    mutating func writeWord(_ value: UInt16, at address: UInt32) throws {
        try writeByte(UInt8(value >> 8), at: address)
        try writeByte(UInt8(value & 0xFF), at: address &+ 1)
    }

    mutating func writeLong(_ value: UInt32, at address: UInt32) throws {
        try writeWord(UInt16(value >> 16), at: address)
        try writeWord(UInt16(value & 0xFFFF), at: address &+ 2)
    }
}
