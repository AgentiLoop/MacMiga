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
    public mutating func step(memory: inout AmigaMemory) throws {
        let instructionAddress = programCounter
        let opcode = try memory.readWord(at: instructionAddress)
        let nextWord = instructionAddress &+ 2

        switch opcode {
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
        default:
            throw CPUError.unsupportedInstruction(opcode: opcode, address: instructionAddress)
        }
    }

    private func conditionHolds(_ condition: Int) -> Bool {
        let carry = status & 1 != 0
        let overflow = status & 2 != 0
        let zero = status & 4 != 0
        let negative = status & 8 != 0
        switch condition {
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
        default: preconditionFailure("Expected a Bcc condition in 2...15")
        }
    }
}
