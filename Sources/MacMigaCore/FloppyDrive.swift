public enum FloppyError: Error, Equatable {
    case invalidADFSize(Int)
    case invalidExtendedADF
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
    public static let trackSize = sectorsPerTrack * 512
    public static let adfSize = cylinders * 2 * trackSize
    /// MFM words per track: 11 sectors of 544 words plus a 350-word gap (12,668 bytes).
    public static let trackWords = 6334

    public private(set) var cylinder = 0
    public private(set) var motorOn = false
    public private(set) var selected = false
    public private(set) var side = 0
    /// AmigaDOS sector data of the inserted disk (tracks stored raw read as zeros here).
    public private(set) var disk: [UInt8]?
    /// Tracks of an extended ADF that are stored as raw MFM (copy-protected disks), by track number.
    public private(set) var rawTracks: [Int: [UInt16]] = [:]
    public var hasDisk: Bool { disk != nil }
    /// Latched disk-change state driving /CHNG.
    public private(set) var diskChanged = true
    /// Word position of the read head within the rotating MFM track.
    var rotation = 0
    /// Counts drive activity (motor switched on, head steps, disk DMA transfers), so a host
    /// can tell when the disk is busy.
    public internal(set) var activity = 0
    private var previousControl: UInt8 = 0xFF

    public init(disk: [UInt8]? = nil, rawTracks: [Int: [UInt16]] = [:]) {
        self.disk = disk
        self.rawTracks = rawTracks
    }

    /// Inserts a disk image: a plain 901,120-byte AmigaDOS ADF (a few trailing bytes are
    /// ignored) or a UAE extended ADF (`UAE--ADF` or `UAE-1ADF`) with raw MFM tracks.
    public mutating func insert(adf: [UInt8]) throws {
        let (sectors, raw) = try Self.parse(adf)
        disk = sectors
        rawTracks = raw
        diskChanged = true
    }

    public mutating func eject() {
        disk = nil
        rawTracks = [:]
        diskChanged = true
    }

    static func parse(_ image: [UInt8]) throws -> ([UInt8], [Int: [UInt16]]) {
        if image.starts(with: Array("DMS!".utf8)) { return try parse(DMS.unpack(image)) }
        func word(_ offset: Int) -> Int { Int(image[offset]) << 8 | Int(image[offset + 1]) }
        func long(_ offset: Int) -> Int { word(offset) << 16 | word(offset + 2) }
        /// A track's stored bytes; a track that runs past the end of the file (other than a
        /// raw `UAE--ADF` track, below), or an AmigaDOS track shorter than 11 sectors, makes
        /// the image invalid.
        func bytes(_ offset: Int, _ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= image.count else { throw FloppyError.invalidExtendedADF }
            return Array(image[offset..<offset + count])
        }
        func dos(_ offset: Int, _ length: Int) throws -> [UInt8] {
            // An unused track may be stored with length 0; it reads as zeros.
            if length == 0 { return [UInt8](repeating: 0, count: trackSize) }
            guard length >= trackSize else { throw FloppyError.invalidExtendedADF }
            return try bytes(offset, trackSize)
        }
        func words(_ data: [UInt8]) -> [UInt16] {
            stride(from: 0, to: data.count - 1, by: 2).map { UInt16(data[$0]) << 8 | UInt16(data[$0 + 1]) }
        }
        let magic = String(decoding: image.prefix(8), as: UTF8.self)
        var sectors = [UInt8](repeating: 0, count: adfSize)
        var raw = [Int: [UInt16]]()
        func store(dos data: [UInt8], track: Int) {
            sectors.replaceSubrange(track * trackSize..<(track + 1) * trackSize, with: data)
        }
        switch magic {
        case "UAE--ADF":
            // 160 entries of sync word and byte length; sync 0 = AmigaDOS data, otherwise
            // raw MFM that follows that sync word.
            guard image.count >= 8 + 160 * 4 else { throw FloppyError.invalidExtendedADF }
            var offset = 8 + 160 * 4
            for track in 0..<160 {
                let sync = word(8 + track * 4), length = word(10 + track * 4)
                if sync == 0 {
                    store(dos: try dos(offset, length), track: track)
                } else {
                    // Some images end a few bytes short inside their last raw track
                    // (Turrican's, by 192 bytes); the stored part is used.
                    raw[track] = [UInt16(sync)] + words(try bytes(offset, max(0, min(length, image.count - offset))))
                }
                offset += length
            }
        case "UAE-1ADF":
            // Track count at 10, then per track: type at +2 (0 AmigaDOS, 1 raw MFM),
            // stored bytes at +4, length in bits at +8.
            guard image.count >= 12 else { throw FloppyError.invalidExtendedADF }
            let count = min(word(10), 160)
            guard image.count >= 12 + count * 12 else { throw FloppyError.invalidExtendedADF }
            var offset = 12 + count * 12
            for track in 0..<count {
                let header = 12 + track * 12
                let type = word(header + 2), length = long(header + 4), bits = long(header + 8)
                if type == 0 {
                    store(dos: try dos(offset, length), track: track)
                } else {
                    let used = bits > 0 ? min((bits + 15) / 16 * 2, length) : length
                    guard used >= 2 else { throw FloppyError.invalidExtendedADF }
                    raw[track] = words(try bytes(offset, used))
                    guard offset + length <= image.count else { throw FloppyError.invalidExtendedADF }
                }
                offset += length
            }
        default:
            guard image.count >= adfSize, image.count < adfSize + 512 else {
                throw FloppyError.invalidADFSize(image.count)
            }
            sectors = Array(image.prefix(adfSize))
        }
        return (sectors, raw.filter { !$0.value.isEmpty })
    }


    /// Applies a new CIA-B port B value.
    mutating func control(_ value: UInt8) {
        let select = value & 0x08 == 0
        if select && previousControl & 0x08 != 0 {
            if !motorOn && value & 0x80 == 0 { activity &+= 1 }
            motorOn = value & 0x80 == 0
        }
        selected = select
        side = value & 0x04 == 0 ? 1 : 0
        if select && previousControl & 0x01 != 0 && value & 0x01 == 0 {
            activity &+= 1
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
        let track = cylinder * 2 + side
        return rawTracks[track] ?? Self.encodeTrack(disk, track: track)
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
/// while DMACON DMAEN and DSKEN are set. Reads with ADKCON WORDSYNC wait for DSKSYNC in
/// the rotating track (raising INTREQ DSKSYN) and copy the words after it; without a disk,
/// a synced read never completes. Writes are discarded (disks are write-protected). The
/// words are in memory at once, but INTREQ DSKBLK follows only after the time the head
/// takes to pass over them at 2 µs per bit cell (`colorClocksPerWord` per word, the wait
/// for the sync included): trackloaders clear DSKBLK after starting a transfer and then
/// wait for it.
extension AmigaMemory {
    /// 16 bit cells of 2 µs at 3,546,895 colour clocks a second.
    static let colorClocksPerWord = 114

    mutating func runPendingDiskDMA() {
        typealias R = CustomChips.Register
        guard custom.diskDMAPending, custom.dmacon & 0x0210 == 0x0210 else { return }
        custom.diskDMAPending = false
        drive.activity &+= 1
        let length = Int(custom.register(R.dsklen) & 0x3FFF)
        var waited = 0
        if custom.register(R.dsklen) & 0x4000 == 0 {
            let track = drive.selected ? drive.currentTrack().flatMap { $0.isEmpty ? nil : $0 } : nil
            var position = drive.rotation
            if let track {
                // Tracks differ in length (raw tracks of extended ADFs), so the position
                // carried over from another track is brought within this one.
                position %= track.count
                if custom.adkcon & 0x0400 != 0 {
                    let sync = custom.register(R.dsksync)
                    guard let found = (0..<track.count).first(where: {
                        track[(position + $0) % track.count] == sync
                    }) else { return }
                    position = (position + found + 1) % track.count
                    waited = found + 1
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
        custom.diskBlockDelay = max(1, (waited + length) * Self.colorClocksPerWord)
    }
}
