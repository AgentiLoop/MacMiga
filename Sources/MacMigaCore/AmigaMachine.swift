import M68K

/// The 68000 core lives in the machine-independent `M68K` package.
public typealias MC68000 = M68K.MC68000
public typealias CPUError = M68K.CPUError

/// An A500 (PAL, or NTSC with `ntsc`) assembled from the CPU and the memory bus, stepped one instruction at a time.
///
/// Each instruction takes the CPU clocks the 68000 core reports for it, and an accepted
/// interrupt 44 more. The chipset is advanced once per instruction, not per bus cycle, and
/// takes no bus time from the CPU.
/// That time advances the beam (colour clock = 2 CPU clocks) and both CIA timers (E clock =
/// 10 CPU clocks). CIA-A's TOD counts frames (VSYNC) and CIA-B's counts lines (HSYNC).
/// CIA-A /IRQ sets INTREQ PORTS (bit 3, level 2) and CIA-B /IRQ sets INTREQ EXTER
/// (bit 13, level 6). Paula's resulting level is presented to the CPU before every step.
public struct AmigaMachine {
    /// PAL 68000 clock in Hz.
    public static let cpuClock = 7_093_790
    /// CPU clocks per idle step while the CPU is stopped.
    public static let clocksPerStoppedStep = 4

    public var cpu = MC68000()
    public var memory: AmigaMemory
    /// Total CPU clocks elapsed since power-on.
    public private(set) var clock: UInt64 = 0
    private var colorClockRemainder = 0
    private var eClockRemainder = 0
    /// Raw keyboard codes (bit 7 = key up) waiting to be sent to CIA-A.
    private var keyQueue: [UInt8] = []
    private var keyboardHandshakes = 0
    private var keyboardSentAt: UInt64?

    /// `ntsc` makes it an NTSC A500: the NTSC Agnus (60 frames a second); clocks keep the
    /// same ratios, so the machine is otherwise unchanged.
    public init(kickstart: [UInt8], extendedROM: [UInt8] = [], chipRAMSize: Int = 512 * 1024,
                slowRAMSize: Int = 512 * 1024, fastRAMSize: Int = 0, hardDisk: HardDisk? = nil,
                ntsc: Bool = false) throws {
        memory = try AmigaMemory(kickstart: kickstart, extendedROM: extendedROM, chipRAMSize: chipRAMSize,
                                 slowRAMSize: slowRAMSize, fastRAMSize: fastRAMSize, hardDisk: hardDisk, ntsc: ntsc)
        memory.stopsOnUnmappedAccess = false
        _ = try memory.reset()
        try cpu.reset(memory: &memory)
    }

    /// Takes a pending interrupt if the CPU accepts it, then executes one instruction
    /// (or idles while stopped) and advances the chipset by the time that took.
    public mutating func step() throws {
        let level = memory.custom.interruptLevel
        var clocks = 0
        if level > 0, try cpu.interrupt(level: level, memory: &memory) { clocks = MC68000.interruptClocks }
        if cpu.isStopped {
            clocks = Self.clocksPerStoppedStep
        } else {
            clocks += try cpu.step(memory: &memory)
        }
        advance(cpuClocks: clocks)
    }

    /// Queues an Amiga raw key code (e.g. `$45` Esc, `$40` Space) press or release.
    public mutating func key(_ code: UInt8, pressed: Bool) {
        keyQueue.append(code & 0x7F | (pressed ? 0 : 0x80))
    }

    /// Mouse in port 1: motion counts and buttons (left = CIA-A /FIR0, right = POTGOR DATLY).
    public mutating func mouse(dx: Int = 0, dy: Int = 0, left: Bool, right: Bool) {
        memory.custom.moveMouse(dx: dx, dy: dy)
        memory.custom.rightMouseButton = right
        memory.ciaA.inputA = left ? memory.ciaA.inputA & ~0x40 : memory.ciaA.inputA | 0x40
    }

    /// Joystick in port 2: directions in JOY1DAT, fire = CIA-A /FIR1.
    public mutating func joystick(_ state: Joystick, fire: Bool) {
        memory.custom.joystick1 = state
        memory.ciaA.inputA = fire ? memory.ciaA.inputA & ~0x80 : memory.ciaA.inputA | 0x80
    }

    /// Sends the next queued key once the previous byte was acknowledged by the CIA-A
    /// SPMODE handshake, or after the keyboard's 143 ms timeout. The byte on the wire is
    /// the code rotated left one bit and inverted, as the keyboard transmits it.
    private mutating func serviceKeyboard() {
        if let sentAt = keyboardSentAt {
            let acknowledged = memory.ciaA.serialHandshakes != keyboardHandshakes
            guard acknowledged || clock - sentAt > UInt64(Self.cpuClock / 7) else { return }
            keyboardSentAt = nil
        }
        guard !keyQueue.isEmpty, memory.ciaA.controlA & 0x40 == 0 else { return }
        let raw = keyQueue.removeFirst()
        memory.ciaA.receiveSerial(~(raw << 1 | raw >> 7))
        keyboardHandshakes = memory.ciaA.serialHandshakes
        keyboardSentAt = clock
    }

    /// Advances beam, TOD inputs and CIA timers, then routes CIA interrupts into INTREQ.
    public mutating func advance(cpuClocks: Int) {
        clock += UInt64(cpuClocks)
        colorClockRemainder += cpuClocks
        let (lines, frames) = memory.advanceChipset(colorClocks: colorClockRemainder / 2)
        colorClockRemainder %= 2
        for _ in 0..<lines { memory.ciaB.pulseTOD() }
        for _ in 0..<frames { memory.ciaA.pulseTOD() }
        eClockRemainder += cpuClocks
        if eClockRemainder >= 10 {
            memory.ciaA.tick(eClocks: eClockRemainder / 10)
            memory.ciaB.tick(eClocks: eClockRemainder / 10)
            eClockRemainder %= 10
        }
        serviceKeyboard()
        if memory.ciaA.interruptRequested { memory.custom.requestInterrupt(bits: 0x0008) }
        if memory.ciaB.interruptRequested { memory.custom.requestInterrupt(bits: 0x2000) }
    }
}
