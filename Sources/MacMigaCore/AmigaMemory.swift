import M68K

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
/// This is the bus the 68000 core (`M68K` package) runs on.
public struct AmigaMemory: M68KBus {
    private static let addressMask: UInt32 = 0x00FF_FFFF
    /// Gary routes `$000000`–`$1FFFFF` to Agnus; chip RAM repeats through it.
    private static let chipRAMSpace: UInt32 = 0x20_0000
    /// The ROM overlay hides the first 512 KiB, whatever the size of chip RAM.
    private static let overlaySize: UInt32 = 0x8_0000
    private let kickstart: [UInt8]
    /// Extended ROM at `$E00000`–`$E7FFFF` (512 KiB), empty when none is fitted.
    private let extendedROM: [UInt8]
    public var hasExtendedROM: Bool { !extendedROM.isEmpty }
    var chipRAM: [UInt8]
    /// 512 KiB with the OCS Agnus, 1 or 2 MiB with the ECS Agnus.
    public var chipRAMSize: Int { chipRAM.count }
    /// A501-style "slow" (ranger) RAM at `$C00000`; empty when the machine has none.
    private var slowRAM: [UInt8]
    /// CIA-A (odd bytes, selected by A12 low): OVL/LED/disk/fire inputs, keyboard.
    public var ciaA = CIA8520()
    /// CIA-B (even bytes, selected by A13 low): serial/parallel control, disk drive outputs.
    public var ciaB = CIA8520()
    /// OCS custom chip registers, decoded at `$DFF000`–`$DFFFFF` (mirrored every `$200`).
    public var custom: CustomChips
    /// Copper and display output (Agnus DMA, Denise), driven by `advanceChipset`.
    public var copper = Copper()
    public var video = Video()
    /// Internal floppy drive DF0, controlled through CIA-B port B.
    public internal(set) var drive = FloppyDrive()
    /// Paula's four audio channels and the mixed host sample stream, driven by `advanceChipset`.
    public var audio = Paula()
    /// When true (the default, for bus diagnostics), byte accesses to addresses with nothing
    /// behind them throw `MemoryBusError.unmappedAddress`. When false (hardware behaviour,
    /// set by `AmigaMachine`), such reads return 0 and writes are ignored; the A500 has no
    /// bus-error source, and real reads there return whatever was last on the data bus.
    public var stopsOnUnmappedAccess = true
    /// Zorro II AUTOCONFIG chain at `$E80000`: the fast RAM board, then the hard-disk controller.
    public private(set) var expansion = ExpansionBus()
    /// Zorro II fast RAM, mapped where Kickstart configures its board (`UInt32.max` until then).
    private var fastRAM: [UInt8]
    private var fastRAMBase = UInt32.max
    /// The hard disk behind the controller board; nil when no controller is fitted.
    public let hardDisk: HardDisk?
    var hardDiskController = HardDiskController()

    /// ROM overlay follows CIA-A PA0 (OVL). The line is pulled up, so it is active
    /// while PA0 is still an input after reset.
    public var overlayEnabled: Bool { ciaA.outputA & 0x01 != 0 }

    /// Accepts a raw, unencrypted 256 KiB or 512 KiB ROM supplied by the caller.
    /// Size validation does not establish that the image is a valid Kickstart ROM.
    /// `chipRAMSize` is 512 KiB (the stock A500 with its OCS Agnus), or 1 MiB or 2 MiB,
    /// which fits the ECS Agnus (`CustomChips.Agnus.ecs`) that can address them.
    /// `slowRAMSize` is 0 (stock A500) or up to 1.5 MiB in 256 KiB steps; the default
    /// 512 KiB models the common A500 + A501 trapdoor expansion. `fastRAMSize` is 0 or a
    /// power of two from 64 KiB to 8 MiB on a Zorro II board; `hardDisk` fits the
    /// hard-disk controller board. Kickstart configures both boards during startup.
    /// `extendedROM` is empty or a 512 KiB image for `$E00000`, where the A500 has nothing
    /// and later machines (CDTV, CD32) and replacement systems such as AROS keep the second
    /// half of a 1 MiB ROM.
    public init(kickstart: [UInt8], extendedROM: [UInt8] = [], chipRAMSize: Int = 512 * 1024,
                slowRAMSize: Int = 512 * 1024, fastRAMSize: Int = 0, hardDisk: HardDisk? = nil) throws {
        guard kickstart.count == 256 * 1024 || kickstart.count == 512 * 1024 else {
            throw MemoryBusError.invalidROMSize(kickstart.count)
        }
        guard extendedROM.isEmpty || extendedROM.count == 512 * 1024 else {
            throw MemoryBusError.invalidROMSize(extendedROM.count)
        }
        self.extendedROM = extendedROM
        precondition([0x8_0000, 0x10_0000, 0x20_0000].contains(chipRAMSize))
        self.chipRAM = [UInt8](repeating: 0, count: chipRAMSize)
        self.custom = CustomChips(agnus: chipRAMSize > 0x8_0000 ? .ecs : .ocs)
        precondition(slowRAMSize >= 0 && slowRAMSize <= 0x18_0000 && slowRAMSize % 0x4_0000 == 0)
        precondition(fastRAMSize == 0 || (fastRAMSize >= 0x1_0000 && fastRAMSize <= 0x80_0000
                                          && fastRAMSize & (fastRAMSize - 1) == 0))
        self.kickstart = kickstart
        self.slowRAM = [UInt8](repeating: 0, count: slowRAMSize)
        self.fastRAM = [UInt8](repeating: 0, count: fastRAMSize)
        self.hardDisk = hardDisk
        expansion.install(fastRAMSize: fastRAMSize, hardDisk: hardDisk != nil)
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

    /// Resets the devices, then fetches the CPU reset vectors (through the ROM overlay the
    /// reset has just restored).
    public mutating func reset() throws -> ResetVectors {
        resetDevices()
        return try ResetVectors(
            supervisorStackPointer: readLong(at: 0),
            programCounter: readLong(at: 4)
        )
    }

    /// The reset line, as driven at power-on, by the keyboard reset, or by the CPU's RESET
    /// instruction: both CIAs (which restores the ROM overlay), the custom chips, the
    /// floppy drive's latches and the expansion boards return to their power-on state.
    /// RAM keeps its contents.
    public mutating func resetDevices() {
        ciaA = CIA8520()
        ciaB = CIA8520()
        custom = CustomChips(agnus: custom.agnus)
        copper = Copper()
        drive = FloppyDrive(disk: drive.disk, rawTracks: drive.rawTracks) // a reset does not eject the disk
        updateDrive()
        // Expansion boards lose their addresses and wait to be configured again.
        expansion.install(fastRAMSize: fastRAM.count, hardDisk: hardDisk != nil)
        fastRAMBase = .max
        hardDiskController = HardDiskController()
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

    /// `$E80000`–`$EFFFFF` is Zorro II I/O space. Where no board answers, reads return 0
    /// (er_Type 0 is not a valid board type) and writes are ignored.
    private static func isEmptyAutoconfig(_ physical: UInt32) -> Bool {
        physical >= 0xE8_0000 && physical < 0xF0_0000
    }

    /// The unconfigured board at the head of the chain answers in `$E80000`–`$E8FFFF`.
    private func isConfigurationWindow(_ physical: UInt32) -> Bool {
        physical & 0xFF_0000 == 0xE8_0000 && expansion.pendingBoard != nil
    }

    private func isHardDiskBoard(_ physical: UInt32) -> Bool {
        physical >= hardDiskController.base && physical - hardDiskController.base < 0x1_0000
    }

    /// Maps a board at the address Kickstart just wrote to its configuration register.
    private mutating func configured(_ board: ExpansionBus.Board) {
        guard let base = board.base else { return }
        switch board.kind {
        case .fastRAM: fastRAMBase = base
        case .hardDisk: if let hardDisk { hardDiskController.configure(base: base, disk: hardDisk) }
        }
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

    private func isExtendedROM(_ physical: UInt32) -> Bool {
        physical >= 0xE0_0000 && physical < 0xE8_0000 && !extendedROM.isEmpty
    }

    public mutating func readByte(at address: UInt32) throws -> UInt8 {
        let physical = address & Self.addressMask
        if physical >= 0xF8_0000 {
            return kickstart[Int(physical - 0xF8_0000) % kickstart.count]
        }
        if physical < Self.chipRAMSpace {
            if overlayEnabled && physical < Self.overlaySize {
                return kickstart[Int(physical) % kickstart.count]
            }
            return chipRAM[Int(physical) & (chipRAM.count - 1)]
        }
        if physical >= fastRAMBase && physical - fastRAMBase < UInt32(fastRAM.count) {
            return fastRAM[Int(physical - fastRAMBase)]
        }
        if isSlowRAM(physical) { return slowRAM[Int(physical - 0xC0_0000)] }
        if isExtendedROM(physical) { return extendedROM[Int(physical - 0xE0_0000)] }
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
        if isHardDiskBoard(physical) { return readHardDiskBoard(offset: Int(physical - hardDiskController.base)) }
        if isConfigurationWindow(physical) { return expansion.read(offset: Int(physical & 0xFFFF)) }
        if Self.isEmptyIORange(physical) || Self.isEmptyAutoconfig(physical) || !stopsOnUnmappedAccess { return 0 }
        throw MemoryBusError.unmappedAddress(physical)
    }

    public mutating func writeByte(_ value: UInt8, at address: UInt32) throws {
        let physical = address & Self.addressMask
        if physical >= 0xF8_0000 || Self.isEmptyDiagnosticSlot(physical) || isExtendedROM(physical) { return }
        if physical < Self.chipRAMSpace {
            if !(overlayEnabled && physical < Self.overlaySize) {
                chipRAM[Int(physical) & (chipRAM.count - 1)] = value
            }
            return
        }
        if physical >= fastRAMBase && physical - fastRAMBase < UInt32(fastRAM.count) {
            fastRAM[Int(physical - fastRAMBase)] = value
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
        if isHardDiskBoard(physical) {
            writeHardDiskBoard(offset: Int(physical - hardDiskController.base), value: value)
            return
        }
        if isConfigurationWindow(physical) {
            if let board = expansion.write(offset: Int(physical & 0xFFFF), value: value) { configured(board) }
            return
        }
        if Self.isEmptyIORange(physical) || Self.isEmptyAutoconfig(physical) || !stopsOnUnmappedAccess { return }
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
        guard address & 1 == 0 else { throw MemoryBusError.unalignedAddress(address & Self.addressMask) }
    }
}
