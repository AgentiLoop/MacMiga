/// Blitter. A blit runs to completion as soon as it is started (BLTSIZE, or BLTSIZH on an
/// ECS Agnus, written with DMAEN and BLTEN set), so BBUSY never reads 1 and blit timing/bus contention is not
/// modelled. Supports area mode (A/B/C/D channels, shifts, first/last-word masks,
/// minterms, ascending and descending order, modulos, inclusive/exclusive fill with FCI)
/// and line mode (octants, SING; texture bit order is unverified). On completion BZERO is updated, the pointers
/// hold their final values and INTREQ BLIT (bit 6) is raised. Pipeline quirks are ignored.
extension AmigaMemory {
    mutating func writeChipWord(_ value: UInt16, at address: UInt32) {
        let index = Int(address) & (chipRAM.count - 2)
        chipRAM[index] = UInt8(value >> 8)
        chipRAM[index + 1] = UInt8(truncatingIfNeeded: value)
    }

    static func minterm(_ a: UInt16, _ b: UInt16, _ c: UInt16, _ function: UInt16) -> UInt16 {
        var d: UInt16 = 0
        if function & 0x01 != 0 { d |= ~a & ~b & ~c }
        if function & 0x02 != 0 { d |= ~a & ~b & c }
        if function & 0x04 != 0 { d |= ~a & b & ~c }
        if function & 0x08 != 0 { d |= ~a & b & c }
        if function & 0x10 != 0 { d |= a & ~b & ~c }
        if function & 0x20 != 0 { d |= a & ~b & c }
        if function & 0x40 != 0 { d |= a & b & ~c }
        if function & 0x80 != 0 { d |= a & b & c }
        return d
    }

    /// Runs a pending blit if Blitter DMA is enabled.
    mutating func runPendingBlit() {
        guard custom.blitPending, custom.dmacon & 0x0240 == 0x0240 else { return }
        custom.blitPending = false
        let zero = custom.register(CustomChips.Register.bltcon1) & 1 != 0
            ? lineBlit(steps: custom.blitHeight) : areaBlit(width: custom.blitWidth, height: custom.blitHeight)
        custom.blitterZero = zero
        custom.requestInterrupt(bits: 0x0040)
    }

    private mutating func areaBlit(width: Int, height: Int) -> Bool {
        typealias R = CustomChips.Register
        let con0 = custom.register(R.bltcon0), con1 = custom.register(R.bltcon1)
        let useA = con0 & 0x0800 != 0, useB = con0 & 0x0400 != 0
        let useC = con0 & 0x0200 != 0, useD = con0 & 0x0100 != 0
        let shiftA = Int(con0 >> 12), shiftB = Int(con1 >> 12)
        let descending = con1 & 0x0002 != 0
        let fill = con1 & 0x0018 != 0, inclusive = con1 & 0x0008 != 0
        let step: Int32 = descending ? -2 : 2
        func modulo(_ register: Int) -> Int32 {
            let value = Int32(Int16(bitPattern: custom.register(register)))
            return descending ? -value : value
        }
        let modA = modulo(R.bltamod), modB = modulo(R.bltbmod)
        let modC = modulo(R.bltcmod), modD = modulo(R.bltdmod)
        var (pc, pb, pa, pd) = (custom.blitterPointers[0], custom.blitterPointers[1],
                                custom.blitterPointers[2], custom.blitterPointers[3])
        var a = custom.register(R.bltadat), b = custom.register(R.bltbdat), c = custom.register(R.bltcdat)
        let firstMask = custom.register(R.bltafwm), lastMask = custom.register(R.bltalwm)
        var previousA: UInt32 = 0, previousB: UInt32 = 0
        var allZero = true
        func advance(_ pointer: inout UInt32, by delta: Int32) {
            pointer = UInt32(bitPattern: Int32(bitPattern: pointer) &+ delta) & 0x1F_FFFE
        }
        for _ in 0..<height {
            var carry = con1 & 0x0004 != 0
            for x in 0..<width {
                if useA { a = chipWord(at: pa); advance(&pa, by: step) }
                if useB { b = chipWord(at: pb); advance(&pb, by: step) }
                if useC { c = chipWord(at: pc); advance(&pc, by: step) }
                var masked = a
                if x == 0 { masked &= firstMask }
                if x == width - 1 { masked &= lastMask }
                let shiftedA: UInt16, shiftedB: UInt16
                if descending {
                    shiftedA = UInt16(truncatingIfNeeded: (UInt32(masked) << 16 | previousA) >> (16 - shiftA))
                    shiftedB = UInt16(truncatingIfNeeded: (UInt32(b) << 16 | previousB) >> (16 - shiftB))
                } else {
                    shiftedA = UInt16(truncatingIfNeeded: (previousA << 16 | UInt32(masked)) >> shiftA)
                    shiftedB = UInt16(truncatingIfNeeded: (previousB << 16 | UInt32(b)) >> shiftB)
                }
                previousA = UInt32(masked)
                previousB = UInt32(b)
                var d = Self.minterm(shiftedA, shiftedB, c, con0 & 0xFF)
                if fill {
                    var result: UInt16 = 0
                    for bit in 0..<16 {
                        let set = d & (1 << bit) != 0
                        if inclusive ? (carry || set) : (carry != set) { result |= 1 << bit }
                        if set { carry.toggle() }
                    }
                    d = result
                }
                if d != 0 { allZero = false }
                if useD { writeChipWord(d, at: pd); advance(&pd, by: step) }
            }
            if useA { advance(&pa, by: modA) }
            if useB { advance(&pb, by: modB) }
            if useC { advance(&pc, by: modC) }
            if useD { advance(&pd, by: modD) }
        }
        custom.blitterPointers = [pc, pb, pa, pd]
        return allZero
    }

    /// Bresenham line drawing as set up by graphics.library: BLTAPTL holds the error
    /// term, BLTAMOD/BLTBMOD its increments, ASH the starting pixel, C/D the start word.
    private mutating func lineBlit(steps: Int) -> Bool {
        typealias R = CustomChips.Register
        let con0 = custom.register(R.bltcon0), con1 = custom.register(R.bltcon1)
        let rowModulo = Int32(Int16(bitPattern: custom.register(R.bltcmod)))
        let errorStep = Int32(Int16(bitPattern: custom.register(R.bltamod)))
        let errorStepNegative = Int32(Int16(bitPattern: custom.register(R.bltbmod)))
        let single = con1 & 0x0002 != 0
        let sometimesVertical = con1 & 0x0010 != 0 // SUD: Y is the minor axis
        var error = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: custom.blitterPointers[2])))
        var negative = con1 & 0x0040 != 0
        var shift = Int(con0 >> 12)
        let a = custom.register(R.bltadat) & custom.register(R.bltafwm)
        let bShift = Int(con1 >> 12)
        let texture = custom.register(R.bltbdat)
        var pattern = bShift == 0 ? texture : texture >> UInt16(bShift) | texture << UInt16(16 - bShift)
        var pointer = custom.blitterPointers[0]
        var dottedThisRow = false
        var allZero = true
        func stepX(decrement: Bool) {
            if decrement {
                if shift == 0 { shift = 15; pointer = (pointer &- 2) & 0x1F_FFFE } else { shift -= 1 }
            } else {
                if shift == 15 { shift = 0; pointer = (pointer &+ 2) & 0x1F_FFFE } else { shift += 1 }
            }
        }
        func stepY(decrement: Bool) {
            let delta = decrement ? -rowModulo : rowModulo
            pointer = UInt32(bitPattern: Int32(bitPattern: pointer) &+ delta) & 0x1F_FFFE
            dottedThisRow = false
        }
        for _ in 0..<steps {
            var dot = a >> UInt16(shift)
            if single && dottedThisRow { dot = 0 }
            let b: UInt16 = pattern & 1 != 0 ? 0xFFFF : 0
            let c = chipWord(at: pointer)
            let d = Self.minterm(dot, b, c, con0 & 0xFF)
            if d != 0 { allZero = false }
            writeChipWord(d, at: pointer)
            if dot != 0 { dottedThisRow = true }
            // Minor axis moves only while the error term is non-negative.
            if !negative {
                if sometimesVertical { stepY(decrement: con1 & 0x0008 != 0) }
                else { stepX(decrement: con1 & 0x0008 != 0) }
            }
            if sometimesVertical { stepX(decrement: con1 & 0x0004 != 0) }
            else { stepY(decrement: con1 & 0x0004 != 0) }
            error &+= negative ? errorStepNegative : errorStep
            negative = Int16(truncatingIfNeeded: error) < 0
            pattern = pattern << 1 | pattern >> 15
        }
        custom.blitterPointers[0] = pointer
        custom.blitterPointers[3] = pointer
        custom.blitterPointers[2] = (custom.blitterPointers[2] & 0x1F_0000) | UInt32(UInt16(truncatingIfNeeded: error))
        return allZero
    }
}
