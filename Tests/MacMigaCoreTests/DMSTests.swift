import Testing
@testable import MacMigaCore

/// A DMS archive with the given cylinder records (number, mode, flags, packed data, unpacked data).
private func archive(_ tracks: [(number: Int, mode: UInt8, flags: UInt8, packed: [UInt8], unpacked: [UInt8])]) -> [UInt8] {
    func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    var header = Array("DMS!".utf8) + [UInt8](repeating: 0, count: 50)
    header[19] = 79                                           // highest track
    let headerCRC = DMS.crc16(header[4..<54])
    var data = header + word(Int(headerCRC))
    for track in tracks {
        var record = Array("TR".utf8) + word(track.number) + [0, 0] + word(track.packed.count) + word(track.packed.count)
            + word(track.unpacked.count) + [track.flags, track.mode]
            + word(track.unpacked.reduce(0) { ($0 + Int($1)) & 0xFFFF }) + word(Int(DMS.crc16(track.packed)))
        record += word(Int(DMS.crc16(record)))
        data += record + track.packed
    }
    return data
}

@Test func dmsChecksumIsCRC16ARC() {
    #expect(DMS.crc16(Array("123456789".utf8)) == 0xBB3D)
}

@Test func dmsStoredAndRunLengthCylindersLandAtTheirPlace() throws {
    let cylinder = FloppyDrive.trackSize * 2
    let stored = (0..<cylinder).map { UInt8(truncatingIfNeeded: $0 * 7) }
    // $90 n c repeats c n times, $90 $FF c hi lo a 16-bit count, $90 0 is a literal $90.
    let runs: [UInt8] = [0x41, 0x90, 0x00, 0x90, 0x03, 0x42, 0x90, 0xFF, 0x43] + [UInt8((cylinder - 5) >> 8), UInt8((cylinder - 5) & 0xFF)]
    let expanded = [0x41, 0x90, 0x42, 0x42, 0x42] + [UInt8](repeating: 0x43, count: cylinder - 5)
    let banner = (number: 0xFFFF, mode: UInt8(0), flags: UInt8(0), packed: [UInt8](repeating: 1, count: 100), unpacked: [UInt8](repeating: 1, count: 100))
    let adf = try DMS.unpack(archive([banner, (0, 0, 0, stored, stored), (5, 1, 0, runs, expanded)]))
    #expect(adf.count == FloppyDrive.adfSize)
    #expect(Array(adf[0..<cylinder]) == stored)
    #expect(Array(adf[5 * cylinder..<6 * cylinder]) == expanded)
    #expect(adf[cylinder..<5 * cylinder].allSatisfy { $0 == 0 })  // cylinders not in the archive
}

@Test func dmsDiskImagesGoIntoTheDrive() throws {
    let cylinder = FloppyDrive.trackSize * 2
    var first = [UInt8](repeating: 0, count: cylinder)
    first[0...3] = [0x44, 0x4F, 0x53, 0x00]
    var drive = FloppyDrive()
    try drive.insert(adf: archive([(0, 0, 0, first, first)]))
    #expect(drive.disk?.prefix(4) == [0x44, 0x4F, 0x53, 0x00])
}

@Test func dmsDamageIsReported() {
    let cylinder = [UInt8](repeating: 5, count: FloppyDrive.trackSize * 2)
    var damaged = archive([(0, 0, 0, cylinder, cylinder)])
    damaged[damaged.count - 1] ^= 0xFF                        // packed data no longer matches its CRC
    #expect(throws: DMSError.corruptTrack(0)) { try DMS.unpack(damaged) }
    var wrongHeader = archive([(0, 0, 0, cylinder, cylinder)])
    wrongHeader[30] ^= 1
    #expect(throws: DMSError.notDMS) { try DMS.unpack(wrongHeader) }
    var encrypted = archive([(0, 0, 0, cylinder, cylinder)])
    encrypted[11] = 2
    let crc = DMS.crc16(encrypted[4..<54])
    encrypted[54] = UInt8(crc >> 8); encrypted[55] = UInt8(crc & 0xFF)
    #expect(throws: DMSError.unsupported("encrypted archive")) { try DMS.unpack(encrypted) }
}
