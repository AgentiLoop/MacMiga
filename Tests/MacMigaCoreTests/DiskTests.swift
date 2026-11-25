import Testing
@testable import MacMigaCore

private func patternADF() -> [UInt8] {
    (0..<FloppyDrive.adfSize).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 / 512) }
}

/// Reads an odd/even-split block of `count` longs starting at word `index`.
private func decodeLongs(_ words: [UInt16], at index: Int, count: Int) -> ([UInt32], UInt32) {
    func long(_ i: Int) -> UInt32 { UInt32(words[i]) << 16 | UInt32(words[i + 1]) }
    var values = [UInt32](), check: UInt32 = 0
    for n in 0..<count {
        let odd = long(index + n * 2), even = long(index + (count + n) * 2)
        values.append((odd & 0x5555_5555) << 1 | even & 0x5555_5555)
        check ^= odd ^ even
    }
    return (values, check & 0x5555_5555)
}

@Test func mfmTrackDecodesBackToSectorsWithValidChecksums() {
    let adf = patternADF()
    let track = 37
    let words = FloppyDrive.encodeTrack(adf, track: track)
    #expect(words.count == FloppyDrive.trackWords)
    var bitStream = [Bool]()
    for word in words { for bit in (0..<16).reversed() { bitStream.append(word >> UInt16(bit) & 1 != 0) } }
    var violations = 0
    for i in 1..<bitStream.count where bitStream[i] && bitStream[i - 1] { violations += 1 }
    #expect(violations == 0) // MFM never has two adjacent 1 bits
    var index = 0, found = 0
    while index < words.count - 4 {
        guard words[index] == 0x4489, words[index + 1] == 0x4489 else { index += 1; continue }
        let start = index + 2
        let (info, infoCheck) = decodeLongs(words, at: start, count: 1)
        let (_, labelCheck) = decodeLongs(words, at: start + 4, count: 4)
        let (header, _) = decodeLongs(words, at: start + 20, count: 1)
        let (dataSum, _) = decodeLongs(words, at: start + 24, count: 1)
        let (data, dataCheck) = decodeLongs(words, at: start + 28, count: 128)
        let sector = Int(info[0] >> 8 & 0xFF)
        #expect(info[0] >> 16 == 0xFF00 | UInt32(track))
        #expect(Int(info[0] & 0xFF) == 11 - sector)
        #expect(header[0] == infoCheck ^ labelCheck)
        #expect(dataSum[0] == dataCheck)
        let base = (track * 11 + sector) * 512
        let expected = (0..<128).map { i in
            (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(adf[base + i * 4 + $1]) }
        }
        #expect(data == expected)
        found += 1
        index = start + 28 + 256
    }
    #expect(found == 11)
}

@Test func rejectsWrongADFSize() throws {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024), slowRAMSize: 0)
    #expect(throws: FloppyError.invalidADFSize(1000)) { try memory.insertDisk(adf: [UInt8](repeating: 0, count: 1000)) }
}

private func driveMemory(disk: Bool) throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024), slowRAMSize: 0)
    memory.setOverlay(enabled: false)
    if disk { try memory.insertDisk(adf: patternADF()) }
    try memory.writeByte(0xFF, at: 0xBFD100)
    try memory.writeByte(0xFF, at: 0xBFD300)
    try memory.writeByte(0x77, at: 0xBFD100) // select DF0, motor on
    return memory
}

@Test func diskChangeClearsOnStepAndInsertedDiskIsWriteProtected() throws {
    var memory = try driveMemory(disk: true)
    #expect(try memory.readByte(at: 0xBFE001) & 0x3C == 0x00) // /RDY /TK0 /WPRO /CHNG all low
    try memory.writeByte(0x74, at: 0xBFD100)                   // step inwards
    try memory.writeByte(0x75, at: 0xBFD100)
    #expect(try memory.readByte(at: 0xBFE001) & 0x3C == 0x14)  // /CHNG released, off track 0
    try memory.insertDisk(adf: nil)
    #expect(try memory.readByte(at: 0xBFE001) & 0x3C == 0x18)  // ejected: /CHNG low, not protected
}

private func startDiskRead(_ memory: inout AmigaMemory, words: UInt16, sync: Bool) throws {
    try memory.writeWord(0x4489, at: 0xDFF07E)                  // DSKSYNC
    try memory.writeWord(sync ? 0x8400 : 0x0400, at: 0xDFF09E)  // ADKCON WORDSYNC
    try memory.writeLong(0x10000, at: 0xDFF020)                 // DSKPT
    try memory.writeWord(0x8210, at: 0xDFF096)                  // DMAEN | DSKEN
    try memory.writeWord(0x8000 | words, at: 0xDFF024)
    memory.advanceChipset(colorClocks: 1)
    #expect(memory.custom.intreq & 0x0002 == 0)                 // one DSKLEN write is not enough
    try memory.writeWord(0x8000 | words, at: 0xDFF024)
    memory.advanceChipset(colorClocks: 1)
}

@Test func syncedDiskReadCopiesWordsAfterSyncAndRaisesDiskBlock() throws {
    var memory = try driveMemory(disk: true)
    try startDiskRead(&memory, words: 8, sync: true)
    #expect(memory.custom.intreq & 0x1002 == 0x1002) // DSKSYN and DSKBLK
    let track = FloppyDrive.encodeTrack(patternADF(), track: 0)
    #expect(try memory.readWord(at: 0x10000) == 0x4489) // second sync word of sector 0
    for i in 1..<8 { #expect(try memory.readWord(at: 0x10000 + UInt32(i * 2)) == track[3 + i]) }
    #expect(memory.custom.diskPointer == 0x10010)
}

@Test func syncedReadWithoutDiskNeverCompletes() throws {
    var memory = try driveMemory(disk: false)
    try startDiskRead(&memory, words: 8, sync: true)
    memory.advanceChipset(colorClocks: 1000)
    #expect(memory.custom.intreq & 0x0002 == 0)
    try memory.writeWord(0x4000, at: 0xDFF024) // cancel; unsynced reads complete with zeros
    try startDiskRead(&memory, words: 4, sync: false)
    #expect(memory.custom.intreq & 0x0002 != 0)
}

@Test func extendedADFsKeepRawTracksAndSectorData() throws {
    let adf = patternADF()
    // Old UAE format: track 1 raw (sync $9521, 4 bytes), the rest AmigaDOS.
    var old = Array("UAE--ADF".utf8)
    for track in 0..<160 { old += track == 1 ? [0x95, 0x21, 0x00, 0x04] : [0x00, 0x00, 0x16, 0x00] }
    for track in 0..<160 {
        old += track == 1 ? [0x12, 0x34, 0x56, 0x78] : Array(adf[track * 5632..<(track + 1) * 5632])
    }
    var drive = FloppyDrive()
    try drive.insert(adf: old)
    #expect(drive.rawTracks == [1: [0x9521, 0x1234, 0x5678]])
    #expect(drive.disk?[0..<5632] == adf[0..<5632])
    #expect(drive.disk?[2 * 5632..<FloppyDrive.adfSize] == adf[2 * 5632..<FloppyDrive.adfSize])

    // New UAE format: two tracks, track 0 AmigaDOS, track 1 raw with 24 bits used.
    var new = Array("UAE-1ADF".utf8) + [0, 0, 0, 2]
    new += [0, 0, 0, 0, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00, 0xB0, 0x00]
    new += [0, 0, 0, 1, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x18]
    new += Array(adf[0..<5632]) + [0x44, 0x89, 0x44, 0x89, 0xAA, 0xAA]
    try drive.insert(adf: new)
    #expect(drive.rawTracks == [1: [0x4489, 0x4489]])
    #expect(drive.disk?[0..<5632] == adf[0..<5632])

    // A plain image with a stray trailing byte still loads; other sizes do not.
    try drive.insert(adf: adf + [0])
    #expect(drive.disk == adf && drive.rawTracks.isEmpty)
    #expect(throws: FloppyError.invalidADFSize(1000)) { try drive.insert(adf: [UInt8](repeating: 0, count: 1000)) }
}
