import Testing
@testable import MacMigaCore

private func audioMemory() throws -> AmigaMemory {
    var memory = try AmigaMemory(kickstart: [UInt8](repeating: 0, count: 256 * 1024), slowRAMSize: 0)
    memory.setOverlay(enabled: false)
    // Two words of samples: $40, $C0, $20, $E0 (64, -64, 32, -32).
    try memory.writeWord(0x40C0, at: 0x4000)
    try memory.writeWord(0x20E0, at: 0x4002)
    try memory.writeLong(0x4000, at: 0xDFF0A0) // AUD0LC
    try memory.writeWord(2, at: 0xDFF0A4)      // AUD0LEN
    try memory.writeWord(200, at: 0xDFF0A6)    // AUD0PER
    try memory.writeWord(64, at: 0xDFF0A8)     // AUD0VOL
    return memory
}

@Test func audioDMAPlaysBytesAtThePeriodAndInterruptsPerBlock() throws {
    var memory = try audioMemory()
    try memory.writeWord(0x8201, at: 0xDFF096) // DMAEN | AUD0EN
    memory.advanceChipset(colorClocks: 1)
    #expect(memory.custom.intreq & 0x0080 != 0) // block start interrupt
    #expect(memory.audio.channels[0].sample == 64)
    try memory.writeWord(0x0080, at: 0xDFF09C)
    memory.advanceChipset(colorClocks: 200)
    #expect(memory.audio.channels[0].sample == -64)
    memory.advanceChipset(colorClocks: 200)
    #expect(memory.audio.channels[0].sample == 32)
    #expect(memory.custom.intreq & 0x0080 != 0) // block restarted after the last word fetch
    memory.advanceChipset(colorClocks: 400)
    #expect(memory.audio.channels[0].sample == 64) // looped back to AUD0LC
    try memory.writeWord(0x0001, at: 0xDFF096) // AUD0EN off
    memory.advanceChipset(colorClocks: 1)
    #expect(memory.audio.channels[0].sample == 0)
    #expect(!memory.audio.channels[0].dma)
}

@Test func audioMixesChannelZeroLeftAtTheHostRate() throws {
    var memory = try audioMemory()
    try memory.writeWord(0x0040, at: 0xDFF0A4)  // longer block of zeros after the first two words
    try memory.writeWord(0x8201, at: 0xDFF096)
    memory.advanceChipset(colorClocks: 100)       // first sample (64 * 64) for the whole span
    let samples = memory.audio.drainSamples()
    #expect(samples.count == 2)                   // 100 colour clocks ≈ 1.24 host frames at 44.1 kHz
    #expect(abs(samples[0] - 0.25) < 0.001)       // 64 * 64 / 16384, left
    #expect(samples[1] == 0)                      // right silent
    memory.advanceChipset(colorClocks: Paula.colorClockRate / 50)
    #expect(memory.audio.drainSamples().count == 2 * 882) // one PAL frame of 44.1 kHz stereo
}

@Test func cpuWrittenAudioDataPlaysTwoBytesThenInterrupts() throws {
    var memory = try audioMemory()
    try memory.writeWord(0x7F81, at: 0xDFF0AA) // AUD0DAT, no DMA
    memory.advanceChipset(colorClocks: 1)
    #expect(memory.audio.channels[0].sample == 127)
    #expect(memory.custom.intreq & 0x0080 == 0)
    memory.advanceChipset(colorClocks: 200)
    #expect(memory.audio.channels[0].sample == -127)
    #expect(memory.custom.intreq & 0x0080 != 0)
}
