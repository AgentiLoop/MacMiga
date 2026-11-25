/// Register-level model of one MOS 8520 Complex Interface Adapter.
///
/// Implements the 16-register file: I/O ports with data-direction registers,
/// timers A and B (latch, one-shot/continuous, force load, B counting A
/// underflows), the 24-bit TOD counter with alarm and read latch, the serial
/// data register (storage only), and the interrupt control register.
/// Counting is driven by the host through `tick(eClocks:)` and `pulseTOD()`;
/// it is not cycle-exact and does not model the CNT/SP/FLAG pins or PB6/PB7 output.
public struct CIA8520: Equatable, Sendable {
    public enum Interrupt {
        public static let timerA: UInt8 = 0x01
        public static let timerB: UInt8 = 0x02
        public static let alarm: UInt8 = 0x04
        public static let serial: UInt8 = 0x08
        public static let flag: UInt8 = 0x10
    }

    public var portA: UInt8 = 0
    public var portB: UInt8 = 0
    public var directionA: UInt8 = 0
    public var directionB: UInt8 = 0
    /// Levels on input pins; bits configured as outputs ignore these.
    public var inputA: UInt8 = 0xFF
    public var inputB: UInt8 = 0xFF

    public private(set) var timerA: UInt16 = 0xFFFF
    public private(set) var timerB: UInt16 = 0xFFFF
    public private(set) var latchA: UInt16 = 0xFFFF
    public private(set) var latchB: UInt16 = 0xFFFF
    public private(set) var controlA: UInt8 = 0
    public private(set) var controlB: UInt8 = 0

    public private(set) var tod: UInt32 = 0
    public private(set) var alarm: UInt32 = 0
    private var todLatch: UInt32?
    private var todHalted = false

    public private(set) var serialData: UInt8 = 0
    public private(set) var interruptData: UInt8 = 0
    public private(set) var interruptMask: UInt8 = 0

    public init() {}

    /// Port value seen by the CPU and attached hardware: outputs drive, inputs float to `input`.
    public var outputA: UInt8 { (portA & directionA) | (inputA & ~directionA) }
    public var outputB: UInt8 { (portB & directionB) | (inputB & ~directionB) }

    /// True while an enabled interrupt source is pending (the /IRQ line is asserted).
    public var interruptRequested: Bool { interruptData & interruptMask != 0 }

    /// Register read; reading ICR clears it and reading TOD bits 16–23 latches TOD.
    public mutating func read(register: Int) -> UInt8 {
        switch register & 0xF {
        case 0x0: return outputA
        case 0x1: return outputB
        case 0x2: return directionA
        case 0x3: return directionB
        case 0x4: return UInt8(truncatingIfNeeded: timerA)
        case 0x5: return UInt8(truncatingIfNeeded: timerA >> 8)
        case 0x6: return UInt8(truncatingIfNeeded: timerB)
        case 0x7: return UInt8(truncatingIfNeeded: timerB >> 8)
        case 0x8:
            let value = todLatch ?? tod
            todLatch = nil
            return UInt8(truncatingIfNeeded: value)
        case 0x9: return UInt8(truncatingIfNeeded: (todLatch ?? tod) >> 8)
        case 0xA:
            todLatch = tod
            return UInt8(truncatingIfNeeded: tod >> 16)
        case 0xC: return serialData
        case 0xD:
            let value = interruptData | (interruptRequested ? 0x80 : 0)
            interruptData = 0
            return value
        case 0xE: return controlA & ~0x10
        case 0xF: return controlB & ~0x10
        default: return 0xFF
        }
    }

    public mutating func write(register: Int, value: UInt8) {
        switch register & 0xF {
        case 0x0: portA = value
        case 0x1: portB = value
        case 0x2: directionA = value
        case 0x3: directionB = value
        case 0x4: latchA = (latchA & 0xFF00) | UInt16(value)
        case 0x5:
            latchA = (latchA & 0x00FF) | UInt16(value) << 8
            if controlA & 0x01 == 0 { timerA = latchA }
            if controlA & 0x08 != 0 { controlA |= 0x01 }
        case 0x6: latchB = (latchB & 0xFF00) | UInt16(value)
        case 0x7:
            latchB = (latchB & 0x00FF) | UInt16(value) << 8
            if controlB & 0x01 == 0 { timerB = latchB }
            if controlB & 0x08 != 0 { controlB |= 0x01 }
        case 0x8: writeTOD(byte: 0, value: value)
        case 0x9: writeTOD(byte: 1, value: value)
        case 0xA: writeTOD(byte: 2, value: value)
        case 0xC: serialData = value
        case 0xD:
            if value & 0x80 != 0 {
                interruptMask |= value & 0x1F
            } else {
                interruptMask &= ~(value & 0x1F)
            }
        case 0xE:
            if value & 0x10 != 0 { timerA = latchA }
            controlA = value & ~0x10
        case 0xF:
            if value & 0x10 != 0 { timerB = latchB }
            controlB = value & ~0x10
        default: break
        }
    }

    /// Advances E-clock-driven timers. Timer B may instead count timer A underflows.
    public mutating func tick(eClocks: Int) {
        guard eClocks > 0 else { return }
        let timerBMode = (controlB >> 5) & 0x3
        var underflowsA = 0
        if controlA & 0x21 == 0x01 { // started, counting E clocks
            underflowsA = count(&timerA, latch: latchA, control: &controlA, ticks: eClocks)
            if underflowsA > 0 { interruptData |= Interrupt.timerA }
        }
        guard controlB & 0x01 != 0 else { return }
        let ticksB: Int
        switch timerBMode {
        case 0: ticksB = eClocks
        case 2: ticksB = underflowsA
        default: ticksB = 0 // CNT-pin modes: no CNT source is modelled
        }
        if count(&timerB, latch: latchB, control: &controlB, ticks: ticksB) > 0 {
            interruptData |= Interrupt.timerB
        }
    }

    /// One TOD input pulse (CIA-A: vertical sync, CIA-B: horizontal sync).
    public mutating func pulseTOD() {
        guard !todHalted else { return }
        tod = (tod &+ 1) & 0xFF_FFFF
        if tod == alarm { interruptData |= Interrupt.alarm }
    }

    /// Counts a timer down; each pass through zero reloads the latch and is one underflow.
    /// A one-shot timer stops after its first underflow.
    private func count(_ counter: inout UInt16, latch: UInt16, control: inout UInt8, ticks: Int) -> Int {
        var remaining = ticks
        var underflows = 0
        while remaining > 0 {
            if Int(counter) > remaining {
                counter -= UInt16(remaining)
                break
            }
            remaining -= max(Int(counter), 1)
            counter = latch
            underflows += 1
            if control & 0x08 != 0 {
                control &= ~0x01
                break
            }
        }
        return underflows
    }

    private mutating func writeTOD(byte: Int, value: UInt8) {
        let shift = UInt32(byte * 8)
        let mask = ~(UInt32(0xFF) << shift) & 0xFF_FFFF
        if controlB & 0x80 != 0 {
            alarm = (alarm & mask) | UInt32(value) << shift
        } else {
            tod = (tod & mask) | UInt32(value) << shift
            if byte == 2 { todHalted = true }
            if byte == 0 { todHalted = false }
        }
    }
}
