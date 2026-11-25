import Testing
@testable import MacMigaCore

@Test func emptyInternalDriveAnswersThroughTheCIAs() throws {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024), slowRAMSize: 0)
    func status(_ memory: inout AmigaMemory) throws -> UInt8 { try memory.readByte(at: 0xBFE001) & 0x3C }
    func port(_ value: UInt8, _ memory: inout AmigaMemory) throws { try memory.writeByte(value, at: 0xBFD100) }
    #expect(try status(&memory) == 0x3C)               // nothing selected
    try port(0xFF, &memory)                             // idle levels before driving outputs
    try memory.writeByte(0xFF, at: 0xBFD300)            // CIA-B DDRB: all outputs
    try port(0x77, &memory)                             // select DF0 with /MTR low: motor on
    #expect(memory.drive.motorOn)
    #expect(try status(&memory) == 0x08)                // /RDY, /TK0, /CHNG low; /WPRO high
    for _ in 0..<3 { try port(0x74, &memory); try port(0x75, &memory) } // DIR inwards, 3 steps
    #expect(memory.drive.cylinder == 3)
    #expect(try status(&memory) == 0x18)                // off cylinder 0
    for _ in 0..<5 { try port(0x76, &memory); try port(0x77, &memory) } // outwards, stops at 0
    #expect(memory.drive.cylinder == 0)
    try port(0xFF, &memory)                             // deselect: motor state latched
    #expect(memory.drive.motorOn)
    #expect(try status(&memory) == 0x3C)
    try port(0xF7, &memory)                             // reselect with /MTR high: motor off
    #expect(!memory.drive.motorOn)
    try port(0x7F, &memory)
    try port(0x75, &memory)                             // stepping a deselected drive does nothing
    #expect(memory.drive.cylinder == 0)
}
