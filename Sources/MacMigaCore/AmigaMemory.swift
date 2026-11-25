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
    /// Gary routes `$000000`–`$1FFFFF` to Agnus; 512 KiB of chip RAM repeats through it.
    private static let chipRAMSpace: UInt32 = 0x20_0000
    private let kickstart: [UInt8]
    var chipRAM = [UInt8](repeating: 0, count: chipRAMSize)
    /// A501-style "slow" (ranger) RAM at `$C00000`; empty when the machine has none.
    private var slowRAM: [UInt8]
    /// CIA-A (odd bytes, selected by A12 low): OVL/LED/disk/fire inputs, keyboard.
    public var ciaA = CIA8520()
    /// CIA-B (even bytes, selected by A13 low): serial/parallel control, disk drive outputs.
    public var ciaB = CIA8520()
    /// OCS custom chip registers, decoded at `$DFF000`–`$DFFFFF` (mirrored every `$200`).
    public var custom = CustomChips()
    /// Copper and display output (Agnus DMA, Denise), driven by `advanceChipset`.
    public var copper = Copper()
    public var video = Video()
    /// Internal floppy drive DF0, controlled through CIA-B port B.
    public internal(set) var drive = FloppyDrive()

    /// ROM overlay follows CIA-A PA0 (OVL). The line is pulled up, so it is active
    /// while PA0 is still an input after reset.
    public var overlayEnabled: Bool { ciaA.outputA & 0x01 != 0 }

    /// Accepts a raw, unencrypted 256 KiB or 512 KiB ROM supplied by the caller.
    /// Size validation does not establish that the image is a valid Kickstart ROM.
    /// `slowRAMSize` is 0 (stock A500) or up to 1.5 MiB in 256 KiB steps; the default
    /// 512 KiB models the common A500 + A501 trapdoor expansion.
    public init(kickstart: [UInt8], slowRAMSize: Int = 512 * 1024) throws {
        guard kickstart.count == 256 * 1024 || kickstart.count == 512 * 1024 else {
            throw MemoryBusError.invalidROMSize(kickstart.count)
        }
        precondition(slowRAMSize >= 0 && slowRAMSize <= 0x18_0000 && slowRAMSize % 0x4_0000 == 0)
        self.kickstart = kickstart
        self.slowRAM = [UInt8](repeating: 0, count: slowRAMSize)
        updateDrive()
    }

    /// Inserts an ADF image into DF0 (nil ejects). /CHNG stays low until the next step.
    public mutating func insertDisk(adf: [UInt8]?) throws {
        if let adf { try drive.insert(adf: adf) } else { drive.eject() }
        updateDrive()
    }

    /// Feeds CIA-B port B to the drive and its status back into CIA-A port A bits 2–5.
    private mutating func updateDrive() {
        drive.control(ciaB.outputB)
        ciaA.inputA = (ciaA.inputA & ~0x3C) | (drive.statusLines & 0x3C)
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
        custom = CustomChips()
        copper = Copper()
        drive = FloppyDrive(disk: drive.disk) // a reset does not eject the disk
        updateDrive()
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

    /// `$D80000`–`$DFEFFF` holds no device on a stock A500 (no RTC, no Gayle/IDE);
    /// reads return 0 and writes are ignored. Kickstart 3.1 probes the A600 Gayle here.
    private static func isEmptyIORange(_ physical: UInt32) -> Bool {
        physical >= 0xD8_0000 && physical < 0xDF_F000
    }

    /// `$E80000`–`$EFFFFF` is the Zorro II autoconfig window. No expansion boards are
    /// fitted: reads return 0 (er_Type 0 is not a valid board type) and writes are ignored.
    private static func isEmptyAutoconfig(_ physical: UInt32) -> Bool {
        physical >= 0xE8_0000 && physical < 0xF0_0000
    }

    /// Custom registers at `$DFF000`–`$DFFFFF`, plus the part of `$C00000`–`$D7FFFF` not
    /// backed by slow RAM: without RAM there, the A500 decodes those addresses to the
    /// custom chips, which Kickstart detects by writing INTENA through the mirror.
    private func isCustomRange(_ physical: UInt32) -> Bool {
        (physical >= 0xDF_F000 && physical < 0xE0_0000)
            || (physical >= 0xC0_0000 + UInt32(slowRAM.count) && physical < 0xD8_0000)
    }

    private func isSlowRAM(_ physical: UInt32) -> Bool {
        physical >= 0xC0_0000 && physical < 0xC0_0000 + UInt32(slowRAM.count)
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
        if physical < Self.chipRAMSpace {
            if overlayEnabled && physical < UInt32(Self.chipRAMSize) {
                return kickstart[Int(physical) % kickstart.count]
            }
            return chipRAM[Int(physical) % Self.chipRAMSize]
        }
        if isSlowRAM(physical) { return slowRAM[Int(physical - 0xC0_0000)] }
        if Self.isEmptyDiagnosticSlot(physical) { return 0 }
        if Self.isCIARange(physical) {
            let register = Int(physical >> 8) & 0xF
            if physical & 1 != 0 {
                return physical & 0x1000 == 0 ? ciaA.read(register: register) : 0xFF
            }
            return physical & 0x2000 == 0 ? ciaB.read(register: register) : 0xFF
        }
        if isCustomRange(physical) {
            let word = custom.readWord(offset: Int(physical & 0x1FE))
            return physical & 1 == 0 ? UInt8(word >> 8) : UInt8(truncatingIfNeeded: word)
        }
        if Self.isEmptyIORange(physical) || Self.isEmptyAutoconfig(physical) { return 0 }
        throw MemoryBusError.unmappedAddress(physical)
    }

    public mutating func writeByte(_ value: UInt8, at address: UInt32) throws {
        let physical = address & Self.addressMask
        if physical >= 0xF8_0000 || Self.isEmptyDiagnosticSlot(physical) { return }
        if physical < Self.chipRAMSpace {
            if !(overlayEnabled && physical < UInt32(Self.chipRAMSize)) {
                chipRAM[Int(physical) % Self.chipRAMSize] = value
            }
            return
        }
        if isSlowRAM(physical) {
            slowRAM[Int(physical - 0xC0_0000)] = value
            return
        }
        if Self.isCIARange(physical) {
            let register = Int(physical >> 8) & 0xF
            if physical & 1 != 0 {
                if physical & 0x1000 == 0 { ciaA.write(register: register, value: value) }
            } else if physical & 0x2000 == 0 {
                ciaB.write(register: register, value: value)
                if register == 1 || register == 3 { updateDrive() }
            }
            return
        }
        if isCustomRange(physical) {
            // A byte write drives the same byte onto both halves of the 16-bit bus.
            custom.writeWord(offset: Int(physical & 0x1FE), value: UInt16(value) << 8 | UInt16(value))
            return
        }
        if Self.isEmptyIORange(physical) || Self.isEmptyAutoconfig(physical) { return }
        throw MemoryBusError.unmappedAddress(physical)
    }

    public mutating func readWord(at address: UInt32) throws -> UInt16 {
        try checkAlignment(address)
        let physical = address & Self.addressMask
        if isCustomRange(physical) { return custom.readWord(offset: Int(physical & 0x1FE)) }
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
        let physical = address & Self.addressMask
        if isCustomRange(physical) {
            custom.writeWord(offset: Int(physical & 0x1FE), value: value)
            return
        }
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
