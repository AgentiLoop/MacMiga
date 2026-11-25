public enum CPUError: Error, Equatable {
    case unsupportedInstruction(opcode: UInt16, address: UInt32)
}

/// Functional MC68000 subset; no prefetch, cycle accounting, interrupts, or exceptions yet.
public struct MC68000: Equatable, Sendable {
    private var dataRegisters = [UInt32](repeating: 0, count: 8)
    private var addressRegisters = [UInt32](repeating: 0, count: 7)
    private var status: UInt16 = 0x2700
    public var programCounter: UInt32 = 0
    public var userStackPointer: UInt32 = 0
    public var supervisorStackPointer: UInt32 = 0

    /// Deterministic host initialization, not a claim about hardware power-on register values.
    public init() {}

    /// Host/debugger access. Only the MC68000's implemented status bits are retained.
    public var statusRegister: UInt16 {
        get { status }
        set { status = newValue & 0xA71F }
    }

    public subscript(data index: Int) -> UInt32 {
        get { dataRegisters[index] }
        set { dataRegisters[index] = newValue }
    }

    /// A7 selects SSP or USP according to the status register's supervisor bit.
    public subscript(address index: Int) -> UInt32 {
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

    /// External machine reset, not the RESET opcode. General registers and CCR are retained.
    public mutating func reset(memory: inout AmigaMemory) throws {
        let vectors = try memory.reset()
        status = (status & 0x001F) | 0x2700
        supervisorStackPointer = vectors.supervisorStackPointer
        programCounter = vectors.programCounter
    }

    /// Executes one supported instruction. PC is the next instruction address on success.
    /// On failure CPU registers remain unchanged; earlier bus writes are not rolled back.
    /// Errors are host diagnostics, not hardware exception processing. Odd branch targets
    /// are detected by the next instruction fetch, since prefetch is not modeled.
    /// Group 1/2 exceptions (TRAP, privilege violation, divide by zero, illegal, line A/F)
    /// are processed by pushing PC and SR on the supervisor stack and jumping through the
    /// vector table. Bus/address errors, trace and interrupts are not modelled yet.
    public mutating func step(memory: inout AmigaMemory) throws {
        do {
            try execute(memory: &memory)
        } catch let trap as Trap {
            try enterException(vector: trap.vector, returnAddress: trap.returnAddress, memory: &memory)
        }
    }

    /// Pending exception raised by an instruction; CPU state is untouched when it is thrown.
    private struct Trap: Error {
        let vector: Int
        let returnAddress: UInt32
    }

    /// 68000 short exception frame: SR at SSP, return PC at SSP+2. Enters supervisor, clears trace.
    private mutating func enterException(vector: Int, returnAddress: UInt32,
                                         memory: inout AmigaMemory) throws {
        var next = self
        next.status = (status | 0x2000) & 0x7FFF
        let stackPointer = next.supervisorStackPointer &- 6
        try memory.writeLong(returnAddress, at: stackPointer &+ 2)
        try memory.writeWord(status, at: stackPointer)
        next.supervisorStackPointer = stackPointer
        next.programCounter = try memory.readLong(at: UInt32(vector * 4))
        self = next
    }

    private static func sizeMask(_ size: Int) -> UInt32 {
        size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
    }

    private static func isDataAlterable(_ mode: Int, _ register: Int) -> Bool {
        mode != 1 && (mode != 7 || register <= 1)
    }

    private static func isMemoryAlterable(_ mode: Int, _ register: Int) -> Bool {
        mode >= 2 && (mode != 7 || register <= 1)
    }

    private static func isDataAddressing(_ mode: Int, _ register: Int) -> Bool {
        mode != 1 && (mode != 7 || register <= 4)
    }

    private static func isControl(_ mode: Int, _ register: Int) -> Bool {
        mode == 2 || mode == 5 || mode == 6 || (mode == 7 && register <= 3)
    }

    /// N and Z from the result, V and C cleared, X unchanged.
    private mutating func setLogicFlags(_ value: UInt32, size: Int) {
        status &= 0xFFF0
        if value & Self.sizeMask(size) == 0 { status |= 0x04 }
        if value & (UInt32(1) << (size * 8 - 1)) != 0 { status |= 0x08 }
    }

    /// Add or subtract with XNZVC flags. With `extend`, X is added/subtracted too and Z is
    /// only cleared (never set), as for ADDX/SUBX/NEGX.
    private mutating func addSub(_ destination: UInt32, _ source: UInt32, size: Int,
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

    private mutating func execute(memory: inout AmigaMemory) throws {
        let instructionAddress = programCounter
        let opcode = try memory.readWord(at: instructionAddress)
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
            } else {
                if opcode & 0xFFC0 == 0x4E80 { // JSR: resolve target before changing A7.
                    let stackPointer = next[address: 7] &- 4
                    try memory.writeLong(cursor, at: stackPointer)
                    next[address: 7] = stackPointer
                }
                next.programCounter = target
            }
            self = next
        case 0x4E71: // NOP
            programCounter = nextWord
        case 0x4E75: // RTS
            let stackPointer = self[address: 7]
            let target = try memory.readLong(at: stackPointer)
            self[address: 7] = stackPointer &+ 4
            programCounter = target
        case _ where opcode & 0xF100 == 0x7000: // MOVEQ #imm,Dn
            let register = Int((opcode >> 9) & 7)
            let immediate = Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: opcode)))
            dataRegisters[register] = UInt32(bitPattern: immediate)
            status &= 0xFFF0 // Preserve X and the supervisor byte; clear NZVC.
            if immediate < 0 { status |= 0x0008 }
            if immediate == 0 { status |= 0x0004 }
            programCounter = nextWord
        case _ where opcode & 0xF000 == 0x6000: // BRA, BSR, Bcc
            let condition = Int((opcode >> 8) & 15)
            let shortDisplacement = UInt8(truncatingIfNeeded: opcode)
            let displacement: Int32
            let returnAddress: UInt32
            if shortDisplacement == 0 {
                displacement = Int32(Int16(bitPattern: try memory.readWord(at: nextWord)))
                returnAddress = nextWord &+ 2
            } else {
                // On the 68000, $FF is -1, not a 68020 long displacement marker.
                displacement = Int32(Int8(bitPattern: shortDisplacement))
                returnAddress = nextWord
            }
            let target = nextWord &+ UInt32(bitPattern: displacement)
            if condition == 1 { // BSR
                let stackPointer = self[address: 7] &- 4
                try memory.writeLong(returnAddress, at: stackPointer)
                self[address: 7] = stackPointer
                programCounter = target
            } else {
                programCounter = condition == 0 || conditionHolds(condition) ? target : returnAddress
            }
        case _ where opcode & 0xF000 == 0x5000 && opcode & 0x00C0 != 0x00C0, // ADDQ / SUBQ
             _ where opcode & 0xB000 == 0x9000: // SUB/SUBA ($9xxx), ADD/ADDA ($Dxxx)
            var next = self
            try next.arithmetic(opcode, memory: &memory)
            self = next
        case _ where opcode & 0xF0F8 == 0x50C8: // DBcc Dn,<label>
            let displacement = Self.signExtendWord(try memory.readWord(at: nextWord))
            if conditionHolds(Int((opcode >> 8) & 15)) {
                programCounter = nextWord &+ 2
            } else {
                // Only the low word of Dn counts; the loop ends when it reaches -1.
                let register = Int(opcode & 7)
                let counter = UInt16(truncatingIfNeeded: dataRegisters[register]) &- 1
                dataRegisters[register] = (dataRegisters[register] & 0xFFFF_0000) | UInt32(counter)
                programCounter = counter == 0xFFFF ? nextWord &+ 2 : nextWord &+ displacement
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
            try next.write(conditionHolds(Int((opcode >> 8) & 15)) ? 0xFF : 0, to: target, size: 1, memory: &memory)
            next.programCounter = cursor
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

    /// ORI/ANDI/SUBI/ADDI/EORI (including to CCR/SR) and BTST/BCHG/BCLR/BSET.
    private mutating func immediateOrBit(_ opcode: UInt16, memory: inout AmigaMemory) throws {
        let instructionAddress = programCounter
        let unsupported = CPUError.unsupportedInstruction(opcode: opcode, address: instructionAddress)
        let mode = Int((opcode >> 3) & 7), register = Int(opcode & 7)
        var cursor = instructionAddress &+ 2
        let dynamic = opcode & 0x0100 != 0
        if dynamic || opcode & 0x0F00 == 0x0800 {
            let operation = Int((opcode >> 6) & 3) // BTST, BCHG, BCLR, BSET
            let legal = operation == 0
                ? mode != 1 && (mode != 7 || register <= (dynamic ? 4 : 3))
                : Self.isDataAlterable(mode, register)
            guard legal else { throw unsupported } // dynamic with An is MOVEP
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
    }

    /// Group $4 instructions other than LEA/JMP/JSR/NOP/RTS (handled in `execute`).
    private mutating func miscellaneous(_ opcode: UInt16, memory: inout AmigaMemory) throws {
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
        case 0x4E70: // RESET: privileged; resetting external devices is not modelled yet.
            guard supervisor else { throw privilege }
        case 0x4E72: // STOP needs interrupt support.
            throw unsupported
        case 0x4E73: // RTE
            guard supervisor else { throw privilege }
            let stackPointer = supervisorStackPointer
            let savedStatus = try memory.readWord(at: stackPointer)
            let target = try memory.readLong(at: stackPointer &+ 2)
            supervisorStackPointer = stackPointer &+ 6
            statusRegister = savedStatus
            programCounter = target
            return
        case 0x4E76: // TRAPV
            if status & 0x02 != 0 { throw Trap(vector: 7, returnAddress: cursor) }
        case 0x4E77: // RTR
            let stackPointer = self[address: 7]
            let condition = try memory.readWord(at: stackPointer)
            let target = try memory.readLong(at: stackPointer &+ 2)
            self[address: 7] = stackPointer &+ 6
            status = (status & 0xFF00) | (condition & 0x1F)
            programCounter = target
            return
        case 0x4840...0x4847: // SWAP
            let value = self[data: register]
            let swapped = value << 16 | value >> 16
            self[data: register] = swapped
            setLogicFlags(swapped, size: 4)
        case 0x4880...0x4887: // EXT.W
            let value = UInt32(UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: self[data: register])))))
            self[data: register] = (self[data: register] & 0xFFFF_0000) | value
            setLogicFlags(value, size: 2)
        case 0x48C0...0x48C7: // EXT.L
            let value = Self.signExtendWord(UInt16(truncatingIfNeeded: self[data: register]))
            self[data: register] = value
            setLogicFlags(value, size: 4)
        case 0x4E40...0x4E4F: // TRAP #n
            throw Trap(vector: 32 + register + (opcode & 8 != 0 ? 8 : 0), returnAddress: cursor)
        case 0x4E50...0x4E57: // LINK An,#d16
            let displacement = Self.signExtendWord(try extensionWord(cursor: &cursor, memory: &memory))
            let stackPointer = self[address: 7] &- 4
            try memory.writeLong(register == 7 ? stackPointer : self[address: register], at: stackPointer)
            self[address: 7] = stackPointer
            self[address: register] = stackPointer
            self[address: 7] = stackPointer &+ displacement
        case 0x4E58...0x4E5F: // UNLK An
            let base = self[address: register]
            let value = try memory.readLong(at: base)
            self[address: 7] = base &+ 4
            self[address: register] = value
        case 0x4E60...0x4E6F: // MOVE An,USP / MOVE USP,An
            guard supervisor else { throw privilege }
            if opcode & 8 == 0 { userStackPointer = self[address: register] }
            else { self[address: register] = userStackPointer }
        case _ where opcode & 0xFFC0 == 0x4840: // PEA
            guard Self.isControl(mode, register) else { throw unsupported }
            guard case .memory(let address) = try moveOperand(
                mode: mode, register: register, size: 4, cursor: &cursor, memory: &memory
            ) else { throw unsupported }
            let stackPointer = self[address: 7] &- 4
            try memory.writeLong(address, at: stackPointer)
            self[address: 7] = stackPointer
        case _ where opcode & 0xFB80 == 0x4880: // MOVEM
            try moveMultiple(opcode, cursor: &cursor, memory: &memory)
        case _ where opcode & 0xFFC0 == 0x40C0: // MOVE SR,<ea> (unprivileged on the 68000)
            guard Self.isDataAlterable(mode, register) else { throw unsupported }
            let target = try moveOperand(mode: mode, register: register, size: 2, cursor: &cursor, memory: &memory)
            try write(UInt32(status), to: target, size: 2, memory: &memory)
        case _ where opcode & 0xFDC0 == 0x44C0: // MOVE <ea>,CCR / MOVE <ea>,SR
            guard Self.isDataAddressing(mode, register) else { throw unsupported }
            let toStatus = opcode & 0x0200 != 0
            if toStatus && !supervisor { throw privilege }
            let source = try moveOperand(mode: mode, register: register, size: 2, cursor: &cursor, memory: &memory)
            let value = UInt16(try read(source, size: 2, memory: &memory))
            if toStatus { statusRegister = value } else { status = (status & 0xFF00) | (value & 0x1F) }
        case _ where opcode & 0xFFC0 == 0x4AC0: // TAS (Amiga chip-bus RMW quirks not modelled)
            guard Self.isDataAlterable(mode, register) else { throw unsupported }
            let target = try moveOperand(mode: mode, register: register, size: 1, cursor: &cursor, memory: &memory)
            let value = try read(target, size: 1, memory: &memory)
            setLogicFlags(value, size: 1)
            try write(value | 0x80, to: target, size: 1, memory: &memory)
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
                let result = addSub(0, value, size: size, subtract: true, extend: opcode & 0x0200 == 0)
                try write(result, to: target, size: size, memory: &memory)
            }
        default:
            throw unsupported
        }
        programCounter = cursor
    }

    /// MOVEM: register list to memory (control or predecrement) or memory to registers
    /// (control or postincrement). Words loaded into registers are sign-extended.
    private mutating func moveMultiple(_ opcode: UInt16, cursor: inout UInt32,
                                       memory: inout AmigaMemory) throws {
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
        if mode == 4 { // predecrement: bit 0 = A7 ... bit 15 = D0, stored downwards
            var address = self[address: register]
            for bit in 0..<16 where list & (1 << bit) != 0 {
                let index = 15 - bit
                let value = index < 8 ? self[data: index] : self[address: index - 8]
                address &-= size
                if size == 4 { try memory.writeLong(value, at: address) }
                else { try memory.writeWord(UInt16(truncatingIfNeeded: value), at: address) }
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
                    ? try memory.readLong(at: address)
                    : Self.signExtendWord(try memory.readWord(at: address))
                if index < 8 { self[data: index] = value } else { self[address: index - 8] = value }
            } else {
                let value = index < 8 ? self[data: index] : self[address: index - 8]
                if size == 4 { try memory.writeLong(value, at: address) }
                else { try memory.writeWord(UInt16(truncatingIfNeeded: value), at: address) }
            }
            address &+= size
        }
        if mode == 3 { self[address: register] = address }
    }

    /// OR ($8), EOR ($B, opmodes 4–6), AND ($C), MULU/MULS, DIVU/DIVS and EXG.
    /// ABCD/SBCD and CMPM encodings are rejected.
    private mutating func logical(_ opcode: UInt16, memory: inout AmigaMemory) throws {
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
            } else {
                guard source != 0 else { throw Trap(vector: 5, returnAddress: cursor) }
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
                    // Destination unchanged; V set, C cleared (N and Z left as they were).
                    status = (status & 0xFFFC) | 0x02
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
    }

    /// ASL/ASR, LSL/LSR, ROXL/ROXR, ROL/ROR on Dn (count 1–8 or Dn mod 64) and on memory words.
    private mutating func shift(_ opcode: UInt16, memory: inout AmigaMemory) throws {
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
    }

    private enum MoveOperand {
        case data(Int), address(Int), memory(UInt32), immediate(UInt32)
    }

    /// CMP <ea>,Dn; CMPA <ea>,An; CMPI #imm,<ea>. Sets NZVC from destination - source; X is unchanged.
    private mutating func compare(_ opcode: UInt16, memory: inout AmigaMemory) throws {
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
    }

    /// ADD, ADDA, ADDQ, SUB, SUBA and SUBQ. ADDX/SUBX encodings are rejected.
    private mutating func arithmetic(_ opcode: UInt16, memory: inout AmigaMemory) throws {
        let mode = Int((opcode >> 3) & 7)
        let register = Int(opcode & 7)
        let upper = Int((opcode >> 9) & 7)
        let opmode = Int((opcode >> 6) & 7)
        let quick = opcode & 0xF000 == 0x5000
        let subtract = quick ? opcode & 0x0100 != 0 : opcode & 0x4000 == 0
        let addressForm = !quick && opmode & 3 == 3 // ADDA / SUBA
        let size = addressForm ? (opmode == 3 ? 2 : 4) : [1, 2, 4][opmode & 3]
        let toEffectiveAddress = quick || (!addressForm && opmode >= 4)
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
    }

    private func read(_ operand: MoveOperand, size: Int, memory: inout AmigaMemory) throws -> UInt32 {
        let mask: UInt32 = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
        switch operand {
        case .data(let register): return self[data: register] & mask
        case .address(let register): return self[address: register] & mask
        case .immediate(let value): return value & mask
        case .memory(let address):
            switch size {
            case 1: return UInt32(try memory.readByte(at: address))
            case 2: return UInt32(try memory.readWord(at: address))
            default: return try memory.readLong(at: address)
            }
        }
    }

    private mutating func write(_ value: UInt32, to operand: MoveOperand, size: Int,
                                memory: inout AmigaMemory) throws {
        let mask: UInt32 = size == 1 ? 0xFF : size == 2 ? 0xFFFF : 0xFFFF_FFFF
        switch operand {
        case .data(let register): self[data: register] = (self[data: register] & ~mask) | value
        case .address(let register): self[address: register] = value
        case .memory(let address):
            switch size {
            case 1: try memory.writeByte(UInt8(value), at: address)
            case 2: try memory.writeWord(UInt16(value), at: address)
            default: try memory.writeLong(value, at: address)
            }
        case .immediate: preconditionFailure("Immediate operands are not writable")
        }
    }

    private mutating func move(_ opcode: UInt16, memory: inout AmigaMemory) throws {
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
            case 2: value = UInt32(try memory.readWord(at: address))
            default: value = try memory.readLong(at: address)
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
            case 2: try memory.writeWord(UInt16(value), at: address)
            default: try memory.writeLong(value, at: address)
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
    }

    private static func signExtendWord(_ word: UInt16) -> UInt32 {
        UInt32(bitPattern: Int32(Int16(bitPattern: word)))
    }

    private func extensionWord(cursor: inout UInt32, memory: inout AmigaMemory) throws -> UInt16 {
        let word = try memory.readWord(at: cursor)
        cursor &+= 2
        return word
    }

    private func indexedAddress(base: UInt32, cursor: inout UInt32,
                                memory: inout AmigaMemory) throws -> UInt32 {
        let word = try extensionWord(cursor: &cursor, memory: &memory)
        let register = Int((word >> 12) & 7)
        var index = word & 0x8000 == 0 ? self[data: register] : self[address: register]
        if word & 0x0800 == 0 { index = Self.signExtendWord(UInt16(truncatingIfNeeded: index)) }
        // MC68000 ignores bits 10...8; no scaled or full-extension addressing.
        let displacement = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: word))))
        return base &+ index &+ displacement
    }

    /// Called only after MOVE's source and destination mode legality has been checked.
    private mutating func moveOperand(mode: Int, register: Int, size: Int,
                                      cursor: inout UInt32, memory: inout AmigaMemory) throws -> MoveOperand {
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

    private func conditionHolds(_ condition: Int) -> Bool {
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
