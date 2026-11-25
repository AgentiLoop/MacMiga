/// Copper co-processor state (Agnus). Runs only while DMACON DMAEN and COPEN are set.
///
/// Each instruction takes 4 colour clocks. MOVE writes a custom register (below `$40` is
/// never allowed, `$40`–`$7E` only with COPCON CDANG; otherwise the Copper halts until
/// the next frame). WAIT and SKIP compare the masked beam position `(V7–V0, H8–H1)`;
/// the vertical mask bit 7 is always on. The blitter-finished-disable bit is ignored
/// because the Blitter is not emulated yet. The Copper restarts at COP1LC every frame.
public struct Copper: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case fetching
        case waiting(position: Int, mask: Int)
        case halted
    }

    public internal(set) var programCounter: UInt32 = 0
    public internal(set) var state = State.halted
    /// Colour clocks until the current instruction has finished.
    var busy = 0

    public init() {}

    mutating func jump(to address: UInt32) {
        programCounter = address
        state = .fetching
        busy = 0
    }
}

/// Denise output: one PAL frame of 32-bit `0xAARRGGBB` pixels in hires resolution.
///
/// Column 0 is lowres horizontal position `firstLowresColumn`; each row is one beam line
/// (row = vertical position, 0–311). Bitplanes (1–6, lowres/hires, dual playfield, HAM
/// and extra half-brite) are drawn per line with the registers in effect at the end of
/// that line, so mid-line Copper colour changes affect the whole line. Sprites, collision
/// detection and interlace are not implemented.
public struct Video: Equatable, Sendable {
    public static let width = 736
    public static let height = CustomChips.linesPerFrame
    public static let firstLowresColumn = 0x58

    public private(set) var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
    /// Number of frames completed since power-on.
    public internal(set) var frameCount = 0

    public init() {}

    public static func argb(_ color: UInt16) -> UInt32 {
        let r = UInt32(color >> 8) & 0xF, g = UInt32(color >> 4) & 0xF, b = UInt32(color) & 0xF
        return 0xFF00_0000 | (r * 0x11) << 16 | (g * 0x11) << 8 | b * 0x11
    }

    mutating func fill(row: Int, with color: UInt32) {
        let start = row * Self.width
        for x in start..<(start + Self.width) { pixels[x] = color }
    }

    mutating func set(row: Int, column: Int, _ color: UInt32) {
        pixels[row * Self.width + column] = color
    }
}

extension AmigaMemory {
    /// Chip RAM word as seen by DMA (512 KiB, address wraps).
    func chipWord(at address: UInt32) -> UInt16 {
        let index = Int(address & 0x7_FFFE)
        return UInt16(chipRAM[index]) << 8 | UInt16(chipRAM[index + 1])
    }

    /// Advances the beam one colour clock at a time, running the Copper and drawing each
    /// line as it ends. Returns lines and frames completed (CIA TOD inputs).
    @discardableResult
    public mutating func advanceChipset(colorClocks: Int) -> (lines: Int, frames: Int) {
        var lines = 0, frames = 0
        for _ in 0..<colorClocks {
            if custom.copperJump != 0 {
                copper.jump(to: custom.copperLocation(custom.copperJump))
                custom.copperJump = 0
            }
            if custom.dmacon & 0x0280 == 0x0280 { stepCopper() }
            if custom.blitPending { runPendingBlit() }
            if custom.diskDMAPending { runPendingDiskDMA() }
            let line = custom.verticalPosition
            let (lineEnded, frameEnded) = custom.stepBeam()
            if lineEnded {
                lines += 1
                renderLine(line)
            }
            if frameEnded {
                frames += 1
                video.frameCount += 1
                copper.jump(to: custom.copperLocation(1))
            }
        }
        return (lines, frames)
    }

    private mutating func stepCopper() {
        if copper.busy > 0 {
            copper.busy -= 1
            return
        }
        let beam = (custom.verticalPosition & 0xFF) << 8 | (custom.horizontalPosition & 0xFE)
        switch copper.state {
        case .halted:
            return
        case .waiting(let position, let mask):
            if beam & mask >= position { copper.state = .fetching }
        case .fetching:
            let first = chipWord(at: copper.programCounter)
            let second = chipWord(at: copper.programCounter &+ 2)
            copper.programCounter = (copper.programCounter &+ 4) & 0x1F_FFFE
            copper.busy = 3
            if first & 1 == 0 { // MOVE
                let register = Int(first & 0x1FE)
                let danger = custom.register(CustomChips.Register.copcon) & 0x02 != 0
                guard register >= 0x80 || (register >= 0x40 && danger) else {
                    copper.state = .halted
                    return
                }
                custom.writeWord(offset: register, value: second)
            } else {
                let mask = (Int(second >> 8) & 0x7F | 0x80) << 8 | Int(second & 0xFE)
                let position = (Int(first >> 8) << 8 | Int(first & 0xFE)) & mask
                if second & 1 == 0 {
                    copper.state = .waiting(position: position, mask: mask)
                } else if beam & mask >= position { // SKIP
                    copper.programCounter = (copper.programCounter &+ 4) & 0x1F_FFFE
                }
            }
        }
    }

    /// Fetches bitplane data for beam line `line` (advancing BPLxPT and adding modulos)
    /// and draws it into `video`.
    private mutating func renderLine(_ line: Int) {
        typealias R = CustomChips.Register
        let background = Video.argb(custom.register(R.color00) & 0xFFF)
        let bplcon0 = custom.register(R.bplcon0)
        let hires = bplcon0 & 0x8000 != 0
        let planes = min(Int(bplcon0 >> 12) & 7, hires ? 4 : 6)
        let diwStart = custom.register(R.diwstrt), diwStop = custom.register(R.diwstop)
        let verticalStart = Int(diwStart >> 8)
        let verticalStop = Int(diwStop >> 8) | (diwStop & 0x8000 == 0 ? 0x100 : 0)
        guard custom.dmacon & 0x0300 == 0x0300, planes > 0,
              line >= verticalStart, line < verticalStop else {
            video.fill(row: line, with: background)
            return
        }
        let fetchStart = Int(custom.register(R.ddfstrt) & 0xFC)
        let fetchStop = Int(custom.register(R.ddfstop) & 0xFC)
        let units = fetchStop >= fetchStart ? (fetchStop - fetchStart) / 8 + 1 : 0
        let words = units * (hires ? 2 : 1)
        var data = [UInt16](repeating: 0, count: planes * words)
        for plane in 0..<planes {
            var pointer = custom.bitplanePointers[plane]
            for word in 0..<words {
                data[plane * words + word] = chipWord(at: pointer)
                pointer &+= 2
            }
            let modulo = Int16(bitPattern: custom.register(plane & 1 == 0 ? R.bpl1mod : R.bpl2mod))
            custom.bitplanePointers[plane] = UInt32(bitPattern: Int32(bitPattern: pointer) &+ Int32(modulo)) & 0x1F_FFFE
        }

        var colors = [UInt32](repeating: 0, count: 64)
        var raw = [UInt16](repeating: 0, count: 32)
        for index in 0..<32 {
            raw[index] = custom.register(R.color00 + index * 2) & 0xFFF
            colors[index] = Video.argb(raw[index])
            colors[index + 32] = Video.argb((raw[index] >> 1) & 0x777) // extra half-brite
        }
        let ham = bplcon0 & 0x0800 != 0 && planes == 6
        let dualPlayfield = bplcon0 & 0x0400 != 0
        let playfield2Priority = custom.register(R.bplcon2) & 0x0040 != 0
        let bplcon1 = Int(custom.register(R.bplcon1))
        let dataStart = fetchStart * 2 + (hires ? 9 : 17) // lowres pixel of the first data bit
        let horizontalStart = Int(diwStart & 0xFF), horizontalStop = Int(diwStop & 0xFF) | 0x100
        let bitCount = words * 16
        var held = raw[0]
        for column in 0..<Video.width {
            let hiresPosition = Video.firstLowresColumn * 2 + column
            let lowres = hiresPosition >> 1
            guard lowres >= horizontalStart, lowres < horizontalStop else {
                video.set(row: line, column: column, background)
                continue
            }
            var index = 0
            for plane in 0..<planes {
                let start = dataStart + (plane & 1 == 0 ? bplcon1 & 0xF : (bplcon1 >> 4) & 0xF)
                let bit = hires ? hiresPosition - start * 2 : lowres - start
                guard bit >= 0, bit < bitCount else { continue }
                let word = data[plane * words + (bit >> 4)]
                index |= Int((word >> (15 - UInt16(bit & 15))) & 1) << plane
            }
            let color: UInt32
            if dualPlayfield {
                let one = (index & 1) | (index >> 1 & 2) | (index >> 2 & 4)
                let two = (index >> 1 & 1) | (index >> 2 & 2) | (index >> 3 & 4)
                if playfield2Priority {
                    color = two != 0 ? colors[8 + two] : colors[one]
                } else {
                    color = one != 0 ? colors[one] : two != 0 ? colors[8 + two] : colors[0]
                }
            } else if ham {
                let value = UInt16(index & 0xF)
                switch index >> 4 {
                case 0: held = raw[index & 0xF]
                case 1: held = (held & 0xFF0) | value
                case 2: held = (held & 0x0FF) | value << 8
                default: held = (held & 0xF0F) | value << 4
                }
                color = Video.argb(held)
            } else {
                color = colors[index]
            }
            video.set(row: line, column: column, color)
        }
    }
}
