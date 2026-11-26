/// Register file of the custom chips (Agnus, Denise, Paula) at `$DFF000`–`$DFF1FE`. Denise
/// and Paula are the OCS chips; Agnus is the OCS 8371 or, for more than 512 KiB of chip
/// RAM, the ECS 8372A (see `Agnus`).
///
/// Implements the set/clear control registers (DMACON, INTENA, INTREQ, ADKCON) and
/// their read-back registers, a PAL beam counter for VPOSR/VHPOSR, and storage of every
/// other write-only register so later subsystems (Copper, bitplanes, Blitter, audio,
/// disk) can consume them. No DMA, video, audio or Blitter behaviour happens here yet.
public struct CustomChips: Equatable, Sendable {
    /// Which Agnus is fitted. The ECS Agnus identifies itself in VPOSR (`$20`, PAL) and adds
    /// three Blitter registers: BLTCON0L (the minterm byte of BLTCON0 on its own) and the
    /// big-blit pair BLTSIZV/BLTSIZH. Its wider DMA pointers reach all of chip RAM.
    /// Its other additions are not modelled: BEAMCON0 and the programmable beam registers
    /// are stored without effect (the beam is always PAL), as is DIWHIGH.
    public enum Agnus: Equatable, Sendable { case ocs, ecs }

    public enum Register {
        public static let dmaconr = 0x002, vposr = 0x004, vhposr = 0x006
        public static let joy0dat = 0x00A, joy1dat = 0x00C, adkconr = 0x010
        public static let potgor = 0x016, serdatr = 0x018, dskbytr = 0x01A
        public static let intenar = 0x01C, intreqr = 0x01E
        public static let dmacon = 0x096, intena = 0x09A, intreq = 0x09C, adkcon = 0x09E
        public static let serdat = 0x030
        public static let dskpth = 0x020, dsklen = 0x024, deniseid = 0x07C, dsksync = 0x07E
        public static let joytest = 0x036, spr0pth = 0x120, spr0pos = 0x140
        public static let copcon = 0x02E, cop1lch = 0x080, cop2lch = 0x084
        public static let copjmp1 = 0x088, copjmp2 = 0x08A
        public static let diwstrt = 0x08E, diwstop = 0x090, ddfstrt = 0x092, ddfstop = 0x094
        public static let bpl1pth = 0x0E0, bplcon0 = 0x100, bplcon1 = 0x102, bplcon2 = 0x104
        public static let bpl1mod = 0x108, bpl2mod = 0x10A, color00 = 0x180
        public static let bltcon0 = 0x040, bltcon1 = 0x042, bltafwm = 0x044, bltalwm = 0x046
        public static let bltcpth = 0x048, bltsize = 0x058, bltcon0l = 0x05A, bltsizv = 0x05C, bltsizh = 0x05E
        public static let bltcmod = 0x060, bltbmod = 0x062, bltamod = 0x064, bltdmod = 0x066
        public static let bltcdat = 0x070, bltbdat = 0x072, bltadat = 0x074
    }

    /// PAL frame geometry in colour clocks (one colour clock = two CPU clocks).
    public static let colorClocksPerLine = 227
    public static let linesPerFrame = 312

    public private(set) var dmacon: UInt16 = 0
    public private(set) var intena: UInt16 = 0 {
        didSet {
            if intena != oldValue { interruptLevel = calculatedInterruptLevel }
        }
    }
    public private(set) var intreq: UInt16 = 0 {
        didSet {
            if intreq != oldValue { interruptLevel = calculatedInterruptLevel }
        }
    }
    public private(set) var adkcon: UInt16 = 0
    public private(set) var verticalPosition = 0
    public private(set) var horizontalPosition = 0
    /// Last value written to each register word (index = offset / 2).
    public private(set) var written = [UInt16](repeating: 0, count: 0x100)
    /// Live bitplane DMA pointers BPL1PT–BPL6PT (written by CPU/Copper, advanced by DMA).
    public internal(set) var bitplanePointers = [UInt32](repeating: 0, count: 6)
    /// Pending COPJMP strobe (1 or 2), consumed by the Copper; 0 when none.
    var copperJump = 0
    /// Live Blitter pointers in register order: C, B, A, D.
    public internal(set) var blitterPointers = [UInt32](repeating: 0, count: 4)
    /// Set by a BLTSIZE (or ECS BLTSIZH) write until the Blitter has run the operation.
    public internal(set) var blitPending = false
    /// Size of the pending blit in words and lines.
    var blitWidth = 0, blitHeight = 0
    /// DMACONR BZERO: the last blit produced only zero D data.
    var blitterZero = false
    /// Sprite DMA pointers SPR0PT–SPR7PT and per-sprite Denise state.
    public internal(set) var spritePointers = [UInt32](repeating: 0, count: 8)
    public internal(set) var sprites = [Sprite](repeating: Sprite(), count: 8)
    /// Mouse counters in port 1 (JOY0DAT) and joystick direction lines in port 2 (JOY1DAT).
    public private(set) var mouseX: UInt8 = 0
    public private(set) var mouseY: UInt8 = 0
    public var joystick1 = Joystick()
    /// Right mouse button in port 1 (POTGOR DATLY, bit 10, active low).
    public var rightMouseButton = false
    /// Disk DMA pointer DSKPT.
    public internal(set) var diskPointer: UInt32 = 0
    /// DSKLEN was written once with DMAEN; a second such write starts the transfer.
    private var diskLengthArmed = false
    /// Set when a disk transfer has been started and not yet run.
    public internal(set) var diskDMAPending = false
    /// Colour clocks until the running disk transfer ends and raises DSKBLK; 0 when none runs.
    public internal(set) var diskBlockDelay = 0
    /// Bytes software wrote to the serial port (SERDAT), oldest first; the host may read
    /// and clear them. Only the most recent ones are kept.
    public var serialOutput: [UInt8] = []
    static let serialOutputLimit = 1 << 16
    /// Bit n set when AUDnDAT was written by the CPU (consumed by non-DMA audio playback).
    var audioDataWritten: UInt8 = 0
    /// COLORxx writes during the current line, in order, so Denise output can follow
    /// mid-line palette changes. Cleared after each line is drawn.
    var colorChanges: [ColorChange] = []

    struct ColorChange: Equatable, Sendable {
        /// Horizontal beam position (colour clocks) of the write.
        let position: Int
        let index: Int
        let value: UInt16
        let previous: UInt16
    }

    public let agnus: Agnus

    public init(agnus: Agnus = .ocs) { self.agnus = agnus }

    /// 68000 interrupt level Paula asserts (0 = none); requires the INTEN master bit.
    /// Updated on register changes so CPU steps only load the cached level.
    public private(set) var interruptLevel = 0

    private var calculatedInterruptLevel: Int {
        guard intena & 0x4000 != 0 else { return 0 }
        let pending = intena & intreq & 0x3FFF
        // Test priority groups from highest to lowest without an indexed lookup.
        if pending & 0x2000 != 0 { return 6 }
        if pending & 0x1800 != 0 { return 5 }
        if pending & 0x0780 != 0 { return 4 }
        if pending & 0x0070 != 0 { return 3 }
        if pending & 0x0008 != 0 { return 2 }
        return pending & 0x0007 != 0 ? 1 : 0
    }

    public mutating func readWord(offset: Int) -> UInt16 {
        switch offset & 0x1FE {
        case Register.dmaconr: return dmacon | (blitterZero ? 0x2000 : 0) // BBUSY: blits finish at once
        // Bits 14–8: Agnus ID, PAL 8371 = $00, PAL 8372A = $20. LOF 0.
        case Register.vposr: return (agnus == .ecs ? 0x2000 : 0) | UInt16(verticalPosition >> 8) & 0x0001
        case Register.vhposr: return UInt16(verticalPosition & 0xFF) << 8 | UInt16(horizontalPosition & 0xFF)
        case Register.adkconr: return adkcon
        case Register.potgor: return 0xFF00 & ~(rightMouseButton ? 0x0400 : 0) // pull-ups when released
        case Register.intenar: return intena
        case Register.intreqr: return intreq
        case Register.joy0dat: return UInt16(mouseY) << 8 | UInt16(mouseX)
        case Register.joy1dat: return joystick1.data
        // Nothing is connected to the serial port: the transmitter is always empty (TBE,
        // TSRE) and the receive line idles high (RXD).
        case Register.serdatr: return 0x3800
        case Register.dskbytr: return 0
        // The OCS Denise has no ID register and leaves the bus alone. An undriven bus is
        // modelled as all ones here, so Kickstart 2.0+ does not take it for an ECS Denise
        // (which answers `$xxFC`).
        case Register.deniseid: return 0xFFFF
        default: return 0 // write-only strobe/data registers; real hardware returns bus noise
        }
    }

    public mutating func writeWord(offset: Int, value: UInt16) {
        let register = offset & 0x1FE
        if register >= Register.color00 && register < Register.color00 + 0x40 {
            colorChanges.append(ColorChange(position: horizontalPosition, index: (register - Register.color00) >> 1,
                                            value: value & 0xFFF, previous: written[register >> 1] & 0xFFF))
        }
        written[register >> 1] = value
        switch register {
        case Register.dmacon: Self.setClear(&dmacon, value, mask: 0x07FF)
        case Register.intena: Self.setClear(&intena, value, mask: 0x7FFF)
        case Register.intreq: Self.setClear(&intreq, value, mask: 0x3FFF)
        case Register.adkcon: Self.setClear(&adkcon, value, mask: 0x7FFF)
        case Register.copjmp1: copperJump = 1
        case Register.copjmp2: copperJump = 2
        case Register.serdat: // sent at once: the byte is kept for the host, and TBE (INTREQ bit 0) follows
            serialOutput.append(UInt8(truncatingIfNeeded: value))
            if serialOutput.count > Self.serialOutputLimit { serialOutput.removeFirst(serialOutput.count - Self.serialOutputLimit / 2) }
            intreq |= 0x0001
        case Register.bltsize: // height in bits 15–6, width in bits 5–0; 0 means 1024 and 64
            blitHeight = value >> 6 == 0 ? 1024 : Int(value >> 6)
            blitWidth = value & 0x3F == 0 ? 64 : Int(value & 0x3F)
            blitPending = true
        case Register.bltcon0l where agnus == .ecs: // replaces the low byte of BLTCON0
            let high = written[Register.bltcon0 >> 1] & 0xFF00
            written[Register.bltcon0 >> 1] = high | value & 0x00FF
        case Register.bltsizh where agnus == .ecs: // width 11 bits, height from BLTSIZV (15 bits)
            let height = Int(written[Register.bltsizv >> 1] & 0x7FFF)
            blitHeight = height == 0 ? 0x8000 : height
            blitWidth = value & 0x07FF == 0 ? 0x0800 : Int(value & 0x07FF)
            blitPending = true
        case 0x0AA, 0x0BA, 0x0CA, 0x0DA: audioDataWritten |= 1 << ((register - 0x0AA) >> 4)
        case Register.joytest:
            mouseY = (mouseY & 3) | UInt8(value >> 8) & 0xFC
            mouseX = (mouseX & 3) | UInt8(value & 0xFC)
        case Register.spr0pth...(Register.spr0pth + 0x1E):
            let sprite = (register - Register.spr0pth) >> 2
            let pointer = spritePointers[sprite]
            spritePointers[sprite] = register & 2 == 0
                ? (pointer & 0xFFFF) | UInt32(value & 0x001F) << 16
                : (pointer & 0x1F_0000) | UInt32(value & 0xFFFE)
        case Register.spr0pos...(Register.spr0pos + 0x3E):
            let sprite = (register - Register.spr0pos) >> 3
            switch register & 6 {
            case 0: sprites[sprite].position = value
            case 2: sprites[sprite].control = value; sprites[sprite].armed = false
            case 4: sprites[sprite].dataA = value; sprites[sprite].armed = true
            default: sprites[sprite].dataB = value
            }
        case Register.dskpth, Register.dskpth + 2:
            diskPointer = register & 2 == 0
                ? (diskPointer & 0xFFFF) | UInt32(value & 0x001F) << 16
                : (diskPointer & 0x1F_0000) | UInt32(value & 0xFFFE)
        case Register.dsklen:
            if value & 0x8000 == 0 {
                diskLengthArmed = false
                diskDMAPending = false
                diskBlockDelay = 0
            } else if diskLengthArmed {
                diskLengthArmed = false
                diskDMAPending = true
            } else {
                diskLengthArmed = true
            }
        case Register.bltcpth...(Register.bltcpth + 0xE):
            let channel = (register - Register.bltcpth) >> 2
            let pointer = blitterPointers[channel]
            blitterPointers[channel] = register & 2 == 0
                ? (pointer & 0xFFFF) | UInt32(value & 0x001F) << 16
                : (pointer & 0x1F_0000) | UInt32(value & 0xFFFE)
        case Register.bpl1pth...(Register.bpl1pth + 0x16):
            let plane = (register - Register.bpl1pth) >> 2
            let pointer = bitplanePointers[plane]
            bitplanePointers[plane] = register & 2 == 0
                ? (pointer & 0xFFFF) | UInt32(value & 0x001F) << 16
                : (pointer & 0x1F_0000) | UInt32(value & 0xFFFE)
        default: break
        }
    }

    /// Paula/Agnus raise interrupt request bits (e.g. VERTB = bit 5).
    public mutating func requestInterrupt(bits: UInt16) {
        intreq |= bits & 0x3FFF
    }

    /// Moves the mouse in port 1 by host-supplied counts (counters wrap at 8 bits).
    public mutating func moveMouse(dx: Int, dy: Int) {
        mouseX = UInt8(truncatingIfNeeded: Int(mouseX) + dx)
        mouseY = UInt8(truncatingIfNeeded: Int(mouseY) + dy)
    }

    /// Value of a register as last written by the CPU or Copper.
    public func register(_ offset: Int) -> UInt16 { written[(offset & 0x1FE) >> 1] }

    /// Copper list start address COP1LC (`list` 1) or COP2LC (`list` 2).
    public func copperLocation(_ list: Int) -> UInt32 {
        let high = list == 1 ? Register.cop1lch : Register.cop2lch
        return (UInt32(register(high)) << 16 | UInt32(register(high + 2))) & 0x1F_FFFE
    }

    /// Advances the beam; each new frame raises VERTB (INTREQ bit 5).
    /// Returns lines (CIA-B TOD input) and frames (CIA-A TOD input) completed.
    /// No Copper or bitplane DMA happens here; `AmigaMemory.advanceChipset` adds those.
    @discardableResult
    public mutating func advance(colorClocks: Int) -> (lines: Int, frames: Int) {
        var lines = 0, frames = 0
        for _ in 0..<colorClocks {
            let (line, frame) = stepBeam()
            if line { lines += 1 }
            if frame { frames += 1 }
        }
        return (lines, frames)
    }

    /// Moves the beam `colorClocks` along the current line (never past its end); reports
    /// whether the line and the frame ended.
    mutating func stepBeam(colorClocks: Int = 1) -> (lineEnded: Bool, frameEnded: Bool) {
        horizontalPosition += colorClocks
        guard horizontalPosition >= Self.colorClocksPerLine else { return (false, false) }
        horizontalPosition = 0
        verticalPosition += 1
        guard verticalPosition >= Self.linesPerFrame else { return (true, false) }
        verticalPosition = 0
        intreq |= 0x0020
        return (true, true)
    }

    private static func setClear(_ register: inout UInt16, _ value: UInt16, mask: UInt16) {
        let bits = value & mask & 0x7FFF
        if value & 0x8000 != 0 { register |= bits } else { register &= ~bits }
    }
}

/// One hardware sprite as seen by Denise: position/control words, current data, and the
/// DMA state Agnus keeps for it.
public struct Sprite: Equatable, Sendable {
    public enum DMAState: Equatable, Sendable { case idle, waiting, active }
    public internal(set) var position: UInt16 = 0
    public internal(set) var control: UInt16 = 0
    public internal(set) var dataA: UInt16 = 0
    public internal(set) var dataB: UInt16 = 0
    /// Writing DATA arms the sprite; writing CTL disarms it.
    public internal(set) var armed = false
    public internal(set) var dma = DMAState.idle

    public var verticalStart: Int { Int(position >> 8) | Int(control & 0x04) << 6 }
    public var verticalStop: Int { Int(control >> 8) | Int(control & 0x02) << 7 }
    /// Lowres horizontal position (same coordinates as DIWSTRT/DIWSTOP).
    public var horizontalStart: Int { Int(position & 0xFF) << 1 | Int(control & 0x01) }
    public var attached: Bool { control & 0x80 != 0 }
}

/// Joystick direction lines encoded as JOYxDAT: right sets bit 1, left bit 9; down and
/// up are XORed into bits 0 and 8.
public struct Joystick: Equatable, Sendable {
    public var up = false, down = false, left = false, right = false
    public init() {}
    var data: UInt16 {
        var value: UInt16 = 0
        if right { value |= 0x0002 }
        if left { value |= 0x0200 }
        if down != right { value |= 0x0001 }
        if up != left { value |= 0x0100 }
        return value
    }
}
