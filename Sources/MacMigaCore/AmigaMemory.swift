public enum MemoryBusError: Error, Equatable {
    case invalidROMSize(Int)
    case unmappedAddress(UInt32)
    case unalignedAddress(UInt32)
}

public struct ResetVectors: Equatable, Sendable {
    public let supervisorStackPointer: UInt32
    public let programCounter: UInt32
}

/// CPU-side memory map subset with both CIAs. Custom chips and bus timing are not implemented.
public struct AmigaMemory {
    public static let chipRAMSize = 512 * 1024
    private static let addressMask: UInt32 = 0x00FF_FFFF
    private let kickstart: [UInt8]
    private var chipRAM = [UInt8](repeating: 0, count: chipRAMSize)
    /// CIA-A (odd bytes, selected by A12 low): OVL/LED/disk/fire inputs, keyboard.
    public var ciaA = CIA8520()
    /// CIA-B (even bytes, selected by A13 low): serial/parallel control, disk drive outputs.
    public var ciaB = CIA8520()

    /// ROM overlay follows CIA-A PA0 (OVL). The line is pulled up, so it is active
    /// while PA0 is still an input after reset.
    public var overlayEnabled: Bool { ciaA.outputA & 0x01 != 0 }

    /// Accepts a raw, unencrypted 256 KiB or 512 KiB ROM supplied by the caller.
    /// Size validation does not establish that the image is a valid Kickstart ROM.
    public init(kickstart: [UInt8]) throws {
        guard kickstart.count == 256 * 1024 || kickstart.count == 512 * 1024 else {
            throw MemoryBusError.invalidROMSize(kickstart.count)
        }
        self.kickstart = kickstart
    }

    /// Host convenience: drives CIA-A PA0 as an output at the requested OVL level.
    public mutating func setOverlay(enabled: Bool) {
        ciaA.directionA |= 0x01
        ciaA.portA = enabled ? ciaA.portA | 0x01 : ciaA.portA & ~0x01
    }

    /// Resets both CIAs (restoring the overlay) without clearing RAM, then fetches
    /// the CPU reset vectors. This is not an implementation of the CPU's RESET instruction.
    public mutating func reset() throws -> ResetVectors {
        ciaA = CIA8520()
        ciaB = CIA8520()
        return try ResetVectors(
            supervisorStackPointer: readLong(at: 0),
            programCounter: readLong(at: 4)
        )
    }

    /// `$F00000`–`$F7FFFF` is the diagnostic/extended-ROM slot, empty on a stock A500.
    /// Kickstart probes it for the `$1111` cartridge signature. Real hardware returns
    /// open-bus data there; this model returns zero (never `$1111`) and ignores writes.
    private static func isEmptyDiagnosticSlot(_ physical: UInt32) -> Bool {
        physical >= 0xF0_0000 && physical < 0xF8_0000
    }

    /// `$A00000`–`$BFFFFF` selects the CIAs: register = A8–A11; CIA-A answers odd bytes
    /// when A12 is low, CIA-B even bytes when A13 is low. An unselected byte lane reads
    /// as `$FF` here (real hardware: open bus).
    private static func isCIARange(_ physical: UInt32) -> Bool {
        physical >= 0xA0_0000 && physical < 0xC0_0000
    }

    public mutating func readByte(at address: UInt32) throws -> UInt8 {
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
        if Self.isEmptyDiagnosticSlot(physical) { return 0 }
        if Self.isCIARange(physical) {
            let register = Int(physical >> 8) & 0xF
            if physical & 1 != 0 {
                return physical & 0x1000 == 0 ? ciaA.read(register: register) : 0xFF
            }
            return physical & 0x2000 == 0 ? ciaB.read(register: register) : 0xFF
        }
        throw MemoryBusError.unmappedAddress(physical)
    }

    public mutating func writeByte(_ value: UInt8, at address: UInt32) throws {
        let physical = address & Self.addressMask
        if physical >= 0xF8_0000 || Self.isEmptyDiagnosticSlot(physical) { return }
        if physical < UInt32(Self.chipRAMSize) {
            if !overlayEnabled { chipRAM[Int(physical)] = value }
            return
        }
        if Self.isCIARange(physical) {
            let register = Int(physical >> 8) & 0xF
            if physical & 1 != 0 {
                if physical & 0x1000 == 0 { ciaA.write(register: register, value: value) }
            } else if physical & 0x2000 == 0 {
                ciaB.write(register: register, value: value)
            }
            return
        }
        throw MemoryBusError.unmappedAddress(physical)
    }

    public mutating func readWord(at address: UInt32) throws -> UInt16 {
        try checkAlignment(address)
        let high = try readByte(at: address)
        let low = try readByte(at: address &+ 1)
        return UInt16(high) << 8 | UInt16(low)
    }

    public mutating func readLong(at address: UInt32) throws -> UInt32 {
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
