/// Paula audio: four 8-bit channels mixed to a stereo host stream.
///
/// Registers per channel n at `$DFF0A0 + n*$10`: AUDnLC (location), AUDnLEN (words, 0 = 65536),
/// AUDnPER (colour clocks per sample), AUDnVOL (0–64), AUDnDAT. With DMACON DMAEN and AUDnEN
/// set, a channel loads LC/LEN, raises its interrupt (INTREQ bit 7+n) so the next block can be
/// queued, and plays the block's bytes high byte first, one per period; after the last word it
/// reloads LC/LEN and interrupts again. Without DMA, a CPU write to AUDnDAT plays that word's two
/// bytes and then interrupts. Channels 0 and 3 go left, 1 and 2 right. Not modelled: ADKCON
/// volume/period modulation, the audio low-pass filter (CIA-A PA1), and DMA slot timing.
public struct Paula: Equatable, Sendable {
    public struct Channel: Equatable, Sendable {
        /// DMA playback running.
        public internal(set) var dma = false
        /// Holds a word being played (DMA or a CPU write to AUDnDAT).
        var playing = false
        var pointer: UInt32 = 0
        var remaining = 0
        var word: UInt16 = 0
        var byteIndex = 0
        var countdown = 0
        /// Current signed 8-bit sample on the channel's output.
        public internal(set) var sample: Int8 = 0
    }

    /// PAL colour clock rate, the rate the period counters count at.
    public static let colorClockRate = 3_546_895
    /// NTSC colour clock rate.
    public static let ntscColorClockRate = 3_579_545
    public internal(set) var channels = [Channel](repeating: Channel(), count: 4)
    /// Host output rate in Hz.
    public var sampleRate = 44_100
    /// Interleaved stereo samples (left, right) in -1…1 waiting for the host.
    public internal(set) var samples: [Float] = []
    /// Cap on buffered stereo frames when the host is not draining (one second).
    var capacity: Int { sampleRate }
    var phase = 0
    var sumLeft = 0, sumRight = 0, sumCount = 0
    /// Mixed levels from the last step, reused while every channel is idle.
    var left = 0, right = 0
    var anyPlaying = false

    public init() {}

    /// Removes and returns the buffered interleaved stereo samples.
    public mutating func drainSamples() -> [Float] {
        defer { samples.removeAll(keepingCapacity: true) }
        return samples
    }
}

extension AmigaMemory {
    /// Advances all four channels by `colorClocks` and feeds the box-filtered mix into the
    /// host sample stream. The clocks up to the next change of a channel's output are taken
    /// in one step; the result is the same as stepping one colour clock at a time.
    mutating func stepAudio(colorClocks: Int) {
        var remaining = colorClocks
        while remaining > 0 {
            let dmaMaster = custom.dmacon & 0x0200 != 0
            var count = remaining
            if audio.anyPlaying || (dmaMaster && custom.dmacon & 0x000F != 0) || custom.audioDataWritten != 0 {
                stepChannels(dmaMaster: dmaMaster)
                // Nothing changes until a playing channel's period counter runs out.
                for index in 0..<4 where audio.channels[index].playing {
                    count = min(count, audio.channels[index].countdown)
                }
                for index in 0..<4 where audio.channels[index].playing {
                    audio.channels[index].countdown -= count - 1
                }
            } else {
                mixVolumes()
            }
            finishAudioStep(colorClocks: count)
            remaining -= count
        }
    }

    private mutating func stepChannels(dmaMaster: Bool) {
        var playing = false
        for index in 0..<4 {
            let base = 0x0A0 + index * 0x10
            let enabled = dmaMaster && custom.dmacon & (1 << index) != 0
            var channel = audio.channels[index]
            if enabled && !channel.dma {
                channel.dma = true
                channel.pointer = audioLocation(base)
                channel.remaining = audioLength(base)
                custom.requestInterrupt(bits: 0x0080 << index)
                fetchAudioWord(&channel, base: base, index: index)
                channel.playing = true
                channel.byteIndex = 0
                channel.countdown = 0
            } else if !enabled && channel.dma {
                channel.dma = false
                channel.playing = false
                channel.sample = 0
            }
            if custom.audioDataWritten & (1 << index) != 0 {
                custom.audioDataWritten &= ~(1 << index)
                if !channel.dma {
                    channel.word = custom.register(base + 0xA)
                    channel.playing = true
                    channel.byteIndex = 0
                    channel.countdown = 0
                }
            }
            if channel.playing {
                channel.countdown -= 1
                if channel.countdown <= 0 {
                    channel.countdown = max(Int(custom.register(base + 6)), 1)
                    channel.sample = Int8(bitPattern: UInt8(truncatingIfNeeded: channel.byteIndex == 0
                                                             ? channel.word >> 8 : channel.word))
                    channel.byteIndex += 1
                    if channel.byteIndex == 2 {
                        channel.byteIndex = 0
                        if channel.dma {
                            fetchAudioWord(&channel, base: base, index: index)
                        } else {
                            channel.playing = false // keeps outputting the last byte until rewritten
                            custom.requestInterrupt(bits: 0x0080 << index)
                        }
                    }
                }
            }
            audio.channels[index] = channel
            if channel.dma || channel.playing { playing = true }
        }
        audio.anyPlaying = playing
        mixVolumes()
    }

    /// Recomputes the left (channels 0, 3) and right (1, 2) levels from samples and volumes.
    private mutating func mixVolumes() {
        var left = 0, right = 0
        for index in 0..<4 where audio.channels[index].sample != 0 {
            let volume = min(Int(custom.register(0x0A8 + index * 0x10) & 0x7F), 64)
            let level = Int(audio.channels[index].sample) * volume
            if index == 0 || index == 3 { left += level } else { right += level }
        }
        audio.left = left
        audio.right = right
    }

    /// Box-filters `colorClocks` of the current mix down to the host rate.
    private mutating func finishAudioStep(colorClocks: Int) {
        var remaining = colorClocks
        let clockRate = custom.ntsc ? Paula.ntscColorClockRate : Paula.colorClockRate
        while remaining > 0 {
            // Colour clocks until the next host sample is due.
            let untilSample = (clockRate - audio.phase + audio.sampleRate - 1) / audio.sampleRate
            let count = min(remaining, max(untilSample, 1))
            remaining -= count
            audio.sumLeft += audio.left * count
            audio.sumRight += audio.right * count
            audio.sumCount += count
            audio.phase += audio.sampleRate * count
            if audio.phase >= clockRate {
                audio.phase -= clockRate
                if audio.samples.count < audio.capacity * 2 {
                    let scale = Float(audio.sumCount) * 16384
                    audio.samples.append(Float(audio.sumLeft) / scale)
                    audio.samples.append(Float(audio.sumRight) / scale)
                }
                audio.sumLeft = 0
                audio.sumRight = 0
                audio.sumCount = 0
            }
        }
    }

    private func audioLocation(_ base: Int) -> UInt32 {
        (UInt32(custom.register(base) & 0x1F) << 16 | UInt32(custom.register(base + 2))) & 0x1F_FFFE
    }

    private func audioLength(_ base: Int) -> Int {
        let length = Int(custom.register(base + 4))
        return length == 0 ? 0x10000 : length
    }

    /// Fetches the next DMA word; after a block's last word, restarts from AUDnLC/AUDnLEN
    /// and raises the channel interrupt.
    private mutating func fetchAudioWord(_ channel: inout Paula.Channel, base: Int, index: Int) {
        channel.word = chipWord(at: channel.pointer)
        channel.pointer = (channel.pointer &+ 2) & 0x1F_FFFE
        channel.remaining -= 1
        if channel.remaining <= 0 {
            channel.pointer = audioLocation(base)
            channel.remaining = audioLength(base)
            custom.requestInterrupt(bits: 0x0080 << index)
        }
    }
}
