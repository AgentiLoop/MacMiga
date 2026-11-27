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
/// and extra half-brite) are drawn per line with the bitplane/control registers in effect
/// at the end of that line. Colour register writes (Copper or CPU) take effect from the
/// colour clock at which they happened, so mid-line palette changes split the line
/// (Denise's few-pixel output delay is not modelled). Collision detection and interlace
/// are not implemented.
public struct Video: Equatable, Sendable {
    public static let width = 736
    public static let height = CustomChips.linesPerFrame
    public static let firstLowresColumn = 0x58

    public private(set) var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
    /// Number of frames completed since power-on.
    public internal(set) var frameCount = 0
    /// Beam lines on which bitplanes were shown in the last completed frame (nil if none).
    public internal(set) var displayedLines: ClosedRange<Int>?
    /// The same range for the frame being drawn.
    var displayingLines: ClosedRange<Int>?
    /// Columns (hires, as in `pixels`) of the display window on those lines, widest extent
    /// over the frame (nil if none).
    public internal(set) var displayedColumns: ClosedRange<Int>?
    var displayingColumns: ClosedRange<Int>?
    /// The last completed frame used beam lines only a PAL frame has (262–311): the Copper
    /// was set to wait for one, or bitplanes were shown with a display window reaching into
    /// them. A game made for NTSC never does either (see `AmigaMemory.autoVideoStandard`).
    public internal(set) var usedPALLines = false
    var usingPALLines = false
    /// Auto video standard: frames in a row with PAL-only lines used, frames showing
    /// bitplanes without them since the last such frame, and how many of those switch to
    /// NTSC (doubled each time PAL lines bring the machine back to PAL, so a game that uses
    /// them only now and then settles on PAL).
    var palFrames = 0, quietFrames = 0, framesToNTSC = 150

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
    /// Chip RAM word as seen by DMA (the address wraps at the size of chip RAM).
    func chipWord(at address: UInt32) -> UInt16 {
        let index = Int(address) & (chipRAM.count - 2)
        return UInt16(chipRAM[index]) << 8 | UInt16(chipRAM[index + 1])
    }

    /// Advances the beam, running the Copper and drawing each line as it ends. Colour clocks
    /// in which the Copper only counts down are taken in one step, up to the end of the
    /// line; the result is the same as stepping one colour clock at a time.
    /// Returns lines and frames completed (CIA TOD inputs).
    @discardableResult
    public mutating func advanceChipset(colorClocks: Int) -> (lines: Int, frames: Int) {
        var lines = 0, frames = 0
        var remaining = colorClocks
        while remaining > 0 {
            if custom.copperJump != 0 {
                copper.jump(to: custom.copperLocation(custom.copperJump))
                custom.copperJump = 0
            }
            var count = min(remaining, CustomChips.colorClocksPerLine - custom.horizontalPosition)
            if custom.dmacon & 0x0280 == 0x0280 {
                let idle = copperIdleClocks(limit: count)
                if idle > 0 {
                    count = idle
                    copper.busy = max(copper.busy - idle, 0)
                } else {
                    count = 1
                    stepCopper()
                }
            }
            if custom.blitPending { runPendingBlit() }
            if custom.diskDMAPending { runPendingDiskDMA() }
            if custom.diskBlockDelay > 0 {
                custom.diskBlockDelay -= count
                if custom.diskBlockDelay <= 0 {
                    custom.diskBlockDelay = 0
                    custom.requestInterrupt(bits: 0x0002) // DSKBLK
                }
            }
            stepAudio(colorClocks: count)
            remaining -= count
            let line = custom.verticalPosition
            let (lineEnded, frameEnded) = custom.stepBeam(colorClocks: count)
            if lineEnded {
                lines += 1
                renderLine(line)
                custom.colorChanges.removeAll(keepingCapacity: true)
                updateSprites(line)
            }
            if frameEnded {
                frames += 1
                video.frameCount += 1
                video.displayedLines = video.displayingLines
                video.displayingLines = nil
                video.displayedColumns = video.displayingColumns
                video.displayingColumns = nil
                video.usedPALLines = video.usingPALLines
                video.usingPALLines = false
                if autoVideoStandard { autoSwitchVideoStandard() }
                copper.jump(to: custom.copperLocation(1))
                for index in 0..<8 { custom.sprites[index].dma = .idle }
            }
        }
        return (lines, frames)
    }

    /// Frames with PAL evidence before an NTSC machine switches to PAL.
    static let framesToPAL = 2

    /// Auto video standard, at the end of a frame (see `autoVideoStandard`). Frames without
    /// bitplanes (loading, blank screens) neither count towards NTSC nor reset the count.
    private mutating func autoSwitchVideoStandard() {
        if video.usedPALLines {
            video.palFrames += 1
            video.quietFrames = 0
        } else {
            video.palFrames = 0
            if video.displayedLines != nil { video.quietFrames += 1 }
        }
        if custom.ntsc ? video.palFrames >= Self.framesToPAL : video.quietFrames >= video.framesToNTSC {
            custom.ntsc.toggle()
            if custom.ntsc {
                // Lines an NTSC frame no longer draws would keep the last PAL picture.
                for row in CustomChips.ntscLinesPerFrame..<Video.height { video.fill(row: row, with: 0xFF00_0000) }
            } else {
                video.framesToNTSC *= 2
            }
            video.palFrames = 0
            video.quietFrames = 0
        }
    }

    /// Colour clocks from now, at most `limit` and all on the current line, in which the
    /// Copper does nothing but count down: it is busy with the instruction it fetched, halted,
    /// or waiting for a beam position that the rest of this line cannot reach.
    private func copperIdleClocks(limit: Int) -> Int {
        if copper.busy > 0 { return min(limit, copper.busy) }
        switch copper.state {
        case .halted:
            return limit
        case .fetching:
            return 0
        case .waiting(let position, let mask):
            // Largest masked beam value any horizontal position of this line can give.
            let vertical = (custom.verticalPosition & 0xFF) << 8 & mask
            let horizontal = min(mask & 0xFE, CustomChips.colorClocksPerLine - 1)
            return vertical | horizontal < position ? limit : 0
        }
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
                    // Past line 255 the vertical byte means line 256 + VP. A wait for one of
                    // the PAL-only lines (a WAIT beyond the frame, like $FFFF, ends the list).
                    // The usual WAIT $FFDF wakes at the end of line 255 and the next WAIT is
                    // fetched there, so the end of line 255 counts as past it.
                    if custom.verticalPosition + (custom.horizontalPosition >= 0xD8 ? 1 : 0) >= 0x100 {
                        let target = 0x100 | Int(first >> 8)
                        if target >= CustomChips.ntscLinesPerFrame && target < CustomChips.linesPerFrame {
                            video.usingPALLines = true
                        }
                    }
                } else if beam & mask >= position { // SKIP
                    copper.programCounter = (copper.programCounter &+ 4) & 0x1F_FFFE
                }
            }
        }
    }

    /// First line on which Agnus fetches sprite control words (end of PAL vertical blank).
    static let firstSpriteLine = 25

    /// Sprite DMA for `line` (control words on the first line and at VSTOP, data words
    /// between VSTART and VSTOP), then draws armed sprites over the line. Sprites are
    /// always drawn in front of the playfields (BPLCON2 priorities and collisions are not
    /// modelled) and clipped to the horizontal display window.
    private mutating func updateSprites(_ line: Int) {
        if custom.dmacon & 0x0220 == 0x0220 {
            for index in 0..<8 {
                var sprite = custom.sprites[index]
                var pointer = custom.spritePointers[index]
                func fetchControl() {
                    sprite.position = chipWord(at: pointer)
                    sprite.control = chipWord(at: pointer &+ 2)
                    sprite.armed = false
                    sprite.dma = .waiting
                    pointer = (pointer &+ 4) & 0x1F_FFFE
                }
                if line == Self.firstSpriteLine && sprite.dma == .idle { fetchControl() }
                if sprite.dma == .waiting && line == sprite.verticalStart && line > Self.firstSpriteLine {
                    sprite.dma = .active
                }
                if sprite.dma == .active {
                    if line == sprite.verticalStop {
                        fetchControl()
                    } else {
                        sprite.dataA = chipWord(at: pointer)
                        sprite.dataB = chipWord(at: pointer &+ 2)
                        sprite.armed = true
                        pointer = (pointer &+ 4) & 0x1F_FFFE
                    }
                }
                custom.sprites[index] = sprite
                custom.spritePointers[index] = pointer
            }
        }
        let sprites = custom.sprites
        guard sprites.contains(where: { $0.armed }) else { return }
        typealias R = CustomChips.Register
        let diwStart = custom.register(R.diwstrt), diwStop = custom.register(R.diwstop)
        let left = Int(diwStart & 0xFF), right = Int(diwStop & 0xFF) | 0x100
        for index in stride(from: 7, through: 0, by: -1) where sprites[index].armed {
            let sprite = sprites[index]
            let pair = index & ~1
            let attached = index & 1 == 1 ? sprite.attached : sprites[index | 1].attached && sprites[index | 1].armed
            if attached && index & 1 == 1 { continue } // drawn together with its even partner
            let partner = sprites[index | 1]
            for pixel in 0..<16 {
                let shift = UInt16(15 - pixel)
                var value = Int(sprite.dataA >> shift & 1) | Int(sprite.dataB >> shift & 1) << 1
                if attached {
                    value |= Int(partner.dataA >> shift & 1) << 2 | Int(partner.dataB >> shift & 1) << 3
                }
                guard value != 0 else { continue }
                let x = sprite.horizontalStart + pixel
                guard x >= left, x < right else { continue }
                let column = (x - Video.firstLowresColumn) * 2
                guard column >= 0, column + 1 < Video.width else { continue }
                let colorIndex = attached ? 16 + value : 16 + pair * 2 + value
                let color = Video.argb(custom.register(R.color00 + colorIndex * 2) & 0xFFF)
                video.set(row: line, column: column, color)
                video.set(row: line, column: column + 1, color)
            }
        }
    }

    /// The bits of a bitplane byte spread over a 64-bit word, leftmost pixel in the lowest
    /// byte, so that eight pixels of a plane join their colour indices with one shift and OR.
    static let pixelSpread: [UInt64] = (0..<256).map { (byte: Int) -> UInt64 in
        var spread: UInt64 = 0
        for pixel in 0..<8 where byte & (0x80 >> pixel) != 0 { spread |= 1 << UInt64(pixel * 8) }
        return spread
    }

    /// Fetches bitplane data for beam line `line` (advancing BPLxPT and adding modulos)
    /// and draws it into `video`.
    private mutating func renderLine(_ line: Int) {
        typealias R = CustomChips.Register
        var raw = [UInt16](repeating: 0, count: 32)
        for index in 0..<32 { raw[index] = custom.register(R.color00 + index * 2) & 0xFFF }
        let changes = custom.colorChanges
        for change in changes.reversed() { raw[change.index] = change.previous } // palette at line start
        var colors = [UInt32](repeating: 0, count: 64)
        for index in 0..<32 {
            colors[index] = Video.argb(raw[index])
            colors[index + 32] = Video.argb((raw[index] >> 1) & 0x777) // extra half-brite
        }
        var nextChange = 0
        /// Applies colour writes made at or before the colour clock showing `column`.
        func applyChanges(upTo column: Int) {
            let clock = (Video.firstLowresColumn * 2 + column) >> 2
            while nextChange < changes.count && changes[nextChange].position <= clock {
                let change = changes[nextChange]
                raw[change.index] = change.value
                colors[change.index] = Video.argb(change.value)
                colors[change.index + 32] = Video.argb((change.value >> 1) & 0x777)
                nextChange += 1
            }
        }
        let bplcon0 = custom.register(R.bplcon0)
        let hires = bplcon0 & 0x8000 != 0
        let planes = min(Int(bplcon0 >> 12) & 7, hires ? 4 : 6)
        let diwStart = custom.register(R.diwstrt), diwStop = custom.register(R.diwstop)
        let verticalStart = Int(diwStart >> 8)
        let verticalStop = Int(diwStop >> 8) | (diwStop & 0x8000 == 0 ? 0x100 : 0)
        guard custom.dmacon & 0x0300 == 0x0300, planes > 0,
              line >= verticalStart, line < verticalStop else {
            if changes.isEmpty {
                video.fill(row: line, with: colors[0])
            } else {
                for column in 0..<Video.width {
                    applyChanges(upTo: column)
                    video.set(row: line, column: column, colors[0])
                }
            }
            return
        }
        video.displayingLines = video.displayingLines.map { min($0.lowerBound, line)...line } ?? line...line
        if verticalStop > CustomChips.ntscLinesPerFrame { video.usingPALLines = true }
        let firstColumn = max((Int(diwStart & 0xFF) - Video.firstLowresColumn) * 2, 0)
        let lastColumn = min(((Int(diwStop & 0xFF) | 0x100) - Video.firstLowresColumn) * 2, Video.width) - 1
        if firstColumn <= lastColumn {
            video.displayingColumns = video.displayingColumns.map {
                min($0.lowerBound, firstColumn)...max($0.upperBound, lastColumn)
            } ?? firstColumn...lastColumn
        }
        let fetchStart = Int(custom.register(R.ddfstrt) & 0xFC)
        let fetchStop = Int(custom.register(R.ddfstop) & 0xFC)
        // Fetch runs in 8-colour-clock units from DDFSTRT; the unit in progress when DDFSTOP
        // is reached is completed (hires DDF values are 4-aligned, e.g. $3C-$D0 = 20 units).
        let units = fetchStop >= fetchStart ? (fetchStop - fetchStart + 7) / 8 + 1 : 0
        let words = units * (hires ? 2 : 1)
        // Planar to chunky, eight pixels per table lookup: byte k of an element holds the
        // colour index bits of data bit k. Even planes fill the first half and odd planes the
        // second, because BPLCON1 scrolls them separately.
        let spread = Self.pixelSpread
        var chunky = [UInt64](repeating: 0, count: words * 4)
        for plane in 0..<planes {
            var pointer = custom.bitplanePointers[plane]
            let base = (plane & 1) * words * 2
            for word in 0..<words {
                let value = chipWord(at: pointer)
                chunky[base + word * 2] |= spread[Int(value >> 8)] << UInt64(plane)
                chunky[base + word * 2 + 1] |= spread[Int(value & 0xFF)] << UInt64(plane)
                pointer &+= 2
            }
            let modulo = Int16(bitPattern: custom.register(plane & 1 == 0 ? R.bpl1mod : R.bpl2mod))
            custom.bitplanePointers[plane] = UInt32(bitPattern: Int32(bitPattern: pointer) &+ Int32(modulo)) & 0x1F_FFFE
        }

        let ham = bplcon0 & 0x0800 != 0 && planes == 6
        let dualPlayfield = bplcon0 & 0x0400 != 0
        let playfield2Priority = custom.register(R.bplcon2) & 0x0040 != 0
        let bplcon1 = Int(custom.register(R.bplcon1))
        let dataStart = fetchStart * 2 + (hires ? 9 : 17) // lowres pixel of the first data bit
        let horizontalStart = Int(diwStart & 0xFF), horizontalStop = Int(diwStop & 0xFF) | 0x100
        let bitCount = words * 16
        // Position of the first data bit of the even and odd planes (they scroll separately),
        // in the unit the data advances by: hires pixels in hires, lowres pixels otherwise.
        let evenOrigin = (dataStart + (bplcon1 & 0xF)) * (hires ? 2 : 1)
        let oddOrigin = (dataStart + ((bplcon1 >> 4) & 0xF)) * (hires ? 2 : 1)
        var held = raw[0]
        var color = colors[0]
        for column in 0..<Video.width {
            // A lowres pixel is two columns wide and colour changes land on 4-column
            // boundaries, so its second column repeats the first.
            if !hires && column & 1 == 1 {
                video.set(row: line, column: column, color)
                continue
            }
            if nextChange < changes.count { applyChanges(upTo: column) }
            let hiresPosition = Video.firstLowresColumn * 2 + column
            let lowres = hiresPosition >> 1
            guard lowres >= horizontalStart, lowres < horizontalStop else {
                color = colors[0]
                video.set(row: line, column: column, color)
                continue
            }
            let position = hires ? hiresPosition : lowres
            let evenBit = position - evenOrigin, oddBit = position - oddOrigin
            var index = 0
            if evenBit >= 0, evenBit < bitCount {
                index = Int(UInt8(truncatingIfNeeded: chunky[evenBit >> 3] >> UInt64((evenBit & 7) * 8)))
            }
            if oddBit >= 0, oddBit < bitCount {
                index |= Int(UInt8(truncatingIfNeeded: chunky[words * 2 + (oddBit >> 3)] >> UInt64((oddBit & 7) * 8)))
            }
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
