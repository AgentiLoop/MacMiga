public enum MemoryBusError: Error, Equatable {
    case invalidROMSize(Int)
    case unmappedAddress(UInt32)
    case unalignedAddress(UInt32)
}

public struct ResetVectors: Equatable, Sendable {
    public let supervisorStackPointer: UInt32
    public let programCounter: UInt32
}

/// Initial CPU-side memory subset. Peripheral decoding and bus timing are not implemented.
public struct AmigaMemory {
    public static let chipRAMSize = 512 * 1024
    private static let addressMask: UInt32 = 0x00FF_FFFF
    private let kickstart: [UInt8]
    private var chipRAM = [UInt8](repeating: 0, count: chipRAMSize)
    public private(set) var overlayEnabled = true

    /// Accepts a raw, unencrypted 256 KiB or 512 KiB ROM supplied by the caller.
    /// Size validation does not establish that the image is a valid Kickstart ROM.
    public init(kickstart: [UInt8]) throws {
        guard kickstart.count == 256 * 1024 || kickstart.count == 512 * 1024 else {
            throw MemoryBusError.invalidROMSize(kickstart.count)
        }
        self.kickstart = kickstart
    }

    /// Host hook until CIA-A's OVL output is implemented.
    public mutating func setOverlay(enabled: Bool) {
        overlayEnabled = enabled
    }

    /// Restores the ROM overlay without clearing RAM, then fetches the CPU reset vectors.
    /// This is not an implementation of the CPU's RESET instruction.
    public mutating func reset() throws -> ResetVectors {
        overlayEnabled = true
        return try ResetVectors(
            supervisorStackPointer: readLong(at: 0),
            programCounter: readLong(at: 4)
        )
    }

    public func readByte(at address: UInt32) throws -> UInt8 {
        let physical = address & Self.addressMask
        if physical >= 0xF8_0000 {
            return kickstart[Int(physical - 0xF8_0000) % kickstart.count]
        }
        if physical < UInt32(Self.chipRAMSize) {
            if overlayEnabled {
                return kickstart[Int(physical) % kickstart.count]
            }
            return chipRAM[Int(physical)]
        }
        throw MemoryBusError.unmappedAddress(physical)
    }

    public mutating func writeByte(_ value: UInt8, at address: UInt32) throws {
        let physical = address & Self.addressMask
        if physical >= 0xF8_0000 { return }
        if physical < UInt32(Self.chipRAMSize) {
            if !overlayEnabled { chipRAM[Int(physical)] = value }
            return
        }
        throw MemoryBusError.unmappedAddress(physical)
    }

    public func readWord(at address: UInt32) throws -> UInt16 {
        try checkAlignment(address)
        let high = try readByte(at: address)
        let low = try readByte(at: address &+ 1)
        return UInt16(high) << 8 | UInt16(low)
    }

    public func readLong(at address: UInt32) throws -> UInt32 {
        let high = try readWord(at: address)
        let low = try readWord(at: address &+ 2)
        return UInt32(high) << 16 | UInt32(low)
    }

    public mutating func writeWord(_ value: UInt16, at address: UInt32) throws {
        try checkAlignment(address)
        try writeByte(UInt8(truncatingIfNeeded: value >> 8), at: address)
        try writeByte(UInt8(truncatingIfNeeded: value), at: address &+ 1)
    }

    public mutating func writeLong(_ value: UInt32, at address: UInt32) throws {
        try checkAlignment(address)
        try writeWord(UInt16(truncatingIfNeeded: value >> 16), at: address)
        try writeWord(UInt16(truncatingIfNeeded: value), at: address &+ 2)
    }

    private func checkAlignment(_ address: UInt32) throws {
        guard address & 1 == 0 else {
            throw MemoryBusError.unalignedAddress(address & Self.addressMask)
        }
    }
}
