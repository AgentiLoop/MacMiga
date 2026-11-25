/// An A500 (PAL) assembled from the CPU and the memory bus, stepped one instruction at a time.
///
/// Each instruction is charged a fixed estimate of CPU clocks (no cycle-accurate timing yet).
/// That time advances the beam (colour clock = 2 CPU clocks) and both CIA timers (E clock =
/// 10 CPU clocks). CIA-A's TOD counts frames (VSYNC) and CIA-B's counts lines (HSYNC).
/// CIA-A /IRQ sets INTREQ PORTS (bit 3, level 2) and CIA-B /IRQ sets INTREQ EXTER
/// (bit 13, level 6). Paula's resulting level is presented to the CPU before every step.
public struct AmigaMachine {
    /// PAL 68000 clock in Hz.
    public static let cpuClock = 7_093_790
    /// Estimated CPU clocks per executed instruction, and per idle step while stopped.
    public static let clocksPerInstruction = 10
    public static let clocksPerStoppedStep = 4

    public var cpu = MC68000()
    public var memory: AmigaMemory
    /// Total CPU clocks elapsed since power-on.
    public private(set) var clock: UInt64 = 0
    private var colorClockRemainder = 0
    private var eClockRemainder = 0

    public init(kickstart: [UInt8], slowRAMSize: Int = 512 * 1024) throws {
        memory = try AmigaMemory(kickstart: kickstart, slowRAMSize: slowRAMSize)
        try cpu.reset(memory: &memory)
    }

    /// Takes a pending interrupt if the CPU accepts it, then executes one instruction
    /// (or idles while stopped) and advances the chipset by the estimated time.
    public mutating func step() throws {
        let level = memory.custom.interruptLevel
        if level > 0 { try cpu.interrupt(level: level, memory: &memory) }
        let stopped = cpu.isStopped
        try cpu.step(memory: &memory)
        advance(cpuClocks: stopped ? Self.clocksPerStoppedStep : Self.clocksPerInstruction)
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
        if memory.ciaA.interruptRequested { memory.custom.requestInterrupt(bits: 0x0008) }
        if memory.ciaB.interruptRequested { memory.custom.requestInterrupt(bits: 0x2000) }
    }
}
