public enum HardDiskError: Error, Equatable {
    /// The image is not a whole number of 512-byte blocks or is smaller than one cylinder.
    case invalidImageSize(Int)
    /// The image starts with a Rigid Disk Block (`RDSK`); partitioned images are not supported yet.
    case rigidDiskBlockUnsupported
}

/// A hard disk image ("hardfile"): one AmigaDOS partition without a partition table, as
/// used by UAE. Geometry is fixed at 512-byte blocks, 1 surface, 32 blocks per track and
/// 2 reserved blocks; blocks past the last whole cylinder are not used.
///
/// A class, so that copies of the machine share the one disk and writes never copy the image.
public final class HardDisk {
    public static let blockSize = 512
    public static let blocksPerTrack = 32
    public static let cylinderSize = blockSize * blocksPerTrack

    public private(set) var bytes: [UInt8]
    public let isWriteProtected: Bool
    /// Blocks written since the last `takeModifiedBlocks()`, for the host to save.
    public private(set) var modifiedBlocks = Set<Int>()
    public private(set) var blocksRead = 0
    public private(set) var blocksWritten = 0

    public init(image: [UInt8], writeProtected: Bool = false) throws {
        guard image.count >= Self.cylinderSize, image.count % Self.blockSize == 0 else {
            throw HardDiskError.invalidImageSize(image.count)
        }
        guard !image.starts(with: [0x52, 0x44, 0x53, 0x4B]) else { throw HardDiskError.rigidDiskBlockUnsupported }
        bytes = image
        isWriteProtected = writeProtected
    }

    public var cylinders: Int { bytes.count / Self.cylinderSize }
    /// Bytes inside whole cylinders, which is all the Amiga can address.
    public var capacity: Int { cylinders * Self.cylinderSize }

    /// The DosType for the mount: the image's own `DOS\0`…`DOS\7` signature, else `DOS\1` (FFS).
    public var dosType: UInt32 {
        guard bytes.starts(with: [0x44, 0x4F, 0x53]), bytes[3] < 8 else { return 0x444F_5301 }
        return 0x444F_5300 | UInt32(bytes[3])
    }

    /// Returns and clears the set of blocks written since the last call, in ascending order.
    public func takeModifiedBlocks() -> [Int] {
        defer { modifiedBlocks.removeAll(keepingCapacity: true) }
        return modifiedBlocks.sorted()
    }

    func read(at offset: Int, count: Int) -> ArraySlice<UInt8> {
        blocksRead += (count + Self.blockSize - 1) / Self.blockSize
        return bytes[offset..<offset + count]
    }

    func write(_ data: [UInt8], at offset: Int) {
        guard !data.isEmpty else { return }
        bytes.replaceSubrange(offset..<offset + data.count, with: data)
        let blocks = offset / Self.blockSize...(offset + data.count - 1) / Self.blockSize
        modifiedBlocks.formUnion(blocks)
        blocksWritten += blocks.count
    }
}

/// The hard-disk controller: a 64 KiB Zorro II board carrying a boot ROM and three
/// long-word registers. It is not a model of any real controller.
///
/// The boot ROM (generated for the address Kickstart assigns) holds a DiagArea with a
/// Resident tag for `macmiga.device`. Kickstart copies the DiagArea to RAM and calls its
/// DiagPoint, then initialises the Resident: the device is created, a DOS node `DH0` is
/// made with expansion.library's MakeDosNode and queued for booting (AddBootNode on V36+,
/// a BootNode on eb_MountList before that). The BootPoint starts dos.library.
///
/// The 68000 code is kept minimal by handing the work to the host through the registers:
/// - `$8000` request: writing an IORequest pointer performs the command at once. Reading
///   returns 0 when the request is finished, 1 when the device keeps it (TD_ADDCHANGEINT).
/// - `$8004` diagnostic: writing the DiagArea copy's address fixes up its Resident tag.
/// - `$8008` device: writing the new device base fills in its library node.
public struct HardDiskController: Equatable, Sendable {
    /// Board offset of the DiagArea (er_InitDiagVec).
    public static let diagnosticOffset: UInt16 = 0x0100
    public static let requestRegister = 0x8000
    public static let diagnosticRegister = 0x8004
    public static let deviceRegister = 0x8008
    public static let deviceName = "macmiga.device"
    public static let dosName = "DH0"

    /// Assigned board address; `UInt32.max` while unconfigured.
    var base = UInt32.max
    /// Board contents from offset 0 (the boot ROM starts at `diagnosticOffset`).
    var rom: [UInt8] = []
    /// Offsets of the ROM's labels from the DiagArea.
    var labels: [String: Int] = [:]
    var latch: UInt32 = 0
    var requestPending = false

    /// Board address of a boot ROM label, e.g. `beginIO` or `parameters`.
    public func address(of label: String) -> UInt32? {
        labels[label].map { base + UInt32(Self.diagnosticOffset) + UInt32($0) }
    }

    mutating func configure(base: UInt32, disk: HardDisk) {
        self.base = base
        let origin = base + UInt32(Self.diagnosticOffset)
        // Every instruction has a fixed size, so a first pass yields the final label offsets.
        let sizes = Self.bootROM(origin: origin, base: base, disk: disk, known: [:])
        let final = Self.bootROM(origin: origin, base: base, disk: disk, known: sizes.labels)
        rom = [UInt8](repeating: 0, count: Int(Self.diagnosticOffset)) + final.bytes
        labels = final.labels
    }

    private struct Assembler {
        var bytes: [UInt8] = []
        var labels: [String: Int] = [:]
        let origin: UInt32
        let known: [String: Int]

        mutating func label(_ name: String) { labels[name] = bytes.count }
        func offset(_ name: String) -> Int { known[name] ?? 0 }
        func address(_ name: String) -> UInt32 { origin + UInt32(offset(name)) }
        mutating func word(_ values: UInt16...) {
            for value in values { bytes += [UInt8(value >> 8), UInt8(value & 0xFF)] }
        }
        mutating func long(_ values: UInt32...) {
            for value in values { word(UInt16(value >> 16), UInt16(value & 0xFFFF)) }
        }
        /// A Bcc.S (`opcode` = `$6x00`) to a label.
        mutating func branch(_ opcode: UInt16, to name: String) {
            word(opcode | UInt16(UInt8(truncatingIfNeeded: offset(name) - (bytes.count + 2))))
        }
        mutating func string(_ text: String) {
            bytes += Array(text.utf8) + [0]
            if bytes.count % 2 != 0 { bytes.append(0) }
        }
    }

    private static func bootROM(origin: UInt32, base: UInt32, disk: HardDisk,
                                known: [String: Int]) -> (bytes: [UInt8], labels: [String: Int]) {
        var a = Assembler(origin: origin, known: known)
        let request = base + UInt32(requestRegister)
        let diagnostic = base + UInt32(diagnosticRegister)
        let device = base + UInt32(deviceRegister)

        // struct DiagArea
        a.word(0x9000)                                    // da_Config DAC_WORDWIDE|DAC_CONFIGTIME, da_Flags
        a.word(UInt16(a.offset("copyEnd")))               // da_Size
        a.word(UInt16(a.offset("diagPoint")))             // da_DiagPoint
        a.word(UInt16(a.offset("bootPoint")))             // da_BootPoint
        a.word(0, 0, 0)                                   // da_Name, reserved
        // struct Resident; MatchTag and EndSkip are pointed at the RAM copy by the host.
        a.label("romTag")
        a.word(0x4AFC)                                    // rt_MatchWord
        a.long(a.address("romTag"), a.address("copyEnd")) // rt_MatchTag, rt_EndSkip
        a.word(0x8101, 0x0314)                            // RTF_AUTOINIT|RTF_COLDSTART, version 1, NT_DEVICE, pri 20
        a.long(a.address("deviceName"), a.address("idString"), a.address("initTable"))
        // DiagPoint(a0 board, a2 DiagArea copy, a3 ConfigDev)
        a.label("diagPoint")
        a.word(0x23CA); a.long(diagnostic)                // move.l a2,(diagnostic).l
        a.word(0x7001, 0x4E75)                            // moveq #1,d0 ; rts
        // BootPoint(a6 SysBase): start dos.library
        a.label("bootPoint")
        a.word(0x43F9); a.long(a.address("dosLibrary"))   // lea dosLibrary,a1
        a.word(0x4EAE, 0xFFA0)                            // jsr FindResident(a6)
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6700, to: "bootDone")                  // beq.s bootDone
        a.word(0x2040, 0x2068, 0x0016, 0x4E90)            // movea.l d0,a0 ; movea.l rt_Init(a0),a0 ; jsr (a0)
        a.label("bootDone")
        a.word(0x4E75)                                    // rts
        a.label("copyEnd")

        // RTF_AUTOINIT table: data size, function table, data table, init routine
        a.label("initTable")
        a.long(36, a.address("functions"), 0, a.address("initialize"))
        a.label("functions")
        a.long(a.address("open"), a.address("close"), a.address("null"), a.address("null"),
               a.address("beginIO"), a.address("null"), 0xFFFF_FFFF)

        // initialize(d0 device, a6 SysBase) -> d0 device
        a.label("initialize")
        a.word(0x48E7, 0x2032)                            // movem.l d2/a2-a3/a6,-(sp)
        a.word(0x2400)                                    // move.l d0,d2
        a.word(0x23C0); a.long(device)                    // move.l d0,(device).l
        a.word(0x43F9); a.long(a.address("expansionLibrary")) // lea expansionLibrary,a1
        a.word(0x7000, 0x4EAE, 0xFDD8)                    // moveq #0,d0 ; jsr OpenLibrary(a6)
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6700, to: "initDone")                  // beq.s initDone
        a.word(0x2C40)                                    // movea.l d0,a6 (ExpansionBase)
        a.word(0x91C8)                                    // suba.l a0,a0
        a.word(0x203C); a.long(UInt32(ExpansionBus.manufacturer)) // move.l #manufacturer,d0
        a.word(0x7200 | UInt16(ExpansionBus.hardDiskProduct))     // moveq #product,d1
        a.word(0x4EAE, 0xFFB8)                            // jsr FindConfigDev(a6)
        a.word(0x2640)                                    // movea.l d0,a3 (ConfigDev)
        a.word(0x41F9); a.long(a.address("parameters"))   // lea parameters,a0
        a.word(0x4EAE, 0xFF70)                            // jsr MakeDosNode(a6)
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6700, to: "closeExpansion")            // beq.s closeExpansion
        a.word(0x2440)                                    // movea.l d0,a2 (DeviceNode)
        a.word(0x0C6E, 0x0024, 0x0014)                    // cmpi.w #36,lib_Version(a6)
        a.branch(0x6D00, to: "version34")                 // blt.s version34
        a.word(0x204A, 0x224B)                            // movea.l a2,a0 ; movea.l a3,a1
        a.word(0x7000, 0x7201)                            // moveq #0,d0 (boot priority) ; moveq #ADNF_STARTPROC,d1
        a.word(0x4EAE, 0xFFDC)                            // jsr AddBootNode(a6)
        a.branch(0x6000, to: "closeExpansion")            // bra.s closeExpansion
        // Kickstart 1.3: queue a BootNode on eb_MountList by hand.
        a.label("version34")
        a.word(0x2F0E, 0x2C78, 0x0004)                    // move.l a6,-(sp) ; movea.l 4.w,a6
        a.word(0x7014)                                    // moveq #BootNode_SIZEOF,d0
        a.word(0x223C); a.long(0x0001_0001)               // move.l #MEMF_PUBLIC|MEMF_CLEAR,d1
        a.word(0x4EAE, 0xFF3A)                            // jsr AllocMem(a6)
        a.word(0x2C5F)                                    // movea.l (sp)+,a6
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6700, to: "closeExpansion")            // beq.s closeExpansion
        a.word(0x2240)                                    // movea.l d0,a1
        a.word(0x137C, 0x0010, 0x0008)                    // move.b #NT_BOOTNODE,ln_Type(a1)
        a.word(0x234B, 0x000A)                            // move.l a3,ln_Name(a1) (ConfigDev)
        a.word(0x234A, 0x0010)                            // move.l a2,bn_DeviceNode(a1)
        a.word(0x41EE, 0x004A)                            // lea eb_MountList(a6),a0
        a.word(0x2F0E, 0x2C78, 0x0004)                    // move.l a6,-(sp) ; movea.l 4.w,a6
        a.word(0x4EAE, 0xFEF2)                            // jsr Enqueue(a6)
        a.word(0x2C5F)                                    // movea.l (sp)+,a6
        a.label("closeExpansion")
        a.word(0x224E, 0x2C78, 0x0004)                    // movea.l a6,a1 ; movea.l 4.w,a6
        a.word(0x4EAE, 0xFE62)                            // jsr CloseLibrary(a6)
        a.label("initDone")
        a.word(0x2002)                                    // move.l d2,d0
        a.word(0x4CDF, 0x4C04, 0x4E75)                    // movem.l (sp)+,d2/a2-a3/a6 ; rts

        // Open(a6 device, a1 request, d0 unit): only unit 0 exists
        a.label("open")
        a.word(0x4A80)                                    // tst.l d0
        a.branch(0x6600, to: "openFailed")                // bne.s openFailed
        a.word(0x526E, 0x0020)                            // addq.w #1,lib_OpenCnt(a6)
        a.word(0x234E, 0x0018)                            // move.l a6,io_Unit(a1)
        a.word(0x4229, 0x001F)                            // clr.b io_Error(a1)
        a.word(0x7000, 0x4E75)                            // moveq #0,d0 ; rts
        a.label("openFailed")
        a.word(0x70FF, 0x1340, 0x001F, 0x4E75)            // moveq #IOERR_OPENFAIL,d0 ; move.b d0,io_Error(a1) ; rts
        a.label("close")
        a.word(0x536E, 0x0020)                            // subq.w #1,lib_OpenCnt(a6)
        a.label("null")                                   // Expunge, ExtFunc, AbortIO
        a.word(0x7000, 0x4E75)                            // moveq #0,d0 ; rts
        // BeginIO(a1 request): the host runs the command; reply unless quick or kept
        a.label("beginIO")
        a.word(0x23C9); a.long(request)                   // move.l a1,(request).l
        a.word(0x4AB9); a.long(request)                   // tst.l (request).l
        a.branch(0x6600, to: "beginDone")                 // bne.s beginDone
        a.word(0x0829, 0x0000, 0x001E)                    // btst #IOB_QUICK,io_Flags(a1)
        a.branch(0x6600, to: "beginDone")                 // bne.s beginDone
        a.word(0x2F0E, 0x2C78, 0x0004)                    // move.l a6,-(sp) ; movea.l 4.w,a6
        a.word(0x4EAE, 0xFE86)                            // jsr ReplyMsg(a6)
        a.word(0x2C5F)                                    // movea.l (sp)+,a6
        a.label("beginDone")
        a.word(0x4E75)                                    // rts

        a.label("deviceName"); a.string(deviceName)
        a.label("idString"); a.string(deviceName + " 1.0 (25.11.2026)\r\n")
        a.label("dosName"); a.string(dosName)
        a.label("expansionLibrary"); a.string("expansion.library")
        a.label("dosLibrary"); a.string("dos.library")
        // MakeDosNode parameter packet: names, unit, flags, then the DosEnvec.
        a.label("parameters")
        a.long(a.address("dosName"), a.address("deviceName"), 0, 0)
        a.long(16,                                        // de_TableSize (up to de_DosType)
               UInt32(HardDisk.blockSize / 4),            // de_SizeBlock in longs
               0, 1, 1,                                   // de_SecOrg, de_Surfaces, de_SectorPerBlock
               UInt32(HardDisk.blocksPerTrack),           // de_BlocksPerTrack
               2, 0, 0,                                   // de_Reserved, de_PreAlloc, de_Interleave
               0, UInt32(disk.cylinders - 1),             // de_LowCyl, de_HighCyl
               30, 1,                                     // de_NumBuffers, de_BufMemType MEMF_PUBLIC
               0x7FFF_FFFF, 0x7FFF_FFFE,                  // de_MaxTransfer, de_Mask
               0, disk.dosType)                           // de_BootPri, de_DosType
        return (a.bytes, a.labels)
    }
}

extension AmigaMemory {
    func readHardDiskBoard(offset: Int) -> UInt8 {
        if offset < hardDiskController.rom.count { return hardDiskController.rom[offset] }
        if offset == HardDiskController.requestRegister + 3 { return hardDiskController.requestPending ? 1 : 0 }
        return 0
    }

    /// Register bytes shift into a latch; the fourth byte of a long word triggers the action.
    mutating func writeHardDiskBoard(offset: Int, value: UInt8) {
        guard offset >= HardDiskController.requestRegister, offset < HardDiskController.deviceRegister + 4 else { return }
        hardDiskController.latch = hardDiskController.latch << 8 | UInt32(value)
        guard offset & 3 == 3 else { return }
        let value = hardDiskController.latch
        switch offset & ~3 {
        case HardDiskController.requestRegister:
            performHardDiskRequest(value)
        case HardDiskController.diagnosticRegister:
            guard let tag = hardDiskController.labels["romTag"], let end = hardDiskController.labels["copyEnd"] else { return }
            try? writeLong(value &+ UInt32(tag), at: value &+ UInt32(tag) &+ 2)   // rt_MatchTag
            try? writeLong(value &+ UInt32(end), at: value &+ UInt32(tag) &+ 6)   // rt_EndSkip
        default:
            guard let name = hardDiskController.address(of: "deviceName"),
                  let id = hardDiskController.address(of: "idString") else { return }
            try? writeByte(3, at: value &+ 8)        // ln_Type NT_DEVICE
            try? writeLong(name, at: value &+ 10)    // ln_Name
            try? writeByte(0x06, at: value &+ 14)    // lib_Flags LIBF_SUMUSED|LIBF_CHANGED
            try? writeLong(0x0001_0000, at: value &+ 20) // lib_Version 1, lib_Revision 0
            try? writeLong(id, at: value &+ 24)      // lib_IdString
        }
    }

    /// Runs the IORequest at `request` to completion and stores io_Error and io_Actual.
    private mutating func performHardDiskRequest(_ request: UInt32) {
        var status: Int8 = 0
        var actual: UInt32 = 0
        hardDiskController.requestPending = false
        do {
            guard let disk = hardDisk else { return }
            let command = try readWord(at: request &+ 28)
            let length = try readLong(at: request &+ 36)
            let data = try readLong(at: request &+ 40)
            let offset = try readLong(at: request &+ 44)
            let inRange = UInt64(offset) + UInt64(length) <= UInt64(disk.capacity)
            switch command {
            case 2: // CMD_READ
                guard inRange else { status = -4; break } // IOERR_BADLENGTH
                var address = data
                for byte in disk.read(at: Int(offset), count: Int(length)) {
                    try writeByte(byte, at: address)
                    address &+= 1
                }
                actual = length
            case 3, 11: // CMD_WRITE, TD_FORMAT
                guard inRange else { status = -4; break }
                guard !disk.isWriteProtected else { status = 28; break } // TDERR_WriteProt
                var bytes = [UInt8]()
                bytes.reserveCapacity(Int(length))
                for index in 0..<length { bytes.append(try readByte(at: data &+ index)) }
                disk.write(bytes, at: Int(offset))
                actual = length
            case 1, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 21:
                // CMD_RESET/UPDATE/CLEAR/STOP/START/FLUSH, TD_MOTOR/SEEK/REMOVE/CHANGENUM,
                // TD_CHANGESTATE (0 = disk present), TD_REMCHANGEINT: nothing to do.
                break
            case 15: // TD_PROTSTATUS
                actual = disk.isWriteProtected ? 1 : 0
            case 19: // TD_GETNUMTRACKS
                actual = UInt32(disk.cylinders)
            case 20: // TD_ADDCHANGEINT: kept until TD_REMCHANGEINT; the disk never changes
                hardDiskController.requestPending = true
                try writeByte(try readByte(at: request &+ 30) & ~0x01, at: request &+ 30) // not quick
                try writeByte(5, at: request &+ 8) // ln_Type NT_MESSAGE
                return
            case 22: // TD_GETGEOMETRY
                let blocks = UInt32(disk.cylinders * HardDisk.blocksPerTrack)
                let geometry: [UInt32] = [UInt32(HardDisk.blockSize), blocks, UInt32(disk.cylinders),
                                          UInt32(HardDisk.blocksPerTrack), 1, UInt32(HardDisk.blocksPerTrack), 1, 0]
                for (index, value) in geometry.enumerated() { try writeLong(value, at: data &+ UInt32(index * 4)) }
                actual = 32
            default:
                status = -3 // IOERR_NOCMD
            }
        } catch {
            status = -5 // IOERR_BADADDRESS
        }
        try? writeByte(UInt8(bitPattern: status), at: request &+ 31)
        if request & 1 == 0 { try? writeLong(actual, at: request &+ 32) }
    }
}
