public enum FloppyError: Error, Equatable {
    case invalidADFSize(Int)
}

/// Internal 3.5" DD drive DF0 as seen through the CIAs, with an optional ADF disk.
///
/// CIA-B port B drives it (all active low): PB7 /MTR (latched when /SEL0 falls), PB3
/// /SEL0, PB2 /SIDE, PB1 DIR (high = outwards), PB0 /STEP (a falling edge moves the head).
/// While selected it answers on CIA-A port A (active low): PA5 /RDY (motor on), PA4 /TK0
/// (head on cylinder 0), PA3 /WPRO (inserted disks are write-protected), PA2 /CHNG (low
/// after power-on or an eject until a step pulse happens with a disk inserted).
/// DF1–DF3 are not connected, so selecting them leaves those inputs high. No index
/// pulses (CIA-B FLG) are generated.
public struct FloppyDrive: Equatable, Sendable {
    public static let cylinders = 80
    public static let sectorsPerTrack = 11
    public static let adfSize = cylinders * 2 * sectorsPerTrack * 512
    /// MFM words per track: 11 sectors of 544 words plus a 350-word gap (12,668 bytes).
    public static let trackWords = 6334

    public private(set) var cylinder = 0
    public private(set) var motorOn = false
    public private(set) var selected = false
    public private(set) var side = 0
    public private(set) var disk: [UInt8]?
    public var hasDisk: Bool { disk != nil }
    /// Latched disk-change state driving /CHNG.
    public private(set) var diskChanged = true
    /// Word position of the read head within the rotating MFM track.
    var rotation = 0
    private var previousControl: UInt8 = 0xFF

    public init(disk: [UInt8]? = nil) {
        self.disk = disk
    }

    /// Inserts a raw 901,120-byte AmigaDOS (ADF) image.
    public mutating func insert(adf: [UInt8]) throws {
        guard adf.count == Self.adfSize else { throw FloppyError.invalidADFSize(adf.count) }
        disk = adf
        diskChanged = true
    }

    public mutating func eject() {
        disk = nil
        diskChanged = true
    }

    /// Applies a new CIA-B port B value.
    mutating func control(_ value: UInt8) {
        let select = value & 0x08 == 0
        if select && previousControl & 0x08 != 0 { motorOn = value & 0x80 == 0 }
        selected = select
        side = value & 0x04 == 0 ? 1 : 0
        if select && previousControl & 0x01 != 0 && value & 0x01 == 0 {
            if value & 0x02 != 0 { cylinder = max(cylinder - 1, 0) }
            else { cylinder = min(cylinder + 1, Self.cylinders - 1) }
            if hasDisk { diskChanged = false }
        }
        previousControl = value
    }

    /// CIA-A port A input bits 2–5 for the current state (others stay high).
    var statusLines: UInt8 {
        guard selected else { return 0xFF }
        var lines: UInt8 = 0xFF
        if motorOn { lines &= ~0x20 }
        if cylinder == 0 { lines &= ~0x10 }
        if hasDisk { lines &= ~0x08 }
        if diskChanged { lines &= ~0x04 }
        return lines
    }

    /// MFM stream of the track under the head, or nil without a disk.
    public func currentTrack() -> [UInt16]? {
        guard let disk else { return nil }
        return Self.encodeTrack(disk, track: cylinder * 2 + side)
    }

    /// Encodes one track of an ADF image as standard AmigaDOS MFM: per sector two
    /// `$AAAA` words, two `$4489` syncs, the info long (`$FF`, track, sector, sectors to
    /// gap), a 16-byte zero label, header and data checksums, then 512 data bytes, each
    /// block stored as its odd bits followed by its even bits. A gap fills the rest.
    public static func encodeTrack(_ disk: [UInt8], track: Int) -> [UInt16] {
        var words = [UInt16]()
        words.reserveCapacity(trackWords)
        var lastBit: UInt16 = 0
        func emit(dataBits: UInt16) {
            let d = dataBits & 0x5555
            let clocks = ~((d >> 1) | (d << 1) | (lastBit << 15)) & 0xAAAA
            words.append(d | clocks)
            lastBit = d & 1
        }
        func raw(_ word: UInt16) {
            words.append(word)
            lastBit = word & 1
        }
        func longs(_ values: [UInt32]) {
            for part in [values.map { $0 >> 1 }, values] {
                for value in part {
                    emit(dataBits: UInt16(truncatingIfNeeded: value >> 16))
                    emit(dataBits: UInt16(truncatingIfNeeded: value))
                }
            }
        }
        func checksum(_ values: [UInt32]) -> UInt32 {
            values.reduce(0) { $0 ^ ($1 >> 1) ^ $1 } & 0x5555_5555
        }
        for sector in 0..<sectorsPerTrack {
            emit(dataBits: 0)
            emit(dataBits: 0)
            raw(0x4489)
            raw(0x4489)
            let info = [UInt32(0xFF) << 24 | UInt32(track) << 16 | UInt32(sector) << 8 | UInt32(sectorsPerTrack - sector)]
            let label = [UInt32](repeating: 0, count: 4)
            let base = (track * sectorsPerTrack + sector) * 512
            let data = (0..<128).map { index -> UInt32 in
                let offset = base + index * 4
                return UInt32(disk[offset]) << 24 | UInt32(disk[offset + 1]) << 16
                    | UInt32(disk[offset + 2]) << 8 | UInt32(disk[offset + 3])
            }
            longs(info)
            longs(label)
            longs([checksum(info + label)])
            longs([checksum(data)])
            longs(data)
        }
        while words.count < trackWords { emit(dataBits: 0) }
        return words
    }
}

/// Paula disk DMA. A transfer starts when DSKLEN is written twice with DMAEN (bit 15)
/// while DMACON DMAEN and DSKEN are set, and completes at once (no bit-rate timing).
/// Reads with ADKCON WORDSYNC wait for DSKSYNC in the rotating track (raising INTREQ
/// DSKSYN) and copy the words after it; without a disk, a synced read never completes.
/// Writes are discarded (disks are write-protected). Completion raises INTREQ DSKBLK.
extension AmigaMemory {
    mutating func runPendingDiskDMA() {
        typealias R = CustomChips.Register
        guard custom.diskDMAPending, custom.dmacon & 0x0210 == 0x0210 else { return }
        custom.diskDMAPending = false
        let length = Int(custom.register(R.dsklen) & 0x3FFF)
        if custom.register(R.dsklen) & 0x4000 == 0 {
            let track = drive.selected ? drive.currentTrack() : nil
            var position = drive.rotation
            if let track {
                if custom.adkcon & 0x0400 != 0 {
                    let sync = custom.register(R.dsksync)
                    guard let found = (0..<track.count).first(where: {
                        track[(position + $0) % track.count] == sync
                    }) else { return }
                    position = (position + found + 1) % track.count
                    custom.requestInterrupt(bits: 0x1000)
                }
            } else if custom.adkcon & 0x0400 != 0 {
                return
            }
            var pointer = custom.diskPointer
            for _ in 0..<length {
                writeChipWord(track?[position] ?? 0, at: pointer)
                pointer = (pointer &+ 2) & 0x1F_FFFE
                if let track { position = (position + 1) % track.count }
            }
            drive.rotation = position
            custom.diskPointer = pointer
        } else {
            custom.diskPointer = (custom.diskPointer &+ UInt32(length * 2)) & 0x1F_FFFE
        }
        custom.requestInterrupt(bits: 0x0002)
    }
}
