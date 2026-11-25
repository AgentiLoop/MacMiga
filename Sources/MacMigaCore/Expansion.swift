/// Zorro II expansion bus: the AUTOCONFIG chain Kickstart's expansion.library walks at
/// `$E80000`.
///
/// One unconfigured board at a time answers in the 64 KiB window. Its identification ROM
/// is read a nibble at a time: logical byte `n` has its high nibble in bits 7–4 of address
/// `n` and its low nibble in bits 7–4 of address `n + 2`, inverted for everything except
/// er_Type (`$00`). Writing the board's base address (low nibble byte to `$4A`, then the
/// byte to `$48`) configures it and lets the next board answer; a write to `$4C` shuts the
/// board up instead. With no board left the window reads 0, which is not a valid er_Type.
public struct ExpansionBus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Fast RAM that Kickstart links into the free memory list.
        case fastRAM
        /// The hard-disk controller with its boot ROM (`HardDiskController`).
        case hardDisk
    }

    public struct Board: Equatable, Sendable {
        public let kind: Kind
        /// Size of the address range the board decodes once configured.
        public let size: UInt32
        /// Identification ROM as it appears on the bus (nibbles in bits 7–4).
        public let identification: [UInt8]
        /// Assigned base address; nil while unconfigured or after a shut-up.
        public internal(set) var base: UInt32?
        var isShutUp = false
    }

    /// The Zorro II "hackers" manufacturer number, for boards without a registered maker.
    public static let manufacturer: UInt16 = 2011
    public static let fastRAMProduct: UInt8 = 1
    public static let hardDiskProduct: UInt8 = 2

    public private(set) var boards: [Board] = []
    private var lowNibbleByte: UInt8 = 0

    public init() {}

    /// Index of the board currently answering at `$E80000`.
    public var pendingBoard: Int? { boards.firstIndex { $0.base == nil && !$0.isShutUp } }

    /// Fits the boards for a power-on or reset: all of them start unconfigured.
    /// `fastRAMSize` is 0 or 64 KiB … 8 MiB (a power of two); `hardDisk` adds the controller.
    public mutating func install(fastRAMSize: Int, hardDisk: Bool) {
        boards = []
        lowNibbleByte = 0
        if fastRAMSize > 0 {
            // er_Type: Zorro II, link into the memory list; er_Flags: wants the 8 MiB space.
            boards.append(Self.board(.fastRAM, size: UInt32(fastRAMSize), type: 0xE0, product: Self.fastRAMProduct,
                                     flags: 0x80, diagnosticVector: 0))
        }
        if hardDisk {
            // er_Type: Zorro II with a valid DiagArea; er_Flags: cannot be shut up.
            boards.append(Self.board(.hardDisk, size: 0x1_0000, type: 0xD0, product: Self.hardDiskProduct,
                                     flags: 0x40, diagnosticVector: HardDiskController.diagnosticOffset))
        }
    }

    private static func board(_ kind: Kind, size: UInt32, type: UInt8, product: UInt8, flags: UInt8,
                              diagnosticVector: UInt16) -> Board {
        // er_Type size code: 64K=1, 128K=2, … 4M=7, 8M=0.
        precondition(size >= 0x1_0000 && size <= 0x80_0000 && size & (size - 1) == 0)
        let sizeCode = UInt8((size >> 16).trailingZeroBitCount + 1) & 7
        var rom = [UInt8](repeating: 0xFF, count: 256)
        func set(_ offset: Int, _ value: UInt8) {
            let stored = offset == 0 ? value : ~value
            rom[offset] = stored & 0xF0
            rom[offset + 2] = (stored & 0x0F) << 4
        }
        set(0x00, type | sizeCode)
        set(0x04, product)
        set(0x08, flags)
        set(0x10, UInt8(manufacturer >> 8))
        set(0x14, UInt8(manufacturer & 0xFF))
        for offset in stride(from: 0x18, through: 0x24, by: 4) { set(offset, 0) } // serial number
        set(0x28, UInt8(diagnosticVector >> 8))
        set(0x2C, UInt8(diagnosticVector & 0xFF))
        return Board(kind: kind, size: size, identification: rom, base: nil)
    }

    /// Reads the configuration window (`offset` from `$E80000`).
    public func read(offset: Int) -> UInt8 {
        guard let index = pendingBoard else { return 0 }
        return offset < 256 ? boards[index].identification[offset] : 0xFF
    }

    /// Writes the configuration window. Returns the board that was just configured, if any.
    public mutating func write(offset: Int, value: UInt8) -> Board? {
        guard let index = pendingBoard else { return nil }
        switch offset {
        case 0x4A:
            lowNibbleByte = value
        case 0x48:
            // A23–A20 come with this write; A19–A16 were latched from `$4A` (bits 7–4).
            boards[index].base = UInt32(value | lowNibbleByte >> 4) << 16
            lowNibbleByte = 0
            return boards[index]
        case 0x4C:
            boards[index].isShutUp = true
        default:
            break
        }
        return nil
    }
}
