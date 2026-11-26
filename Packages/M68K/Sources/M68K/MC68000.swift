public enum CPUError: Error, Equatable {
    case unsupportedInstruction(opcode: UInt16, address: UInt32)
    /// A word or long access to an odd address (24-bit), thrown instead of taking the
    /// exception when `stopsOnAddressError` is set or while an exception frame is written.
    case addressError(address: UInt32, isWrite: Bool)
}

/// Functional MC68000. It knows nothing about the machine around it: every memory access goes
/// through the `M68KBus` passed to each call, and the machine presents interrupts with
/// `interrupt(level:memory:)`. `step` returns the time each instruction takes in CPU clocks,
/// from tables 8-1 to 8-14 of the MC68000 User's Manual (MC68000UM); where both
/// SingleStepTests sets have another figure than the printed table, a comment says so. The
/// bus cycles inside an instruction and the prefetch queue are not modelled.
///
/// The members are `@inlinable` so that a client module compiles the generic code
/// specialized for its own bus type.
public struct MC68000: Equatable, Sendable {
    /// Eight 32-bit registers stored inside the CPU value itself, so that copying the CPU
    /// (every instruction works on a copy and commits it on success) is a plain memory copy
    /// with no allocation or reference counting.
    @usableFromInline struct Registers: Equatable, Sendable {
        @usableFromInline var r0: UInt32 = 0
        @usableFromInline var r1: UInt32 = 0
        @usableFromInline var r2: UInt32 = 0
        @usableFromInline var r3: UInt32 = 0
        @usableFromInline var r4: UInt32 = 0
        @usableFromInline var r5: UInt32 = 0
        @usableFromInline var r6: UInt32 = 0
        @usableFromInline var r7: UInt32 = 0

        @inlinable init() {}

        @inlinable subscript(index: Int) -> UInt32 {
            get {
                precondition((0..<8).contains(index))
                return withUnsafeBytes(of: self) { $0.load(fromByteOffset: index * 4, as: UInt32.self) }
            }
            set {
                precondition((0..<8).contains(index))
                withUnsafeMutableBytes(of: &self) { $0.storeBytes(of: newValue, toByteOffset: index * 4, as: UInt32.self) }
            }
        }
    }

    @usableFromInline var dataRegisters = Registers()
    /// A0–A6; A7 is `userStackPointer` or `supervisorStackPointer` (the eighth slot is unused).
    @usableFromInline var addressRegisters = Registers()
    @usableFromInline var status: UInt16 = 0x2700
    public var programCounter: UInt32 = 0
    public var userStackPointer: UInt32 = 0
    public var supervisorStackPointer: UInt32 = 0
    /// Set by STOP; the CPU executes nothing until an accepted interrupt clears it.
    @inlinable public var isStopped: Bool { stopped }
    /// The opcode after a RESET instruction, fetched before the devices were reset, as the
    /// 68000's prefetch does. Software relies on it when the reset changes the memory map
    /// under the running code (`RESET` followed by a one-word `JMP (An)`).
    @usableFromInline var prefetchedOpcode: UInt16?
    @usableFromInline var stopped = false
    /// CPU clocks of the instruction in progress. `step` returns the sum and clears it, so
    /// it is 0 whenever a caller can see the CPU and never takes part in a comparison.
    @usableFromInline var clocks = 0
    /// CPU clocks from accepting an interrupt to the first instruction of its handler.
    public static let interruptClocks = 44
    /// When false (hardware behaviour), unassigned opcodes and invalid addressing modes take the
    /// illegal-instruction exception (vector 4, stacked PC = the opcode's address). When true,
    /// `step` throws `CPUError.unsupportedInstruction` instead, for decoder diagnostics.
    public var stopsOnIllegalInstruction = false
    /// When false (hardware behaviour), a word/long access to an odd address takes the address
    /// error exception (vector 3, 14-byte group 0 frame). When true, `step` throws
    /// `CPUError.addressError` instead. Either way the bus never sees the access.
    public var stopsOnAddressError = false
    /// When false (hardware behaviour), an instruction started with SR's T bit set is followed
    /// by the trace exception. When true, `step` ends with the instruction, as the
    /// SingleStepTests sets record it.
    public var stopsBeforeTrace = false

    /// Deterministic host initialization, not a claim about hardware power-on register values.
    @inlinable public init() {}

    /// Host/debugger access. Only the MC68000's implemented status bits are retained.
    @inlinable public var statusRegister: UInt16 {
        get { status }
        set { status = newValue & 0xA71F }
    }

    @inlinable public subscript(data index: Int) -> UInt32 {
        get { dataRegisters[index] }
        set { dataRegisters[index] = newValue }
    }

    /// A7 selects SSP or USP according to the status register's supervisor bit.
    @inlinable public subscript(address index: Int) -> UInt32 {
        get {
            precondition((0..<8).contains(index))
            if index == 7 {
                return status & 0x2000 != 0 ? supervisorStackPointer : userStackPointer
            }
            return addressRegisters[index]
        }
        set {
            precondition((0..<8).contains(index))
            if index == 7 {
                if status & 0x2000 != 0 { supervisorStackPointer = newValue }
                else { userStackPointer = newValue }
            } else {
                addressRegisters[index] = newValue
            }
        }
    }

    /// External machine reset, not the RESET opcode: loads SSP from address 0 and PC from
    /// address 4. General registers and CCR are retained. The machine resets its own devices.
    @inlinable public mutating func reset<Bus: M68KBus>(memory: inout Bus) throws {
        let stackPointer = try memory.readAlignedLong(at: 0)
        let entry = try memory.readAlignedLong(at: 4)
        status = (status & 0x001F) | 0x2700
        prefetchedOpcode = nil
        supervisorStackPointer = stackPointer
        programCounter = entry
    }

    /// Executes one supported instruction and returns the CPU clocks it took (0 while the
    /// CPU is stopped). PC is the next instruction address on success.
    /// On failure CPU registers remain unchanged; earlier bus writes are not rolled back.
    /// Errors are host diagnostics, not hardware exception processing.
    /// Group 1/2 exceptions (TRAP, privilege violation, divide by zero, illegal, line A/F)
    /// are processed by pushing PC and SR on the supervisor stack and jumping through the
    /// vector table. Bus errors are not modelled; see `interrupt(level:memory:)`.
    /// Trace: when SR's T bit is set as an instruction starts, the trace exception (vector 9)
    /// follows it, with the next instruction's address stacked. It also follows TRAP, TRAPV,
    /// CHK and a division by zero (stacking their handler's address), and ends STOP; it does
    /// not follow an illegal instruction, line A/F, a privilege violation or an address error.
    @discardableResult
    @inlinable public mutating func step<Bus: M68KBus>(memory: inout Bus) throws -> Int {
        guard !isStopped else { return 0 }
        let prefetched = prefetchedOpcode
        prefetchedOpcode = nil
        let instructionAddress = programCounter
        var traced = status & 0x8000 != 0 && !stopsBeforeTrace
        do {
            do {
                try execute(prefetched: prefetched, memory: &memory)
                // A jump to an odd address faults at once: the 68000 fetches the first word
                // at the target before the instruction ends, with the jump still in IR.
                if programCounter & 1 != 0, instructionAddress & 1 == 0, !stopsOnAddressError {
                    let opcode = try prefetched ?? memory.readAlignedWord(at: instructionAddress)
                    // A branch (Bcc, BRA, BSR) stacks its own address + 2 instead of the target;
                    // Rob Northen's Copylock sums its code up to that address.
                    try enterAddressError(accessAddress: programCounter, write: false, instruction: opcode,
                                          stackedPC: opcode & 0xF000 == 0x6000 ? instructionAddress &+ 2 : nil, memory: &memory)
                    clocks += 50
                    traced = false
                }
            } catch let trap as Trap {
                if let registers = trap.registers { self = registers }
                if let condition = trap.condition { status = (status & 0xFF00) | condition }
                try enterException(vector: trap.vector, returnAddress: trap.returnAddress, memory: &memory)
                // CHK 40, division by zero 38, the others (illegal, privilege, TRAP, TRAPV,
                // line A and F) 34; `registers` brought the operand's time with them.
                clocks += trap.vector == 6 ? 40 : trap.vector == 5 ? 38 : 34
                traced = traced && (5...7 ~= trap.vector || 32...47 ~= trap.vector)
            } catch CPUError.unsupportedInstruction(_, let address) where !stopsOnIllegalInstruction {
                try enterException(vector: 4, returnAddress: address, memory: &memory)
                clocks += 34
                traced = false
            } catch CPUError.addressError(let address, let isWrite) where !stopsOnAddressError {
                try enterAddressError(accessAddress: address, write: isWrite, memory: &memory)
                clocks += 50
                traced = false
            }
            if traced {
                stopped = false
                prefetchedOpcode = nil
                try enterException(vector: 9, returnAddress: programCounter, memory: &memory)
                clocks += 34
            }
        } catch {
            clocks = 0
            prefetchedOpcode = prefetched
            throw error
        }
        let used = clocks
        clocks = 0
        return used
    }

    /// Group 0 frame (MC68000UM 6.3.9.1), from SSP upwards: special status word (R/W bit 4,
    /// I/N bit 3 = 0, function code bits 0–2; the undocumented upper bits are those of the
    /// instruction register), access address (all 32 bits), instruction register, SR, PC.
    /// `instruction` is the opcode of a jump whose target is odd; for a fetch at an odd PC
    /// that no instruction led to, the instruction register is stacked as 0. The stacked PC is
    /// the faulting address for an odd opcode fetch, else the instruction address + 2 (real
    /// hardware stacks a value 2–10 bytes past it). A fault while writing this frame (odd SSP)
    /// would halt a real 68000; here `CPUError.addressError` is thrown. `stackedPC`, if given,
    /// replaces the stacked PC.
    @inlinable mutating func enterAddressError<Bus: M68KBus>(accessAddress: UInt32, write: Bool,
                                            instruction: UInt16? = nil, stackedPC: UInt32? = nil,
                                            memory: inout Bus) throws {
        let fetch = !write && accessAddress == programCounter
        let opcode = try instruction ?? (fetch ? 0 : memory.readAlignedWord(at: programCounter))
        let supervisor: UInt16 = status & 0x2000 != 0 ? 4 : 0
        let special = (opcode & 0xFFE0) | (write ? 0 : 0x10) | supervisor | (fetch ? 2 : 1)
        var next = self
        next.status = (status | 0x2000) & 0x7FFF
        let stackPointer = next.supervisorStackPointer &- 14
        try memory.writeAlignedLong(stackedPC ?? (fetch ? programCounter : programCounter &+ 2), at: stackPointer &+ 10)
        try memory.writeAlignedWord(status, at: stackPointer &+ 8)
        try memory.writeAlignedWord(opcode, at: stackPointer &+ 6)
        try memory.writeAlignedLong(accessAddress, at: stackPointer &+ 2)
        try memory.writeAlignedWord(special, at: stackPointer)
        next.supervisorStackPointer = stackPointer
        next.programCounter = try memory.readAlignedLong(at: 3 * 4)
        self = next
    }

    /// Presents an autovectored interrupt at `level` (1–7). It is accepted when the level is 7
    /// or above the SR interrupt mask: SR and PC are stacked, the mask is raised to `level`,
    /// STOP is ended and execution continues at vector 24 + level. Returns whether accepted.
    /// Level 7 is treated as level-sensitive here; real hardware makes it edge-triggered.
    @discardableResult
    @inlinable public mutating func interrupt<Bus: M68KBus>(level: Int, memory: inout Bus) throws -> Bool {
        guard (1...7).contains(level), level == 7 || level > Int((status >> 8) & 7) else { return false }
        var next = self
        next.stopped = false
        next.prefetchedOpcode = nil
        try next.enterException(vector: 24 + level, returnAddress: programCounter, memory: &memory)
        next.status = (next.status & 0xF8FF) | UInt16(level) << 8
        self = next
        return true
    }

    /// Pending exception raised by an instruction. CPU state is as before the instruction
    /// when it is thrown, with two exceptions: `condition`, if given, replaces the CCR before
    /// stacking (CHK sets N, a division by zero clears N, Z, V and C), and `registers`, if
    /// given, are the registers after the operand was fetched (CHK and the divisions trap
    /// after `(An)+` or `-(An)` has changed An).
    @usableFromInline struct Trap: Error {
        @usableFromInline let vector: Int
        @usableFromInline let returnAddress: UInt32
        @usableFromInline var condition: UInt16?
        @usableFromInline var registers: MC68000?

        @inlinable init(vector: Int, returnAddress: UInt32, condition: UInt16? = nil, registers: MC68000? = nil) {
            self.vector = vector
            self.returnAddress = returnAddress
            self.condition = condition
            self.registers = registers
        }
    }

    /// 68000 short exception frame: SR at SSP, return PC at SSP+2. Enters supervisor, clears trace.
    @inlinable mutating func enterException<Bus: M68KBus>(vector: Int, returnAddress: UInt32,
                                         memory: inout Bus) throws {
        var next = self
        next.status = (status | 0x2000) & 0x7FFF
        let stackPointer = next.supervisorStackPointer &- 6
        try memory.writeAlignedLong(returnAddress, at: stackPointer &+ 2)
        try memory.writeAlignedWord(status, at: stackPointer)
        next.supervisorStackPointer = stackPointer
        next.programCounter = try memory.readAlignedLong(at: UInt32(vector * 4))
        self = next
    }

    @inlinable static func sizeMask(_ size: Int) -> UInt32 {
        size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
    }

    @inlinable static func isDataAlterable(_ mode: Int, _ register: Int) -> Bool {
        mode != 1 && (mode != 7 || register <= 1)
    }

    @inlinable static func isMemoryAlterable(_ mode: Int, _ register: Int) -> Bool {
        mode >= 2 && (mode != 7 || register <= 1)
    }

    @inlinable static func isDataAddressing(_ mode: Int, _ register: Int) -> Bool {
        mode != 1 && (mode != 7 || register <= 4)
    }

    @inlinable static func isControl(_ mode: Int, _ register: Int) -> Bool {
        mode == 2 || mode == 5 || mode == 6 || (mode == 7 && register <= 3)
    }

    /// Clocks to calculate an effective address and fetch its operand (MC68000UM table 8-1):
    /// one bus cycle of 4 clocks per extension word and per operand word, plus 2 for the
    /// decrement of `-(An)` and for the index of `d8(An,Xn)`. Register operands take none.
    @inlinable static func operandClocks(_ mode: Int, _ register: Int, size: Int) -> Int {
        let clocks: Int
        switch mode {
        case 0, 1: return 0
        case 2, 3: clocks = 4
        case 4: clocks = 6
        case 5: clocks = 8
        case 6: clocks = 10
        default: clocks = register == 0 || register == 2 ? 8 : register == 1 ? 12 : register == 3 ? 10 : 4
        }
        return size == 4 ? clocks + 4 : clocks
    }

    /// Clocks of LEA for a control addressing mode (table 8-10); PEA takes 8 more, and MOVEM's
    /// and JMP's times are derived in place.
    @inlinable static func controlClocks(_ mode: Int, _ register: Int) -> Int {
        switch mode {
        case 2: return 4
        case 5: return 8
        case 6: return 12
        default: return register == 1 || register == 3 ? 12 : 8
        }
    }

    /// N and Z from the result, V and C cleared, X unchanged.
    @inlinable mutating func setLogicFlags(_ value: UInt32, size: Int) {
        status &= 0xFFF0
        if value & Self.sizeMask(size) == 0 { status |= 0x04 }
        if value & (UInt32(1) << (size * 8 - 1)) != 0 { status |= 0x08 }
    }

    /// Add or subtract with XNZVC flags. With `extend`, X is added/subtracted too and Z is
    /// only cleared (never set), as for ADDX/SUBX/NEGX.
    @inlinable mutating func addSub(_ destination: UInt32, _ source: UInt32, size: Int,
                                 subtract: Bool, extend: Bool = false) -> UInt32 {
        let mask = Self.sizeMask(size)
        let sign = UInt32(1) << (size * 8 - 1)
        let d = destination & mask, s = source & mask
        let x: UInt64 = extend && status & 0x10 != 0 ? 1 : 0
        let wide = subtract ? UInt64(d) &- UInt64(s) &- x : UInt64(d) + UInt64(s) + x
        let result = UInt32(truncatingIfNeeded: wide) & mask
        let carry = subtract ? UInt64(s) + x > UInt64(d) : wide > UInt64(mask)
        let overflow = subtract
            ? (s ^ d) & (d ^ result) & sign != 0
            : (s ^ result) & (d ^ result) & sign != 0
        let keptZero = status & 0x04
        status &= 0xFFE0
        if carry { status |= 0x11 }
        if result & sign != 0 { status |= 0x08 }
        if overflow { status |= 0x02 }
        if result == 0 { status |= extend ? keptZero : 0x04 }
        return result
    }

    @inlinable mutating func execute<Bus: M68KBus>(prefetched: UInt16?, memory: inout Bus) throws {
        let instructionAddress = programCounter
        let opcode = try prefetched ?? memory.readAlignedWord(at: instructionAddress)
        let nextWord = instructionAddress &+ 2

        switch opcode {
        case 0x1000...0x3FFF: // MOVE / MOVEA
            var next = self
            try next.move(opcode, memory: &memory)
            self = next
        case _ where opcode & 0xF1C0 == 0x41C0 || opcode & 0xFF80 == 0x4E80: // LEA / JSR / JMP
            let mode = Int((opcode >> 3) & 7)
            let register = Int(opcode & 7)
            guard mode == 2 || mode == 5 || mode == 6 || (mode == 7 && register <= 3) else {
                throw CPUError.unsupportedInstruction(opcode: opcode, address: instructionAddress)
            }
            var next = self
            var cursor = nextWord
            // These control modes compute an address without reading it or changing An.
            guard case .memory(let target) = try next.moveOperand(
                mode: mode, register: register, size: 4, cursor: &cursor, memory: &memory
            ) else {
                preconditionFailure("Control addressing was validated before decoding")
            }
            if opcode & 0xF1C0 == 0x41C0 { // LEA
                next[address: Int((opcode >> 9) & 7)] = target
                next.programCounter = cursor
                next.clocks += Self.controlClocks(mode, register)
            } else {
                // JMP: (An) 8, d16 10, d8 14, xxx.W 10, xxx.L 12; JSR takes 8 more.
                let jump = mode == 2 ? 8 : mode == 6 || (mode == 7 && register == 3) ? 14
                    : mode == 7 && register == 1 ? 12 : 10
                next.clocks += opcode & 0xFFC0 == 0x4E80 ? jump + 8 : jump
                // JSR resolves the target before changing A7, and fetches from it before it
                // pushes: nothing is pushed when the target is odd.
                if opcode & 0xFFC0 == 0x4E80, target & 1 == 0 {
                    let stackPointer = next[address: 7] &- 4
                    try memory.writeAlignedLong(cursor, at: stackPointer)
                    next[address: 7] = stackPointer
                }
                next.programCounter = target
            }
            self = next
        case 0x4E71: // NOP
            programCounter = nextWord
            clocks += 4
        case 0x4E75: // RTS
            let stackPointer = self[address: 7]
            let target = try memory.readAlignedLong(at: stackPointer)
            self[address: 7] = stackPointer &+ 4
            programCounter = target
            clocks += 16
        case _ where opcode & 0xF100 == 0x7000: // MOVEQ #imm,Dn
            let register = Int((opcode >> 9) & 7)
            let immediate = Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: opcode)))
            dataRegisters[register] = UInt32(bitPattern: immediate)
            status &= 0xFFF0 // Preserve X and the supervisor byte; clear NZVC.
            if immediate < 0 { status |= 0x0008 }
            if immediate == 0 { status |= 0x0004 }
            programCounter = nextWord
            clocks += 4
        case _ where opcode & 0xF000 == 0x6000: // BRA, BSR, Bcc
            let condition = Int((opcode >> 8) & 15)
            let shortDisplacement = UInt8(truncatingIfNeeded: opcode)
            let displacement: Int32
            let returnAddress: UInt32
            if shortDisplacement == 0 {
                displacement = Int32(Int16(bitPattern: try memory.readAlignedWord(at: nextWord)))
                returnAddress = nextWord &+ 2
            } else {
                // On the 68000, $FF is -1, not a 68020 long displacement marker.
                displacement = Int32(Int8(bitPattern: shortDisplacement))
                returnAddress = nextWord
            }
            let target = nextWord &+ UInt32(bitPattern: displacement)
            if condition == 1 { // BSR
                let stackPointer = self[address: 7] &- 4
                try memory.writeAlignedLong(returnAddress, at: stackPointer)
                self[address: 7] = stackPointer
                programCounter = target
                clocks += 18
            } else if condition == 0 || conditionHolds(condition) {
                programCounter = target
                clocks += 10
            } else {
                programCounter = returnAddress
                clocks += shortDisplacement == 0 ? 12 : 8
            }
        case _ where opcode & 0xF000 == 0x5000 && opcode & 0x00C0 != 0x00C0, // ADDQ / SUBQ
             _ where opcode & 0xB000 == 0x9000: // SUB/SUBA ($9xxx), ADD/ADDA ($Dxxx)
            var next = self
            try next.arithmetic(opcode, memory: &memory)
            self = next
        case _ where opcode & 0xF0F8 == 0x50C8: // DBcc Dn,<label>
            let displacement = Self.signExtendWord(try memory.readAlignedWord(at: nextWord))
            if conditionHolds(Int((opcode >> 8) & 15)) {
                programCounter = nextWord &+ 2
                clocks += 12
            } else {
                // Only the low word of Dn counts; the loop ends when it reaches -1.
                let register = Int(opcode & 7)
                let counter = UInt16(truncatingIfNeeded: dataRegisters[register]) &- 1
                dataRegisters[register] = (dataRegisters[register] & 0xFFFF_0000) | UInt32(counter)
                programCounter = counter == 0xFFFF ? nextWord &+ 2 : nextWord &+ displacement
                clocks += counter == 0xFFFF ? 14 : 10
            }
        case _ where opcode & 0xF000 == 0xB000 && [0, 1, 2, 3, 7].contains((opcode >> 6) & 7),
             _ where opcode & 0xFF00 == 0x0C00 && opcode & 0x00C0 != 0x00C0: // CMP / CMPA / CMPI
            var next = self
            try next.compare(opcode, memory: &memory)
            self = next
        case _ where opcode & 0xF000 == 0x0000: // immediate logic/arithmetic, bit operations
            var next = self
            try next.immediateOrBit(opcode, memory: &memory)
            self = next
        case _ where opcode & 0xF000 == 0x4000:
            var next = self
            try next.miscellaneous(opcode, memory: &memory)
            self = next
        case _ where opcode & 0xF0C0 == 0x50C0: // Scc (DBcc matched above)
            let mode = Int((opcode >> 3) & 7), register = Int(opcode & 7)
            guard Self.isDataAlterable(mode, register) else {
                throw CPUError.unsupportedInstruction(opcode: opcode, address: instructionAddress)
            }
            var next = self
            var cursor = nextWord
            let target = try next.moveOperand(mode: mode, register: register, size: 1, cursor: &cursor, memory: &memory)
            let holds = conditionHolds(Int((opcode >> 8) & 15))
            try next.write(holds ? 0xFF : 0, to: target, size: 1, memory: &memory)
            next.programCounter = cursor
            next.clocks += mode == 0 ? (holds ? 6 : 4) : 8 + Self.operandClocks(mode, register, size: 1)
            self = next
        case _ where opcode & 0xB1F0 == 0x8100: // SBCD ($8), ABCD ($C): Dy,Dx or -(Ay),-(Ax)
            var next = self
            var cursor = nextWord
            let size = 1, x = Int((opcode >> 9) & 7), y = Int(opcode & 7)
            let memoryForm = opcode & 8 != 0
            let sourceOperand = memoryForm
                ? try next.moveOperand(mode: 4, register: y, size: size, cursor: &cursor, memory: &memory) : .data(y)
            let source = try next.read(sourceOperand, size: size, memory: &memory)
            let target = memoryForm
                ? try next.moveOperand(mode: 4, register: x, size: size, cursor: &cursor, memory: &memory) : .data(x)
            let destination = try next.read(target, size: size, memory: &memory)
            let result = next.decimal(destination, source, subtract: opcode & 0x4000 == 0)
            try next.write(result, to: target, size: size, memory: &memory)
            next.programCounter = cursor
            next.clocks += memoryForm ? 18 : 6
            self = next
        case _ where opcode & 0xB000 == 0x8000, // OR/DIV ($8), AND/MUL/EXG ($C)
             _ where opcode & 0xF000 == 0xB000: // EOR (CMP opmodes matched above)
            var next = self
            try next.logical(opcode, memory: &memory)
            self = next
        case _ where opcode & 0xF000 == 0xE000:
            var next = self
            try next.shift(opcode, memory: &memory)
            self = next
        case _ where opcode & 0xF000 == 0xA000:
            throw Trap(vector: 10, returnAddress: instructionAddress) // line A emulator
        case _ where opcode & 0xF000 == 0xF000:
            throw Trap(vector: 11, returnAddress: instructionAddress) // line F emulator
        default:
            throw CPUError.unsupportedInstruction(opcode: opcode, address: instructionAddress)
        }
    }

    /// BCD add/subtract with X for ABCD, SBCD and NBCD. C and X = decimal carry/borrow, Z cleared
    /// if the result is nonzero (else unchanged); N and V follow the 68000's undocumented results.
    @inlinable mutating func decimal(_ destination: UInt32, _ source: UInt32, subtract: Bool) -> UInt32 {
        let x: Int = status & 0x10 != 0 ? 1 : 0
        let d = Int(destination & 0xFF), s = Int(source & 0xFF)
        var result: Int
        let binary: Int
        let carry: Bool, overflow: Bool
        if subtract {
            // The low digits are subtracted first; a borrow out of them corrects by 6, and a
            // borrow out of the whole byte by $60. Operands need not be valid BCD.
            let low = (d & 0x0F) - (s & 0x0F) - x
            binary = (d & 0xF0) - (s & 0xF0) + low
            result = binary
            var correction = 0
            if low & 0xF0 != 0 { result -= 6; correction = 6 }
            if (d - s - x) & 0x100 != 0 { result -= 0x60 }
            carry = (d - s - correction - x) & 0x300 != 0
            overflow = binary & 0x80 != 0 && result & 0x80 == 0
        } else {
            let low = (d & 0x0F) + (s & 0x0F) + x
            binary = (d & 0xF0) + (s & 0xF0) + low
            result = binary
            if low > 9 { result += 6 }
            carry = result & 0x3F0 > 0x90
            if carry { result += 0x60 }
            overflow = binary & 0x80 == 0 && result & 0x80 != 0
        }
        result &= 0xFF
        status &= ~0x1B // keep Z
        if carry { status |= 0x11 }
        if result & 0x80 != 0 { status |= 0x08 }
        if overflow { status |= 0x02 }
        if result != 0 { status &= ~0x04 }
        return UInt32(result)
    }

    /// ORI/ANDI/SUBI/ADDI/EORI (including to CCR/SR) and BTST/BCHG/BCLR/BSET.
    @inlinable mutating func immediateOrBit<Bus: M68KBus>(_ opcode: UInt16, memory: inout Bus) throws {
        let instructionAddress = programCounter
        let unsupported = CPUError.unsupportedInstruction(opcode: opcode, address: instructionAddress)
        let mode = Int((opcode >> 3) & 7), register = Int(opcode & 7)
        var cursor = instructionAddress &+ 2
        let dynamic = opcode & 0x0100 != 0
        if dynamic && mode == 1 { // MOVEP Dx,(d16,Ay) / (d16,Ay),Dx: alternate bytes, high first
            let data = Int((opcode >> 9) & 7)
            let base = self[address: register] &+ Self.signExtendWord(try extensionWord(cursor: &cursor, memory: &memory))
            let count = opcode & 0x0040 != 0 ? 4 : 2
            if opcode & 0x0080 != 0 {
                let value = self[data: data]
                for index in 0..<count {
                    let byte = UInt8(truncatingIfNeeded: value >> UInt32((count - 1 - index) * 8))
                    try memory.writeByte(byte, at: base &+ UInt32(index * 2))
                }
            } else {
                var value: UInt32 = 0
                for index in 0..<count {
                    value = value << 8 | UInt32(try memory.readByte(at: base &+ UInt32(index * 2)))
                }
                self[data: data] = count == 4 ? value : (self[data: data] & 0xFFFF_0000) | value
            }
            programCounter = cursor
            clocks += count == 4 ? 24 : 16
            return
        }
        if dynamic || opcode & 0x0F00 == 0x0800 {
            let operation = Int((opcode >> 6) & 3) // BTST, BCHG, BCLR, BSET
            let legal = operation == 0
                ? mode != 1 && (mode != 7 || register <= (dynamic ? 4 : 3))
                : Self.isDataAlterable(mode, register)
            guard legal else { throw unsupported }
            let number = dynamic
                ? self[data: Int((opcode >> 9) & 7)]
                : UInt32(try extensionWord(cursor: &cursor, memory: &memory) & 0xFF)
            let size = mode == 0 ? 4 : 1 // Dn: bit mod 32; memory: byte, bit mod 8
            let target = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
            let value = try read(target, size: size, memory: &memory)
            let bit = UInt32(1) << (number % UInt32(size * 8))
            if value & bit == 0 { status |= 0x04 } else { status &= ~0x04 }
            if operation != 0 {
                let result = operation == 1 ? value ^ bit : operation == 2 ? value & ~bit : value | bit
                try write(result, to: target, size: size, memory: &memory)
            }
            programCounter = cursor
            // BTST 6 on Dn, 4 + operand in memory (10 for an immediate operand in both test
            // sets; table 8-8 gives 8). BCHG and BSET 8, BCLR 10 on Dn (2 less for a bit
            // below 16), 8 + operand in memory. A bit number in an extension word adds 4.
            let base: Int
            if mode == 0 {
                base = operation == 0 ? 6 : (operation == 2 ? 10 : 8) - (number % 32 < 16 ? 2 : 0)
            } else if mode == 7 && register == 4 {
                base = 10
            } else {
                base = (operation == 0 ? 4 : 8) + Self.operandClocks(mode, register, size: 1)
            }
            clocks += dynamic ? base : base + 4
            return
        }

        let kind = Int((opcode >> 9) & 7) // 0 OR, 1 AND, 2 SUB, 3 ADD, 5 EOR
        let sizeBits = Int((opcode >> 6) & 3)
        guard sizeBits != 3, [0, 1, 2, 3, 5].contains(kind) else { throw unsupported }
        if mode == 7 && register == 4 { // to CCR (byte) or SR (word, privileged)
            guard [0, 1, 5].contains(kind), sizeBits <= 1 else { throw unsupported }
            if sizeBits == 1 && status & 0x2000 == 0 {
                throw Trap(vector: 8, returnAddress: instructionAddress)
            }
            let fieldMask: UInt16 = sizeBits == 0 ? 0x00FF : 0xFFFF
            let operand = try extensionWord(cursor: &cursor, memory: &memory) & fieldMask
            switch kind {
            case 0: statusRegister = status | operand
            case 1: statusRegister = status & (operand | ~fieldMask)
            default: statusRegister = status ^ operand
            }
            programCounter = cursor
            clocks += 20
            return
        }
        guard Self.isDataAlterable(mode, register) else { throw unsupported }
        let size = [1, 2, 4][sizeBits]
        let high = try extensionWord(cursor: &cursor, memory: &memory)
        var source = size == 1 ? UInt32(high & 0xFF) : UInt32(high)
        if size == 4 { source = source << 16 | UInt32(try extensionWord(cursor: &cursor, memory: &memory)) }
        let target = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
        let destination = try read(target, size: size, memory: &memory)
        let result: UInt32
        switch kind {
        case 0: result = destination | source; setLogicFlags(result, size: size)
        case 1: result = destination & source; setLogicFlags(result, size: size)
        case 5: result = destination ^ source; setLogicFlags(result, size: size)
        default: result = addSub(destination, source, size: size, subtract: kind == 2)
        }
        try write(result, to: target, size: size, memory: &memory)
        programCounter = cursor
        if mode == 0 { // 16 for every long operation (table 8-5 prints 14 for ANDI.L)
            clocks += size == 4 ? 16 : 8
        } else {
            clocks += (size == 4 ? 20 : 12) + Self.operandClocks(mode, register, size: size)
        }
    }

    /// Group $4 instructions other than LEA/JMP/JSR/NOP/RTS (handled in `execute`).
    @inlinable mutating func miscellaneous<Bus: M68KBus>(_ opcode: UInt16, memory: inout Bus) throws {
        let instructionAddress = programCounter
        let unsupported = CPUError.unsupportedInstruction(opcode: opcode, address: instructionAddress)
        let privilege = Trap(vector: 8, returnAddress: instructionAddress)
        let supervisor = status & 0x2000 != 0
        let mode = Int((opcode >> 3) & 7), register = Int(opcode & 7)
        var cursor = instructionAddress &+ 2
        switch opcode {
        case 0x4AFC, 0x4E7A, 0x4E7B:
            // ILLEGAL, and MOVEC (68010+), which Kickstart executes to detect the CPU type.
            throw Trap(vector: 4, returnAddress: instructionAddress)
        case 0x4E70: // RESET: privileged; resets the devices on the bus, not the CPU.
            guard supervisor else { throw privilege }
            prefetchedOpcode = try memory.readAlignedWord(at: cursor)
            memory.resetDevices()
            clocks += 132
        case 0x4E72: // STOP #imm: load SR and wait for an interrupt.
            guard supervisor else { throw privilege }
            statusRegister = try extensionWord(cursor: &cursor, memory: &memory)
            stopped = true
            clocks += 4
        case 0x4E73: // RTE
            guard supervisor else { throw privilege }
            let stackPointer = supervisorStackPointer
            let savedStatus = try memory.readAlignedWord(at: stackPointer)
            let target = try memory.readAlignedLong(at: stackPointer &+ 2)
            supervisorStackPointer = stackPointer &+ 6
            statusRegister = savedStatus
            programCounter = target
            clocks += 20
            return
        case 0x4E76: // TRAPV
            if status & 0x02 != 0 { throw Trap(vector: 7, returnAddress: cursor) }
            clocks += 4
        case 0x4E77: // RTR
            let stackPointer = self[address: 7]
            let condition = try memory.readAlignedWord(at: stackPointer)
            let target = try memory.readAlignedLong(at: stackPointer &+ 2)
            self[address: 7] = stackPointer &+ 6
            status = (status & 0xFF00) | (condition & 0x1F)
            programCounter = target
            clocks += 20
            return
        case 0x4840...0x4847: // SWAP
            let value = self[data: register]
            let swapped = value << 16 | value >> 16
            self[data: register] = swapped
            setLogicFlags(swapped, size: 4)
            clocks += 4
        case 0x4880...0x4887: // EXT.W
            let value = UInt32(UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: self[data: register])))))
            self[data: register] = (self[data: register] & 0xFFFF_0000) | value
            setLogicFlags(value, size: 2)
            clocks += 4
        case 0x48C0...0x48C7: // EXT.L
            let value = Self.signExtendWord(UInt16(truncatingIfNeeded: self[data: register]))
            self[data: register] = value
            setLogicFlags(value, size: 4)
            clocks += 4
        case 0x4E40...0x4E4F: // TRAP #n
            throw Trap(vector: 32 + register + (opcode & 8 != 0 ? 8 : 0), returnAddress: cursor)
        case 0x4E50...0x4E57: // LINK An,#d16
            let displacement = Self.signExtendWord(try extensionWord(cursor: &cursor, memory: &memory))
            let stackPointer = self[address: 7] &- 4
            try memory.writeAlignedLong(register == 7 ? stackPointer : self[address: register], at: stackPointer)
            self[address: 7] = stackPointer
            self[address: register] = stackPointer
            self[address: 7] = stackPointer &+ displacement
            clocks += 16
        case 0x4E58...0x4E5F: // UNLK An
            let base = self[address: register]
            let value = try memory.readAlignedLong(at: base)
            self[address: 7] = base &+ 4
            self[address: register] = value
            clocks += 12
        case 0x4E60...0x4E6F: // MOVE An,USP / MOVE USP,An
            guard supervisor else { throw privilege }
            if opcode & 8 == 0 { userStackPointer = self[address: register] }
            else { self[address: register] = userStackPointer }
            clocks += 4
        case _ where opcode & 0xFFC0 == 0x4840: // PEA
            guard Self.isControl(mode, register) else { throw unsupported }
            guard case .memory(let address) = try moveOperand(
                mode: mode, register: register, size: 4, cursor: &cursor, memory: &memory
            ) else { throw unsupported }
            let stackPointer = self[address: 7] &- 4
            try memory.writeAlignedLong(address, at: stackPointer)
            self[address: 7] = stackPointer
            clocks += Self.controlClocks(mode, register) + 8
        case _ where opcode & 0xFFC0 == 0x4800: // NBCD <ea>
            guard Self.isDataAlterable(mode, register) else { throw unsupported }
            let target = try moveOperand(mode: mode, register: register, size: 1, cursor: &cursor, memory: &memory)
            let value = try read(target, size: 1, memory: &memory)
            try write(decimal(0, value, subtract: true), to: target, size: 1, memory: &memory)
            clocks += mode == 0 ? 6 : 8 + Self.operandClocks(mode, register, size: 1)
        case _ where opcode & 0xF1C0 == 0x4180: // CHK.W <ea>,Dn: trap 6 if Dn < 0 or Dn > bound
            guard Self.isDataAddressing(mode, register) else { throw unsupported }
            let source = try moveOperand(mode: mode, register: register, size: 2, cursor: &cursor, memory: &memory)
            let bound = Int16(bitPattern: UInt16(try read(source, size: 2, memory: &memory)))
            let value = Int16(bitPattern: UInt16(truncatingIfNeeded: self[data: Int((opcode >> 9) & 7)]))
            // Z, V and C are documented as undefined, and N as undefined without a trap. As
            // the 68000's microcode leaves them: Z, V and C clear, N set for a negative register.
            status = (status & ~0x0F) | (value < 0 ? 0x08 : 0)
            clocks += Self.operandClocks(mode, register, size: 2)
            if value < 0 || value > bound {
                // The upper bound is tested first, as bound - register in 16 bits, and that
                // trap is 2 clocks shorter; an overflow of the subtraction counts as above.
                let difference = Int(bound) - Int(value)
                if difference < 0 || difference > 0x7FFF { clocks -= 2 }
                throw Trap(vector: 6, returnAddress: cursor, condition: status & 0xFF, registers: self)
            }
            clocks += 10
        case _ where opcode & 0xFB80 == 0x4880: // MOVEM
            try moveMultiple(opcode, cursor: &cursor, memory: &memory)
        case _ where opcode & 0xFFC0 == 0x40C0: // MOVE SR,<ea> (unprivileged on the 68000)
            guard Self.isDataAlterable(mode, register) else { throw unsupported }
            let target = try moveOperand(mode: mode, register: register, size: 2, cursor: &cursor, memory: &memory)
            try write(UInt32(status), to: target, size: 2, memory: &memory)
            clocks += mode == 0 ? 6 : 8 + Self.operandClocks(mode, register, size: 2)
        case _ where opcode & 0xFDC0 == 0x44C0: // MOVE <ea>,CCR / MOVE <ea>,SR
            guard Self.isDataAddressing(mode, register) else { throw unsupported }
            let toStatus = opcode & 0x0200 != 0
            if toStatus && !supervisor { throw privilege }
            let source = try moveOperand(mode: mode, register: register, size: 2, cursor: &cursor, memory: &memory)
            let value = UInt16(try read(source, size: 2, memory: &memory))
            if toStatus { statusRegister = value } else { status = (status & 0xFF00) | (value & 0x1F) }
            clocks += 12 + Self.operandClocks(mode, register, size: 2)
        case _ where opcode & 0xFFC0 == 0x4AC0: // TAS (Amiga chip-bus RMW quirks not modelled)
            guard Self.isDataAlterable(mode, register) else { throw unsupported }
            let target = try moveOperand(mode: mode, register: register, size: 1, cursor: &cursor, memory: &memory)
            let value = try read(target, size: 1, memory: &memory)
            setLogicFlags(value, size: 1)
            try write(value | 0x80, to: target, size: 1, memory: &memory)
            // Both test sets have 10 + operand for memory; table 8-6 prints 14 + operand.
            clocks += mode == 0 ? 4 : 10 + Self.operandClocks(mode, register, size: 1)
        case _ where (opcode & 0xF900 == 0x4000 || opcode & 0xFF00 == 0x4A00) && opcode & 0x00C0 != 0x00C0:
            // NEGX, CLR, NEG, NOT, TST
            guard Self.isDataAlterable(mode, register) else { throw unsupported }
            let size = [1, 2, 4][Int((opcode >> 6) & 3)]
            let target = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
            switch (opcode >> 9) & 7 {
            case 1: // CLR
                try write(0, to: target, size: size, memory: &memory)
                status = (status & 0xFFF0) | 0x04
            case 5: // TST
                setLogicFlags(try read(target, size: size, memory: &memory), size: size)
            case 3: // NOT
                let result = ~(try read(target, size: size, memory: &memory)) & Self.sizeMask(size)
                try write(result, to: target, size: size, memory: &memory)
                setLogicFlags(result, size: size)
            default: // 0 NEGX, 2 NEG
                let value = try read(target, size: size, memory: &memory)
                let result = addSub(0, value, size: size, subtract: true, extend: (opcode >> 9) & 7 == 0)
                try write(result, to: target, size: size, memory: &memory)
            }
            if (opcode >> 9) & 7 == 5 { // TST only reads
                clocks += 4 + Self.operandClocks(mode, register, size: size)
            } else if mode == 0 {
                clocks += size == 4 ? 6 : 4
            } else {
                clocks += (size == 4 ? 12 : 8) + Self.operandClocks(mode, register, size: size)
            }
        default:
            throw unsupported
        }
        programCounter = cursor
    }

    /// MOVEM: register list to memory (control or predecrement) or memory to registers
    /// (control or postincrement). Words loaded into registers are sign-extended.
    @inlinable mutating func moveMultiple<Bus: M68KBus>(_ opcode: UInt16, cursor: inout UInt32,
                                       memory: inout Bus) throws {
        let mode = Int((opcode >> 3) & 7), register = Int(opcode & 7)
        let toRegisters = opcode & 0x0400 != 0
        let size: UInt32 = opcode & 0x0040 != 0 ? 4 : 2
        let legal = toRegisters
            ? Self.isControl(mode, register) || mode == 3
            : (Self.isControl(mode, register) && !(mode == 7 && register >= 2)) || mode == 4
        guard legal else {
            throw CPUError.unsupportedInstruction(opcode: opcode, address: programCounter)
        }
        let list = try extensionWord(cursor: &cursor, memory: &memory)
        // To registers 8 + the mode's time, to memory 4 + (-(An) as (An)); 4 clocks per word moved.
        clocks += (toRegisters ? 8 : 4) + Self.operandClocks(mode == 4 ? 2 : mode, register, size: 2)
            + list.nonzeroBitCount * Int(size) * 2
        if mode == 4 { // predecrement: bit 0 = A7 ... bit 15 = D0, stored downwards
            var address = self[address: register]
            for bit in 0..<16 where list & (1 << bit) != 0 {
                let index = 15 - bit
                let value = index < 8 ? self[data: index] : self[address: index - 8]
                address &-= size
                if size == 4 { try memory.writeAlignedLong(value, at: address) }
                else { try memory.writeAlignedWord(UInt16(truncatingIfNeeded: value), at: address) }
            }
            self[address: register] = address
            return
        }
        var address: UInt32
        if mode == 3 {
            address = self[address: register]
        } else {
            guard case .memory(let base) = try moveOperand(
                mode: mode, register: register, size: Int(size), cursor: &cursor, memory: &memory
            ) else { preconditionFailure("Control addressing yields a memory operand") }
            address = base
        }
        for index in 0..<16 where list & (1 << index) != 0 {
            if toRegisters {
                let value = size == 4
                    ? try memory.readAlignedLong(at: address)
                    : Self.signExtendWord(try memory.readAlignedWord(at: address))
                if index < 8 { self[data: index] = value } else { self[address: index - 8] = value }
            } else {
                let value = index < 8 ? self[data: index] : self[address: index - 8]
                if size == 4 { try memory.writeAlignedLong(value, at: address) }
                else { try memory.writeAlignedWord(UInt16(truncatingIfNeeded: value), at: address) }
            }
            address &+= size
        }
        if mode == 3 { self[address: register] = address }
    }

    /// OR ($8), EOR/CMPM ($B, opmodes 4–6), AND ($C), MULU/MULS, DIVU/DIVS and EXG.
    @inlinable mutating func logical<Bus: M68KBus>(_ opcode: UInt16, memory: inout Bus) throws {
        let unsupported = CPUError.unsupportedInstruction(opcode: opcode, address: programCounter)
        let mode = Int((opcode >> 3) & 7), register = Int(opcode & 7)
        let upper = Int((opcode >> 9) & 7)
        let opmode = Int((opcode >> 6) & 7)
        let group = opcode >> 12
        var cursor = programCounter &+ 2

        if group == 0xC, [0x0140, 0x0148, 0x0188].contains(opcode & 0x01F8) { // EXG
            switch opcode & 0x01F8 {
            case 0x0140: (self[data: upper], self[data: register]) = (self[data: register], self[data: upper])
            case 0x0148:
                let value = self[address: upper]
                self[address: upper] = self[address: register]
                self[address: register] = value
            default:
                let value = self[data: upper]
                self[data: upper] = self[address: register]
                self[address: register] = value
            }
            programCounter = cursor
            clocks += 6
            return
        }

        if opmode == 3 || opmode == 7 { // MULU/MULS ($C), DIVU/DIVS ($8)
            guard group != 0xB, Self.isDataAddressing(mode, register) else { throw unsupported }
            let operand = try moveOperand(mode: mode, register: register, size: 2, cursor: &cursor, memory: &memory)
            let source = UInt16(try read(operand, size: 2, memory: &memory))
            let destination = self[data: upper]
            let signed = opmode == 7
            if group == 0xC {
                let product = signed
                    ? UInt32(bitPattern: Int32(Int16(bitPattern: source)) * Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: destination))))
                    : UInt32(source) * (destination & 0xFFFF)
                self[data: upper] = product
                setLogicFlags(product, size: 4)
                // 38 clocks and 2 for each 1 in the source (MULU), or for each change between
                // neighbouring bits of the source with a 0 appended (MULS).
                let pattern = signed ? source ^ (source << 1) : source
                clocks += 38 + 2 * pattern.nonzeroBitCount + Self.operandClocks(mode, register, size: 2)
            } else {
                clocks += Self.operandClocks(mode, register, size: 2)
                // Division by zero: N, Z, V and C are clear in the stacked SR (SingleStepTests set).
                guard source != 0 else { throw Trap(vector: 5, returnAddress: cursor, condition: status & 0x10, registers: self) }
                clocks += Self.divisionClocks(destination, source, signed: signed)
                let quotient: Int64, remainder: Int64
                if signed {
                    let dividend = Int64(Int32(bitPattern: destination)), divisor = Int64(Int16(bitPattern: source))
                    quotient = dividend / divisor
                    remainder = dividend % divisor
                } else {
                    quotient = Int64(destination / UInt32(source))
                    remainder = Int64(destination % UInt32(source))
                }
                let overflow = signed ? quotient < -32768 || quotient > 32767 : quotient > 0xFFFF
                if overflow {
                    // Destination unchanged; V set, C clear. N and Z are documented as
                    // undefined: the 68000's microcode leaves N set and Z clear.
                    status = (status & 0xFFF0) | 0x0A
                } else {
                    let result = UInt32(UInt16(truncatingIfNeeded: remainder)) << 16
                        | UInt32(UInt16(truncatingIfNeeded: quotient))
                    self[data: upper] = result
                    setLogicFlags(result & 0xFFFF, size: 2)
                }
            }
            programCounter = cursor
            return
        }

        if group == 0xB && mode == 1 { // CMPM (Ay)+,(Ax)+: NZVC from (Ax) - (Ay), X unchanged
            let size = [1, 2, 4][opmode & 3]
            let sourceOperand = try moveOperand(mode: 3, register: register, size: size, cursor: &cursor, memory: &memory)
            let source = try read(sourceOperand, size: size, memory: &memory)
            let destinationOperand = try moveOperand(mode: 3, register: upper, size: size, cursor: &cursor, memory: &memory)
            let destination = try read(destinationOperand, size: size, memory: &memory)
            let extend = status & 0x10
            _ = addSub(destination, source, size: size, subtract: true)
            status = (status & ~0x10) | extend
            programCounter = cursor
            clocks += size == 4 ? 20 : 12
            return
        }

        let size = [1, 2, 4][opmode & 3]
        let toEffectiveAddress = opmode >= 4
        let legal = toEffectiveAddress
            ? (group == 0xB ? Self.isDataAlterable(mode, register) : Self.isMemoryAlterable(mode, register))
            : group != 0xB && Self.isDataAddressing(mode, register)
        guard legal else { throw unsupported }
        let operand = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
        let other = self[data: upper] & Self.sizeMask(size)
        let value = try read(operand, size: size, memory: &memory)
        let result = group == 0x8 ? value | other : group == 0xC ? value & other : value ^ other
        try write(result, to: toEffectiveAddress ? operand : .data(upper), size: size, memory: &memory)
        setLogicFlags(result, size: size)
        programCounter = cursor
        clocks += Self.operationClocks(mode, register, size: size, toMemory: toEffectiveAddress && mode != 0)
    }

    /// Clocks of ADD, SUB, AND, OR and EOR between a data register and an operand (table 8-4).
    /// To a register: 4 + operand for bytes and words; 6 + operand for longs, 8 when the
    /// operand is a register or immediate. To memory: 8 + operand, 12 + operand for longs.
    @inlinable static func operationClocks(_ mode: Int, _ register: Int, size: Int, toMemory: Bool) -> Int {
        let operand = operandClocks(mode, register, size: size)
        if toMemory { return (size == 4 ? 12 : 8) + operand }
        if size != 4 { return 4 + operand }
        return mode <= 1 || (mode == 7 && register == 4) ? 8 + operand : 6 + operand
    }

    /// Clocks of DIVU or DIVS without the operand fetch, for a divisor that is not 0. The
    /// 68000 divides bit by bit and the time depends on the operands; this follows Jorge
    /// Cwik's description of the microcode and matches every division in the m68000 test
    /// set. DIVU: 10 on overflow, else 76 to 136. DIVS: 16 or 18 on an overflow seen at
    /// once, else 120 to 156.
    @inlinable static func divisionClocks(_ dividend: UInt32, _ divisor: UInt16, signed: Bool) -> Int {
        if !signed {
            if dividend >> 16 >= UInt32(divisor) { return 10 }
            var steps = 38
            var remainder = dividend
            let shifted = UInt32(divisor) << 16
            for _ in 0..<15 {
                let carry = remainder & 0x8000_0000 != 0
                remainder <<= 1
                if carry {
                    remainder &-= shifted
                } else {
                    steps += 2
                    if remainder >= shifted {
                        remainder &-= shifted
                        steps -= 1
                    }
                }
            }
            return steps * 2
        }
        let negativeDividend = dividend & 0x8000_0000 != 0, negativeDivisor = divisor & 0x8000 != 0
        let magnitude = negativeDividend ? 0 &- dividend : dividend
        let divisorMagnitude = UInt32(negativeDivisor ? 0 &- divisor : divisor)
        var steps = negativeDividend ? 7 : 6
        if magnitude >> 16 >= divisorMagnitude { return (steps + 2) * 2 }
        steps += 55
        if !negativeDivisor { steps += negativeDividend ? 1 : -1 }
        var quotient = magnitude / divisorMagnitude
        for _ in 0..<15 {
            if quotient & 0x8000 == 0 { steps += 1 }
            quotient <<= 1
        }
        return steps * 2
    }

    /// ASL/ASR, LSL/LSR, ROXL/ROXR, ROL/ROR on Dn (count 1–8 or Dn mod 64) and on memory words.
    @inlinable mutating func shift<Bus: M68KBus>(_ opcode: UInt16, memory: inout Bus) throws {
        var cursor = programCounter &+ 2
        let left = opcode & 0x0100 != 0
        let sizeBits = Int((opcode >> 6) & 3)
        let type: Int, size: Int, count: Int
        let target: MoveOperand
        if sizeBits == 3 {
            let mode = Int((opcode >> 3) & 7), register = Int(opcode & 7)
            guard opcode & 0x0800 == 0, Self.isMemoryAlterable(mode, register) else {
                throw CPUError.unsupportedInstruction(opcode: opcode, address: programCounter)
            }
            type = Int((opcode >> 9) & 3)
            size = 2
            count = 1
            target = try moveOperand(mode: mode, register: register, size: 2, cursor: &cursor, memory: &memory)
        } else {
            type = Int((opcode >> 3) & 3)
            size = [1, 2, 4][sizeBits]
            let field = Int((opcode >> 9) & 7)
            count = opcode & 0x20 != 0 ? Int(self[data: field] & 63) : (field == 0 ? 8 : field)
            target = .data(Int(opcode & 7))
        }
        let mask = Self.sizeMask(size)
        let sign = UInt32(1) << (size * 8 - 1)
        var value = try read(target, size: size, memory: &memory)
        var extend = status & 0x10 != 0
        var carry = type == 2 ? extend : false // count 0: ROX copies X to C, others clear C
        var overflow = false
        for _ in 0..<count {
            let outgoing = left ? value & sign != 0 : value & 1 != 0
            let incoming: Bool
            switch type {
            case 0: incoming = !left && value & sign != 0 // ASR replicates the sign bit
            case 1: incoming = false
            case 2: incoming = extend
            default: incoming = outgoing
            }
            let shifted = left
                ? ((value << 1) & mask) | (incoming ? 1 : 0)
                : (value >> 1) | (incoming ? sign : 0)
            if type == 0 && left && (shifted ^ value) & sign != 0 { overflow = true }
            value = shifted
            carry = outgoing
            if type != 3 { extend = outgoing }
        }
        try write(value, to: target, size: size, memory: &memory)
        status &= 0xFFE0
        if extend { status |= 0x10 }
        if value & sign != 0 { status |= 0x08 }
        if value == 0 { status |= 0x04 }
        if overflow { status |= 0x02 }
        if carry { status |= 0x01 }
        programCounter = cursor
        if sizeBits == 3 {
            clocks += 8 + Self.operandClocks(Int((opcode >> 3) & 7), Int(opcode & 7), size: 2)
        } else {
            clocks += (size == 4 ? 8 : 6) + 2 * count
        }
    }

    @usableFromInline enum MoveOperand {
        case data(Int), address(Int), memory(UInt32), immediate(UInt32)
    }

    /// CMP <ea>,Dn; CMPA <ea>,An; CMPI #imm,<ea>. Sets NZVC from destination - source; X is unchanged.
    @inlinable mutating func compare<Bus: M68KBus>(_ opcode: UInt16, memory: inout Bus) throws {
        let mode = Int((opcode >> 3) & 7)
        let register = Int(opcode & 7)
        let immediateForm = opcode & 0xF000 == 0x0000
        let opmode = Int((opcode >> 6) & 7)
        let size: Int
        let legal: Bool
        if immediateForm {
            size = [1, 2, 4][opmode & 3]
            legal = mode != 1 && (mode != 7 || register <= 1) // data alterable
        } else {
            size = opmode == 3 ? 2 : opmode == 7 ? 4 : [1, 2, 4][opmode]
            legal = (mode != 7 || register <= 4) && !(mode == 1 && size == 1)
        }
        guard legal else {
            throw CPUError.unsupportedInstruction(opcode: opcode, address: programCounter)
        }

        var cursor = programCounter &+ 2
        var bits = size * 8
        var source: UInt32
        let destination: UInt32
        if immediateForm {
            let high = try extensionWord(cursor: &cursor, memory: &memory)
            source = size == 1 ? UInt32(high & 0xFF) : UInt32(high)
            if size == 4 { source = source << 16 | UInt32(try extensionWord(cursor: &cursor, memory: &memory)) }
            let operand = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
            destination = try read(operand, size: size, memory: &memory)
        } else {
            let operand = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
            source = try read(operand, size: size, memory: &memory)
            let upper = Int((opcode >> 9) & 7)
            if opmode == 3 || opmode == 7 { // CMPA compares all 32 bits of An
                if size == 2 { source = Self.signExtendWord(UInt16(source)) }
                destination = self[address: upper]
                bits = 32
            } else {
                destination = self[data: upper] & (size == 4 ? 0xFFFF_FFFF : (UInt32(1) << bits) - 1)
            }
        }

        let mask: UInt32 = bits == 32 ? 0xFFFF_FFFF : (UInt32(1) << bits) - 1
        let sign = UInt32(1) << (bits - 1)
        let result = (destination &- source) & mask
        status &= 0xFFF0
        if source > destination { status |= 0x01 }
        if (source ^ destination) & (destination ^ result) & sign != 0 { status |= 0x02 }
        if result == 0 { status |= 0x04 }
        if result & sign != 0 { status |= 0x08 }
        programCounter = cursor
        let operand = Self.operandClocks(mode, register, size: size)
        if immediateForm { // CMPI: Dn 8 (long 14), memory 8 (long 12) + operand
            clocks += mode == 0 ? (size == 4 ? 14 : 8) : (size == 4 ? 12 : 8) + operand
        } else { // CMP 4 + operand (long 6); CMPA 6 + operand
            clocks += (bits == 32 ? 6 : 4) + operand
        }
    }

    /// ADD, ADDA, ADDQ, SUB, SUBA, SUBQ, ADDX and SUBX.
    @inlinable mutating func arithmetic<Bus: M68KBus>(_ opcode: UInt16, memory: inout Bus) throws {
        let mode = Int((opcode >> 3) & 7)
        let register = Int(opcode & 7)
        let upper = Int((opcode >> 9) & 7)
        let opmode = Int((opcode >> 6) & 7)
        let quick = opcode & 0xF000 == 0x5000
        let subtract = quick ? opcode & 0x0100 != 0 : opcode & 0x4000 == 0
        let addressForm = !quick && opmode & 3 == 3 // ADDA / SUBA
        let size = addressForm ? (opmode == 3 ? 2 : 4) : [1, 2, 4][opmode & 3]
        let toEffectiveAddress = quick || (!addressForm && opmode >= 4)
        if !quick && !addressForm && opmode >= 4 && mode <= 1 {
            // ADDX/SUBX Dy,Dx or -(Ay),-(Ax): source register is the low field.
            var cursor = programCounter &+ 2
            let source: UInt32, destination: UInt32
            let target: MoveOperand
            if mode == 0 {
                source = self[data: register]
                target = .data(upper)
                destination = self[data: upper]
            } else {
                let sourceOperand = try moveOperand(mode: 4, register: register, size: size, cursor: &cursor, memory: &memory)
                source = try read(sourceOperand, size: size, memory: &memory)
                target = try moveOperand(mode: 4, register: upper, size: size, cursor: &cursor, memory: &memory)
                destination = try read(target, size: size, memory: &memory)
            }
            let result = addSub(destination, source, size: size, subtract: subtract, extend: true)
            try write(result, to: target, size: size, memory: &memory)
            programCounter = cursor
            clocks += mode == 0 ? (size == 4 ? 8 : 4) : (size == 4 ? 30 : 18)
            return
        }
        let legal: Bool
        if toEffectiveAddress {
            let alterable = mode <= 6 || (mode == 7 && register <= 1)
            // Register modes of the Dn,<ea> form encode ADDX/SUBX instead.
            legal = alterable && (quick ? !(mode == 1 && size == 1) : mode >= 2)
        } else {
            legal = (mode != 7 || register <= 4) && !(mode == 1 && size == 1)
        }
        guard legal else {
            throw CPUError.unsupportedInstruction(opcode: opcode, address: programCounter)
        }

        var cursor = programCounter &+ 2
        let mask: UInt32 = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
        let source: UInt32
        let target: MoveOperand
        if quick {
            source = UInt32(upper == 0 ? 8 : upper)
            target = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
        } else if toEffectiveAddress {
            source = self[data: upper] & mask
            target = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
        } else {
            let operand = try moveOperand(mode: mode, register: register, size: size, cursor: &cursor, memory: &memory)
            source = try read(operand, size: size, memory: &memory)
            target = addressForm ? .address(upper) : .data(upper)
        }

        if case .address(let index) = target {
            // Address destinations use all 32 bits and leave the condition codes unchanged.
            let operand = addressForm && size == 2 ? Self.signExtendWord(UInt16(source)) : source
            self[address: index] = subtract ? self[address: index] &- operand : self[address: index] &+ operand
            programCounter = cursor
            if quick { // ADDQ/SUBQ to An: 8 for both sizes (table 8-5 prints 4 for ADDQ.W)
                clocks += 8
            } else if size == 2 { // ADDA.W/SUBA.W
                clocks += 8 + Self.operandClocks(mode, register, size: 2)
            } else {
                clocks += Self.operationClocks(mode, register, size: 4, toMemory: false)
            }
            return
        }

        let destination = try read(target, size: size, memory: &memory)
        let result = (subtract ? destination &- source : destination &+ source) & mask
        let sign = UInt32(1) << (size * 8 - 1)
        let carry = subtract ? source > destination : result < destination
        let overflow = subtract
            ? (source ^ destination) & (destination ^ result) & sign != 0
            : (source ^ result) & (destination ^ result) & sign != 0
        try write(result, to: target, size: size, memory: &memory)
        status &= 0xFFE0
        if carry { status |= 0x11 } // X and C
        if result & sign != 0 { status |= 0x08 }
        if result == 0 { status |= 0x04 }
        if overflow { status |= 0x02 }
        programCounter = cursor
        if quick { // ADDQ/SUBQ: Dn 4 (long 8), memory 8 (long 12) + operand
            clocks += mode == 0 ? (size == 4 ? 8 : 4) : (size == 4 ? 12 : 8) + Self.operandClocks(mode, register, size: size)
        } else {
            clocks += Self.operationClocks(mode, register, size: size, toMemory: toEffectiveAddress)
        }
    }

    @inlinable func read<Bus: M68KBus>(_ operand: MoveOperand, size: Int, memory: inout Bus) throws -> UInt32 {
        let mask: UInt32 = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
        switch operand {
        case .data(let register): return self[data: register] & mask
        case .address(let register): return self[address: register] & mask
        case .immediate(let value): return value & mask
        case .memory(let address):
            switch size {
            case 1: return UInt32(try memory.readByte(at: address))
            case 2: return UInt32(try memory.readAlignedWord(at: address))
            default: return try memory.readAlignedLong(at: address)
            }
        }
    }

    @inlinable mutating func write<Bus: M68KBus>(_ value: UInt32, to operand: MoveOperand, size: Int,
                                memory: inout Bus) throws {
        let mask: UInt32 = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
        switch operand {
        case .data(let register): self[data: register] = (self[data: register] & ~mask) | value
        case .address(let register): self[address: register] = value
        case .memory(let address):
            switch size {
            case 1: try memory.writeByte(UInt8(value), at: address)
            case 2: try memory.writeAlignedWord(UInt16(value), at: address)
            default: try memory.writeAlignedLong(value, at: address)
            }
        case .immediate: preconditionFailure("Immediate operands are not writable")
        }
    }

    @inlinable mutating func move<Bus: M68KBus>(_ opcode: UInt16, memory: inout Bus) throws {
        let size = opcode >> 12 == 1 ? 1 : opcode >> 12 == 3 ? 2 : 4
        let sourceMode = Int((opcode >> 3) & 7)
        let sourceRegister = Int(opcode & 7)
        let destinationMode = Int((opcode >> 6) & 7)
        let destinationRegister = Int((opcode >> 9) & 7)
        guard !(size == 1 && (sourceMode == 1 || destinationMode == 1)),
              sourceMode != 7 || sourceRegister <= 4,
              destinationMode != 7 || destinationRegister <= 1 else {
            throw CPUError.unsupportedInstruction(opcode: opcode, address: programCounter)
        }

        var cursor = programCounter &+ 2
        let mask: UInt32 = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
        let source = try moveOperand(mode: sourceMode, register: sourceRegister,
                                     size: size, cursor: &cursor, memory: &memory)
        let value: UInt32
        switch source {
        case .data(let register): value = self[data: register] & mask
        case .address(let register): value = self[address: register] & mask
        case .immediate(let immediate): value = immediate & mask
        case .memory(let address):
            switch size {
            case 1: value = UInt32(try memory.readByte(at: address))
            case 2: value = UInt32(try memory.readAlignedWord(at: address))
            default: value = try memory.readAlignedLong(at: address)
            }
        }

        // Source updates precede destination decoding, including shared address registers.
        let destination = try moveOperand(mode: destinationMode, register: destinationRegister,
                                          size: size, cursor: &cursor, memory: &memory)
        switch destination {
        case .data(let register):
            self[data: register] = (self[data: register] & ~mask) | value
        case .address(let register):
            self[address: register] = size == 2 ? Self.signExtendWord(UInt16(value)) : value
        case .memory(let address):
            switch size {
            case 1: try memory.writeByte(UInt8(value), at: address)
            case 2: try memory.writeAlignedWord(UInt16(value), at: address)
            default: try memory.writeAlignedLong(value, at: address)
            }
        case .immediate:
            preconditionFailure("MOVE destination was validated before decoding")
        }
        if destinationMode != 1 {
            status &= 0xFFF0
            if value == 0 { status |= 4 }
            if value & (UInt32(1) << (size * 8 - 1)) != 0 { status |= 8 }
        }
        programCounter = cursor
        // 4 + source + destination (table 8-2 and 8-3); a `-(An)` destination has no extra 2.
        clocks += 4 + Self.operandClocks(sourceMode, sourceRegister, size: size)
            + Self.operandClocks(destinationMode == 4 ? 2 : destinationMode, destinationRegister, size: size)
    }

    @inlinable static func signExtendWord(_ word: UInt16) -> UInt32 {
        UInt32(bitPattern: Int32(Int16(bitPattern: word)))
    }

    @inlinable func extensionWord<Bus: M68KBus>(cursor: inout UInt32, memory: inout Bus) throws -> UInt16 {
        let word = try memory.readAlignedWord(at: cursor)
        cursor &+= 2
        return word
    }

    @inlinable func indexedAddress<Bus: M68KBus>(base: UInt32, cursor: inout UInt32,
                                memory: inout Bus) throws -> UInt32 {
        let word = try extensionWord(cursor: &cursor, memory: &memory)
        let register = Int((word >> 12) & 7)
        var index = word & 0x8000 == 0 ? self[data: register] : self[address: register]
        if word & 0x0800 == 0 { index = Self.signExtendWord(UInt16(truncatingIfNeeded: index)) }
        // MC68000 ignores bits 10...8; no scaled or full-extension addressing.
        let displacement = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: word))))
        return base &+ index &+ displacement
    }

    /// Called only after MOVE's source and destination mode legality has been checked.
    @inlinable mutating func moveOperand<Bus: M68KBus>(mode: Int, register: Int, size: Int,
                                      cursor: inout UInt32, memory: inout Bus) throws -> MoveOperand {
        let increment = UInt32(size == 1 && register == 7 ? 2 : size)
        switch mode {
        case 0: return .data(register)
        case 1: return .address(register)
        case 2: return .memory(self[address: register])
        case 3:
            let address = self[address: register]
            self[address: register] &+= increment
            return .memory(address)
        case 4:
            self[address: register] &-= increment
            return .memory(self[address: register])
        case 5:
            let displacement = try Self.signExtendWord(extensionWord(cursor: &cursor, memory: &memory))
            return .memory(self[address: register] &+ displacement)
        case 6:
            return try .memory(indexedAddress(base: self[address: register], cursor: &cursor, memory: &memory))
        default:
            switch register {
            case 0:
                return try .memory(Self.signExtendWord(extensionWord(cursor: &cursor, memory: &memory)))
            case 1:
                let high = try extensionWord(cursor: &cursor, memory: &memory)
                let low = try extensionWord(cursor: &cursor, memory: &memory)
                return .memory(UInt32(high) << 16 | UInt32(low))
            case 2:
                let base = cursor
                let displacement = try Self.signExtendWord(extensionWord(cursor: &cursor, memory: &memory))
                return .memory(base &+ displacement)
            case 3:
                let base = cursor
                return try .memory(indexedAddress(base: base, cursor: &cursor, memory: &memory))
            case 4:
                let high = try extensionWord(cursor: &cursor, memory: &memory)
                if size != 4 { return .immediate(UInt32(high)) }
                let low = try extensionWord(cursor: &cursor, memory: &memory)
                return .immediate(UInt32(high) << 16 | UInt32(low))
            default:
                preconditionFailure("MOVE mode was validated before decoding")
            }
        }
    }

    @inlinable func conditionHolds(_ condition: Int) -> Bool {
        let carry = status & 1 != 0
        let overflow = status & 2 != 0
        let zero = status & 4 != 0
        let negative = status & 8 != 0
        switch condition {
        case 0: return true // T
        case 1: return false // F
        case 2: return !carry && !zero // HI
        case 3: return carry || zero // LS
        case 4: return !carry // CC
        case 5: return carry // CS
        case 6: return !zero // NE
        case 7: return zero // EQ
        case 8: return !overflow // VC
        case 9: return overflow // VS
        case 10: return !negative // PL
        case 11: return negative // MI
        case 12: return negative == overflow // GE
        case 13: return negative != overflow // LT
        case 14: return !zero && negative == overflow // GT
        case 15: return zero || negative != overflow // LE
        default: preconditionFailure("Expected a condition code in 0...15")
        }
    }
}
