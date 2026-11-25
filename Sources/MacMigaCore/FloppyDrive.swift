/// Internal 3.5" DD drive DF0 as seen through the CIAs; no disk media or disk DMA yet.
///
/// CIA-B port B drives it (all active low): PB7 /MTR (latched when /SEL0 falls), PB3
/// /SEL0, PB2 /SIDE, PB1 DIR (high = outwards), PB0 /STEP (a falling edge moves the head).
/// While selected it answers on CIA-A port A (active low): PA5 /RDY (motor on), PA4 /TK0
/// (head on cylinder 0), PA3 /WPRO, PA2 /CHNG (low while no disk is inserted).
/// DF1–DF3 are not connected, so selecting them leaves those inputs high.
public struct FloppyDrive: Equatable, Sendable {
    public static let cylinders = 80
    public private(set) var cylinder = 0
    public private(set) var motorOn = false
    public private(set) var selected = false
    public private(set) var side = 0
    /// No media support yet: the drive is always empty.
    public var hasDisk: Bool { false }
    private var previousControl: UInt8 = 0xFF

    public init() {}

    /// Applies a new CIA-B port B value.
    mutating func control(_ value: UInt8) {
        let select = value & 0x08 == 0
        if select && previousControl & 0x08 != 0 { motorOn = value & 0x80 == 0 }
        selected = select
        side = value & 0x04 == 0 ? 1 : 0
        if select && previousControl & 0x01 != 0 && value & 0x01 == 0 {
            if value & 0x02 != 0 { cylinder = max(cylinder - 1, 0) }
            else { cylinder = min(cylinder + 1, Self.cylinders - 1) }
        }
        previousControl = value
    }

    /// CIA-A port A input bits 2–5 for the current state (others stay high).
    var statusLines: UInt8 {
        guard selected else { return 0xFF }
        var lines: UInt8 = 0xFF
        if motorOn { lines &= ~0x20 }
        if cylinder == 0 { lines &= ~0x10 }
        if !hasDisk { lines &= ~0x04 }
        return lines
    }
}
