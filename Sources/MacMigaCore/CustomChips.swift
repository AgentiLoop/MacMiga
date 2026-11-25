/// Register file of the OCS custom chips (Agnus, Denise, Paula) at `$DFF000`–`$DFF1FE`.
///
/// Implements the set/clear control registers (DMACON, INTENA, INTREQ, ADKCON) and
/// their read-back registers, a PAL beam counter for VPOSR/VHPOSR, and storage of every
/// other write-only register so later subsystems (Copper, bitplanes, Blitter, audio,
/// disk) can consume them. No DMA, video, audio or Blitter behaviour happens here yet.
public struct CustomChips: Equatable, Sendable {
    public enum Register {
        public static let dmaconr = 0x002, vposr = 0x004, vhposr = 0x006
        public static let joy0dat = 0x00A, joy1dat = 0x00C, adkconr = 0x010
        public static let potgor = 0x016, serdatr = 0x018, dskbytr = 0x01A
        public static let intenar = 0x01C, intreqr = 0x01E
        public static let dmacon = 0x096, intena = 0x09A, intreq = 0x09C, adkcon = 0x09E
    }

    /// PAL frame geometry in colour clocks (one colour clock = two CPU clocks).
    public static let colorClocksPerLine = 227
    public static let linesPerFrame = 312

    public private(set) var dmacon: UInt16 = 0
    public private(set) var intena: UInt16 = 0
    public private(set) var intreq: UInt16 = 0
    public private(set) var adkcon: UInt16 = 0
    public private(set) var verticalPosition = 0
    public private(set) var horizontalPosition = 0
    /// Last value written to each register word (index = offset / 2).
    public private(set) var written = [UInt16](repeating: 0, count: 0x100)

    public init() {}

    /// 68000 interrupt level Paula asserts (0 = none); requires the INTEN master bit.
    public var interruptLevel: Int {
        guard intena & 0x4000 != 0 else { return 0 }
        let pending = intena & intreq & 0x3FFF
        guard pending != 0 else { return 0 }
        let highest = 15 - pending.leadingZeroBitCount
        // Paula priority levels for INTREQ bits 0–13.
        let levels = [1, 1, 1, 2, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6]
        return levels[highest]
    }

    public mutating func readWord(offset: Int) -> UInt16 {
        switch offset & 0x1FE {
        case Register.dmaconr: return dmacon // BBUSY/BZERO (bits 14/13) read 0: no Blitter yet
        case Register.vposr: return UInt16(verticalPosition >> 8) & 0x0001 // PAL OCS Agnus ID 0, LOF 0
        case Register.vhposr: return UInt16(verticalPosition & 0xFF) << 8 | UInt16(horizontalPosition & 0xFF)
        case Register.adkconr: return adkcon
        case Register.potgor: return 0xFF00 // pull-ups: right mouse/fire buttons released
        case Register.intenar: return intena
        case Register.intreqr: return intreq
        case Register.joy0dat, Register.joy1dat, Register.serdatr, Register.dskbytr: return 0
        default: return 0 // write-only strobe/data registers; real hardware returns bus noise
        }
    }

    public mutating func writeWord(offset: Int, value: UInt16) {
        let register = offset & 0x1FE
        written[register >> 1] = value
        switch register {
        case Register.dmacon: Self.setClear(&dmacon, value, mask: 0x07FF)
        case Register.intena: Self.setClear(&intena, value, mask: 0x7FFF)
        case Register.intreq: Self.setClear(&intreq, value, mask: 0x3FFF)
        case Register.adkcon: Self.setClear(&adkcon, value, mask: 0x7FFF)
        default: break
        }
    }

    /// Paula/Agnus raise interrupt request bits (e.g. VERTB = bit 5).
    public mutating func requestInterrupt(bits: UInt16) {
        intreq |= bits & 0x3FFF
    }

    /// Advances the beam; each new frame raises VERTB (INTREQ bit 5).
    /// Returns lines (CIA-B TOD input) and frames (CIA-A TOD input) completed.
    @discardableResult
    public mutating func advance(colorClocks: Int) -> (lines: Int, frames: Int) {
        var lines = 0, frames = 0
        horizontalPosition += colorClocks
        while horizontalPosition >= Self.colorClocksPerLine {
            horizontalPosition -= Self.colorClocksPerLine
            lines += 1
            verticalPosition += 1
            if verticalPosition >= Self.linesPerFrame {
                verticalPosition = 0
                frames += 1
                intreq |= 0x0020
            }
        }
        return (lines, frames)
    }

    private static func setClear(_ register: inout UInt16, _ value: UInt16, mask: UInt16) {
        let bits = value & mask & 0x7FFF
        if value & 0x8000 != 0 { register |= bits } else { register &= ~bits }
    }
}
