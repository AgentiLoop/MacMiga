import AppKit
import AVFoundation
import GameController
import MetalKit
import MacMigaCore
import UniformTypeIdentifiers

/// MacMiga app: one window showing the emulated PAL display, driven at 50 frames per second
/// on the main thread. Keyboard, mouse (captured by a click, released with ⌘) and joystick
/// (numeric keypad, right Option, optionally the arrow keys, or a game controller) go to the Amiga.
@MainActor
final class Emulator {
    private(set) var machine: AmigaMachine?
    private(set) var romURL: URL?
    /// The second ROM, at `$E00000`; AROS's own ROM comes as two files. Nil for a Kickstart.
    private(set) var extendedROMURL: URL?
    private(set) var diskURL: URL?
    private var disk: [UInt8]?
    /// Hard disk image on the controller board (DH0); changed blocks are saved back to its file.
    private(set) var hardDisk: HardDisk?
    private(set) var hardDiskURL: URL?
    /// Sizes of Zorro II fast RAM the Machine menu offers, in MiB; 0 is none.
    static let fastRAMSizes = [0, 1, 2, 4, 8]
    /// MiB of Zorro II fast RAM; none by default (the stock machine is 512 KiB chip + 512 KiB slow).
    private(set) var fastRAM = Emulator.fastRAMSetting(UserDefaults.standard.object(forKey: "FastRAM"))

    /// The `FastRAM` default as MiB. It was a switch for 8 MiB before it was a size, so a
    /// Boolean (as stored by older versions, or `-FastRAM YES` on the command line) means 8.
    /// Anything that is not one of `fastRAMSizes` means none.
    static func fastRAMSetting(_ value: Any?) -> Int {
        var size = 0
        if let number = value as? NSNumber {
            size = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? 8 : 0) : number.intValue
        } else if let text = value as? String {
            size = Int(text) ?? (["yes", "true", "y"].contains(text.lowercased()) ? 8 : 0)
        }
        return fastRAMSizes.contains(size) ? size : 0
    }
    /// 1 MiB of chip RAM with the ECS Agnus instead of 512 KiB with the OCS one; off by default.
    private(set) var bigChipRAM = UserDefaults.standard.bool(forKey: "ChipRAM1MB")
    var onError: ((String) -> Void)?
    let audio = AudioOutput()

    func load(rom url: URL, extended: URL?) throws {
        let extendedROM = try extended.map { Array(try Data(contentsOf: $0)) } ?? []
        var machine = try AmigaMachine(kickstart: Array(try Data(contentsOf: url)), extendedROM: extendedROM,
                                       chipRAMSize: bigChipRAM ? 1 << 20 : 512 << 10,
                                       fastRAMSize: fastRAM << 20, hardDisk: hardDisk)
        if let audio { machine.memory.audio.sampleRate = audio.sampleRate }
        self.machine = machine
        romURL = url
        extendedROMURL = extended
        UserDefaults.standard.set(url.path, forKey: "kickstartPath")
        UserDefaults.standard.set(extended?.path, forKey: "extendedROMPath")
        if let disk { try self.machine?.memory.insertDisk(adf: disk) }
    }

    func reset() throws {
        if let romURL { try load(rom: romURL, extended: extendedROMURL) }
    }

    func insert(adf url: URL) throws {
        let bytes = Array(try Data(contentsOf: url))
        try machine?.memory.insertDisk(adf: bytes)
        disk = bytes
        diskURL = url
    }

    func eject() {
        try? machine?.memory.insertDisk(adf: nil)
        disk = nil
        diskURL = nil
    }

    /// Attaches a hardfile as DH0 (nil detaches) and restarts the machine, since Kickstart
    /// only looks for expansion boards while it starts. A file that cannot be written is
    /// attached write-protected.
    func attach(hardDisk url: URL?) throws {
        saveHardDisk()
        if let url {
            let writable = FileManager.default.isWritableFile(atPath: url.path)
            // Mapped, so that a large image is only held once in memory, as the array.
            hardDisk = try HardDisk(image: Array(try Data(contentsOf: url, options: .alwaysMapped)), writeProtected: !writable)
        } else {
            hardDisk = nil
        }
        hardDiskURL = url
        try reset()
    }

    func setFastRAM(megabytes: Int) throws {
        guard Self.fastRAMSizes.contains(megabytes) else { return }
        fastRAM = megabytes
        UserDefaults.standard.set(megabytes, forKey: "FastRAM")
        try reset()
    }

    func setBigChipRAM(_ enabled: Bool) throws {
        bigChipRAM = enabled
        UserDefaults.standard.set(enabled, forKey: "ChipRAM1MB")
        try reset()
    }

    /// Writes the blocks the Amiga changed since the last call back into the image file.
    func saveHardDisk() {
        guard let hardDisk, let hardDiskURL else { return }
        let blocks = hardDisk.takeModifiedBlocks()
        guard !blocks.isEmpty else { return }
        do {
            let handle = try FileHandle(forWritingTo: hardDiskURL)
            defer { try? handle.close() }
            for block in blocks {
                let start = block * HardDisk.blockSize
                try handle.seek(toOffset: UInt64(start))
                try handle.write(contentsOf: Data(hardDisk.bytes[start..<start + HardDisk.blockSize]))
            }
        } catch {
            onError?("Could not save \(hardDiskURL.lastPathComponent): \(error)")
        }
    }

    /// Warp speed: emulate as fast as the Mac allows instead of 50 frames a second, without
    /// sound. Not remembered between launches; `-Warp YES` on the command line starts with it on.
    var warp = UserDefaults.standard.bool(forKey: "Warp")

    /// Instant Load: run at warp speed while the floppy is busy (motor on and the drive used
    /// within the last emulated second), then return to normal speed. Remembered; on by default.
    var instantLoad = UserDefaults.standard.object(forKey: "InstantLoad") as? Bool ?? true {
        didSet { UserDefaults.standard.set(instantLoad, forKey: "InstantLoad") }
    }
    private var diskActivity = 0, diskActivityFrame = 0

    /// True while Instant Load should run the machine at warp speed.
    func diskBusy() -> Bool {
        guard instantLoad, let memory = machine?.memory else { return false }
        if memory.drive.activity != diskActivity {
            diskActivity = memory.drive.activity
            diskActivityFrame = memory.video.frameCount
        }
        // The frame count restarts with a new machine, so a negative age counts as idle.
        let age = memory.video.frameCount - diskActivityFrame
        return memory.drive.motorOn && age >= 0 && age < 50
    }

    /// Runs until the chipset completes one more frame (bounded so a bug cannot hang the UI).
    /// With `playAudio` false the frame's sound is discarded.
    func runFrame(playAudio: Bool = true) {
        guard var machine else { return }
        // The local copy is the only owner while it runs; otherwise the first write of the
        // frame would copy chip RAM, slow RAM and the frame buffer.
        self.machine = nil
        let start = machine.memory.video.frameCount
        do {
            var steps = 0
            while machine.memory.video.frameCount == start && steps < 400_000 {
                try machine.step()
                steps += 1
            }
            let samples = machine.memory.audio.drainSamples()
            if playAudio { audio?.queue.push(samples) }
            self.machine = machine
            if machine.memory.video.frameCount % 50 == 0 { saveHardDisk() }
        } catch {
            onError?(String(format: "Emulation stopped at PC=$%08X: %@", machine.cpu.programCounter, "\(error)"))
        }
    }

    func key(_ code: UInt8, pressed: Bool) { machine?.key(code, pressed: pressed) }

    func mouse(dx: Int, dy: Int, left: Bool, right: Bool) {
        machine?.mouse(dx: dx, dy: dy, left: left, right: right)
    }

    func joystick(_ state: Joystick, fire: Bool) { machine?.joystick(state, fire: fire) }
}

/// Thread-safe FIFO of interleaved stereo samples between the emulator (main thread) and
/// the Core Audio render thread. Keeps at most ~100 ms queued so latency stays low.
final class AudioQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var readIndex = 0
    let maximum: Int

    init(sampleRate: Int) { maximum = sampleRate / 10 * 2 }

    func push(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(contentsOf: samples)
        let queued = buffer.count - readIndex
        if queued > maximum { readIndex += (queued - maximum) & ~1 }
        if readIndex > 65_536 { buffer.removeFirst(readIndex); readIndex = 0 }
    }

    /// Fills `frames` stereo frames, padding with silence when the emulator falls behind.
    func pull(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        for frame in 0..<frames {
            if readIndex + 1 < buffer.count {
                left[frame] = buffer[readIndex]
                right[frame] = buffer[readIndex + 1]
                readIndex += 2
            } else {
                left[frame] = 0
                right[frame] = 0
            }
        }
    }
}

/// Plays the Paula output through AVAudioEngine.
final class AudioOutput {
    let engine = AVAudioEngine()
    let queue: AudioQueue
    let sampleRate: Int

    init?() {
        sampleRate = Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)
        guard sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2) else { return nil }
        let queue = AudioQueue(sampleRate: sampleRate)
        self.queue = queue
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            queue.pull(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return nil }
    }
}

/// Mac virtual key code → Amiga raw key code (US layout positions).
let amigaKeys: [UInt16: UInt8] = [
    50: 0x00, 18: 0x01, 19: 0x02, 20: 0x03, 21: 0x04, 23: 0x05, 22: 0x06, 26: 0x07, 28: 0x08,
    25: 0x09, 29: 0x0A, 27: 0x0B, 24: 0x0C, 42: 0x0D,
    12: 0x10, 13: 0x11, 14: 0x12, 15: 0x13, 17: 0x14, 16: 0x15, 32: 0x16, 34: 0x17, 31: 0x18,
    35: 0x19, 33: 0x1A, 30: 0x1B,
    0: 0x20, 1: 0x21, 2: 0x22, 3: 0x23, 5: 0x24, 4: 0x25, 38: 0x26, 40: 0x27, 37: 0x28,
    41: 0x29, 39: 0x2A,
    6: 0x31, 7: 0x32, 8: 0x33, 9: 0x34, 11: 0x35, 45: 0x36, 46: 0x37, 43: 0x38, 47: 0x39, 44: 0x3A,
    49: 0x40, 51: 0x41, 48: 0x42, 36: 0x44, 76: 0x43, 53: 0x45, 117: 0x46,
    126: 0x4C, 125: 0x4D, 124: 0x4E, 123: 0x4F,
    122: 0x50, 120: 0x51, 99: 0x52, 118: 0x53, 96: 0x54, 97: 0x55, 98: 0x56, 100: 0x57,
    101: 0x58, 109: 0x59, 114: 0x5F,
    56: 0x60, 60: 0x61, 57: 0x62, 59: 0x63, 58: 0x64, 61: 0x65, 55: 0x66, 54: 0x67,
]

final class DisplayView: MTKView, MTKViewDelegate {
    var emulator: Emulator?
    /// Pixels of the frame on screen, kept to tell whether the next frame differs.
    private var shownPixels = Data()
    /// Set when the picture must be drawn again although no new frame arrived (resize, crop).
    private var needsRedraw = true

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// Three textures in rotation: a new frame is always copied into one the GPU isn't reading.
    private var textures: [MTLTexture?] = [nil, nil, nil]
    private var current = 0
    /// Command buffers in flight, at most one fewer than the textures.
    private let inFlight = DispatchSemaphore(value: 2)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 t = float2(vid & 1, vid >> 1);
        VOut o;
        o.pos = float4(t.x * 2 - 1, 1 - t.y * 2, 0, 1);
        o.uv = rect.xy + t * rect.zw;
        return o;
    }
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        return float4(tex.sample(s, in.uv).rgb, 1);
    }
    """

    override init(frame: NSRect, device: MTLDevice?) {
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { fatalError("Metal is not available") }
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: DisplayView.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vmain")
            desc.fragmentFunction = library.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Metal pipeline: \(error)")
        }
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        framebufferOnly = true
        // Driven by the display's refresh: each refresh calls onRefresh (which runs the emulation)
        // and then presents the newest frame, so pictures change only on vsync. A refresh without
        // a new frame draws nothing.
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 120
        delegate = self
    }

    convenience init(frame: NSRect) { self.init(frame: frame, device: nil) }

    required init(coder: NSCoder) { fatalError() }

    private var left = false, right = false
    private var modifiersDown = Set<UInt16>()

    // MARK: Joystick (port 2)

    /// Numeric keypad 8/2/4/6 (7/9/1/3 diagonals) steer and 0/5/Enter fire; right Option also
    /// fires. With `cursorKeysAsJoystick` the arrow keys steer instead of typing cursor keys.
    var cursorKeysAsJoystick = UserDefaults.standard.bool(forKey: "CursorKeysJoystick")
    private var keyBits: UInt8 = 0          // 0 up, 1 down, 2 left, 3 right, 4 fire
    private var rightOptionFire = false
    static let joystickKeys: [UInt16: UInt8] = [91: 0x01, 84: 0x02, 86: 0x04, 88: 0x08, 82: 0x10, 87: 0x10,
                                               76: 0x10, 89: 0x05, 92: 0x09, 83: 0x06, 85: 0x0A]
    static let cursorJoystick: [UInt16: UInt8] = [126: 0x01, 125: 0x02, 123: 0x04, 124: 0x08]

    /// Combines keyboard and game-controller state and sends it to the joystick in port 2.
    func updateJoystick() {
        var bits = keyBits | (rightOptionFire ? 0x10 : 0)
        for pad in GCController.controllers() {
            if let gp = pad.extendedGamepad {
                if gp.dpad.up.isPressed || gp.leftThumbstick.yAxis.value > 0.5 { bits |= 0x01 }
                if gp.dpad.down.isPressed || gp.leftThumbstick.yAxis.value < -0.5 { bits |= 0x02 }
                if gp.dpad.left.isPressed || gp.leftThumbstick.xAxis.value < -0.5 { bits |= 0x04 }
                if gp.dpad.right.isPressed || gp.leftThumbstick.xAxis.value > 0.5 { bits |= 0x08 }
                if gp.buttonA.isPressed || gp.buttonB.isPressed || gp.rightTrigger.isPressed { bits |= 0x10 }
            } else if let mg = pad.microGamepad {
                if mg.dpad.up.isPressed { bits |= 0x01 }
                if mg.dpad.down.isPressed { bits |= 0x02 }
                if mg.dpad.left.isPressed { bits |= 0x04 }
                if mg.dpad.right.isPressed { bits |= 0x08 }
                if mg.buttonA.isPressed || mg.buttonX.isPressed { bits |= 0x10 }
            }
        }
        var state = Joystick()
        state.up = bits & 0x01 != 0; state.down = bits & 0x02 != 0
        state.left = bits & 0x04 != 0; state.right = bits & 0x08 != 0
        emulator?.joystick(state, fire: bits & 0x10 != 0)
    }

    /// Releases every joystick input (used when the window loses focus).
    func releaseJoystick() { keyBits = 0; rightOptionFire = false; updateJoystick() }

    private func joystickBits(for keyCode: UInt16) -> UInt8? {
        if let bits = DisplayView.joystickKeys[keyCode] { return bits }
        return cursorKeysAsJoystick ? DisplayView.cursorJoystick[keyCode] : nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    // The frame is a Metal texture drawn as a textured quad with nearest-neighbour sampling.

    /// The whole frame is every beam line (0–311, vertical blank included) and lowres
    /// positions $58–$1C8. The standard display window ($2C81–$2CC1, 320×256) is not in its
    /// middle, so the borders are uneven. The cropped area runs from lowres $7A to $1C8 (the
    /// frame's right edge, where the beam ends) and fits the lines the game shows bitplanes on
    /// (lines 44–299 for the standard window), with a few lines of border above and below.
    static let fullArea = CGRect(x: 0, y: 0, width: Video.width, height: Video.height)
    static let standardLines = 44...299
    static func croppedArea(lines: ClosedRange<Int>) -> CGRect {
        let top = max(lines.lowerBound - 8, 0), bottom = min(lines.upperBound + 1 + 8, Video.height)
        return CGRect(x: (0x7A - Video.firstLowresColumn) * 2, y: top,
                      width: Video.width - (0x7A - Video.firstLowresColumn) * 2, height: bottom - top)
    }
    /// Part of the frame shown, in frame pixels (hires columns × beam lines).
    var visibleArea = DisplayView.fullArea {
        didSet { needsRedraw = true; needsDisplay = true }
    }

    /// A frame received but not yet copied into a texture.
    private var pendingUpload = false

    /// Shows the frame unless it is the one already on screen, which costs no redraw at all.
    func show(_ video: Video) {
        let unchanged = video.pixels.withUnsafeBytes { new in
            shownPixels.withUnsafeBytes { old in
                old.count == new.count && memcmp(old.baseAddress, new.baseAddress, new.count) == 0
            }
        }
        guard !unchanged else { return }
        shownPixels = video.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        pendingUpload = true
        needsDisplay = true
    }

    /// Called at every display refresh, before the newest frame is presented.
    var onRefresh: (() -> Void)?

    func draw(in view: MTKView) {
        onRefresh?()
        // Both earlier pictures still on the GPU: try again at the next refresh instead of blocking.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        if pendingUpload, let device, shownPixels.count >= Video.width * Video.height * 4 {
            pendingUpload = false
            let next = (current + 1) % textures.count
            if textures[next] == nil {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                    width: Video.width, height: Video.height,
                                                                    mipmapped: false)
                desc.usage = .shaderRead
                textures[next] = device.makeTexture(descriptor: desc)
            }
            shownPixels.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                textures[next]?.replace(region: MTLRegionMake2D(0, 0, Video.width, Video.height), mipmapLevel: 0,
                                        withBytes: base, bytesPerRow: Video.width * 4)
            }
            current = next
            needsRedraw = true
        }
        // Nothing new: leave the last presented picture on screen instead of drawing it again.
        guard needsRedraw else { return }
        needsRedraw = false
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture = textures[current] {
            let r = visibleArea
            var rect = SIMD4<Float>(Float(r.minX) / Float(texture.width), Float(r.minY) / Float(texture.height),
                                    Float(r.width) / Float(texture.width), Float(r.height) / Float(texture.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        let done = inFlight
        buffer.addCompletedHandler { _ in done.signal() }
        buffer.commit()
        committed = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsRedraw = true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if let bits = joystickBits(for: event.keyCode) { keyBits |= bits; updateJoystick(); return }
        guard !event.isARepeat, let code = amigaKeys[event.keyCode] else { return }
        emulator?.key(code, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        if let bits = joystickBits(for: event.keyCode) { keyBits &= ~bits; updateJoystick(); return }
        if let code = amigaKeys[event.keyCode] { emulator?.key(code, pressed: false) }
    }

    override func flagsChanged(with event: NSEvent) {
        if mouseCaptured && event.modifierFlags.contains(.command) { releaseMouse() } // ⌘ gives the pointer back
        if event.keyCode == 61 {                                   // right Option = joystick fire
            rightOptionFire = event.modifierFlags.rawValue & 0x40 != 0
            updateJoystick()
            return
        }
        guard let code = amigaKeys[event.keyCode] else { return }
        let pressed = !modifiersDown.contains(event.keyCode)
        if pressed { modifiersDown.insert(event.keyCode) } else { modifiersDown.remove(event.keyCode) }
        emulator?.key(code, pressed: pressed)
    }

    // MARK: Mouse (port 1)

    /// A click in the window captures the Mac pointer (hidden, detached from the screen) so
    /// the Amiga pointer is the only one and follows every movement; ⌘ releases it.
    private(set) var mouseCaptured = false
    private var remainder = (x: 0.0, y: 0.0)

    private func captureMouse() {
        guard !mouseCaptured, window != nil else { return }
        mouseCaptured = true
        remainder = (0, 0)
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        onMouseCaptureChange?()
    }

    func releaseMouse() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        left = false; right = false
        sendMouse(dx: 0, dy: 0)
        onMouseCaptureChange?()
    }

    var onMouseCaptureChange: (() -> Void)?

    private func sendMouse(dx: Int, dy: Int) {
        emulator?.mouse(dx: dx, dy: dy, left: left, right: right)
    }

    /// One mouse count moves the Amiga pointer one lowres pixel, which is two display pixels
    /// of the visible frame, so scale by the view size to keep pointer speed 1:1.
    private func moveMouse(_ event: NSEvent) {
        guard mouseCaptured else { return }
        remainder.x += Double(event.deltaX) * Double(visibleArea.width) / (2 * bounds.width)
        remainder.y += Double(event.deltaY) * Double(visibleArea.height) / bounds.height
        let dx = Int(remainder.x.rounded(.towardZero)), dy = Int(remainder.y.rounded(.towardZero))
        guard dx != 0 || dy != 0 else { return }
        remainder.x -= Double(dx); remainder.y -= Double(dy)
        sendMouse(dx: dx, dy: dy)
    }

    override func mouseMoved(with event: NSEvent) { moveMouse(event) }
    override func mouseDragged(with event: NSEvent) { moveMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { moveMouse(event) }
    override func mouseDown(with event: NSEvent) {
        if !mouseCaptured { captureMouse(); return }        // the capturing click is not an Amiga click
        left = true; sendMouse(dx: 0, dy: 0)
    }
    override func mouseUp(with event: NSEvent) { if mouseCaptured { left = false; sendMouse(dx: 0, dy: 0) } }
    override func rightMouseDown(with event: NSEvent) { if mouseCaptured { right = true; sendMouse(dx: 0, dy: 0) } }
    override func rightMouseUp(with event: NSEvent) { if mouseCaptured { right = false; sendMouse(dx: 0, dy: 0) } }

    // MARK: Drag and drop

    /// Floppy (.adf) and hard disk (.hdf) images dropped on the window go to DF0 and DH0; a Kickstart ROM
    /// (.rom or .bin) is opened as with Machine ▸ Kickstart ROM.
    static let droppableExtensions: Set<String> = ["adf", "dms", "hdf", "rom", "bin"]
    var onFileDrop: ((URL) -> Void)?

    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { DisplayView.droppableExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { droppedURL(sender) == nil ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(sender) else { return false }
        onFileDrop?(url)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let emulator = Emulator()
    var window: NSWindow!
    /// The Fast RAM submenu, whose check marks change when a WHDLoad disk turns fast RAM on.
    private var fastRAMMenu: NSMenu?
    let view = DisplayView(frame: NSRect(x: 0, y: 0, width: Video.width, height: Video.height * 2))

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        view.wantsLayer = true
        window.contentView = view
        window.contentAspectRatio = view.frame.size
        addDriveLights()
        if UserDefaults.standard.bool(forKey: "CropBorders") { showArea(cropped: true) }
        window.center()
        view.emulator = emulator
        emulator.onError = { [weak self] message in self?.alert(message) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        window.acceptsMouseMovedEvents = true
        NSApp.activate(ignoringOtherApps: true)
        view.onMouseCaptureChange = { [weak self] in self?.updateTitle() }
        view.registerForDraggedTypes([.fileURL])
        view.onFileDrop = { [weak self] url in
            switch url.pathExtension.lowercased() {
            case "hdf": self?.attach(hardDisk: url)
            case "rom", "bin": self?.open(rom: url, extended: nil)
            default: self?.insert(adf: url)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.view.releaseMouse(); self?.view.releaseJoystick() }
        }
        observeControllers()

        let arguments = Array(CommandLine.arguments.dropFirst())
        let isMedia = { (path: String) in path.lowercased().hasSuffix(".adf") || path.lowercased().hasSuffix(".hdf") }
        // ROM files come before any `-Option value` pairs: the Kickstart, then an extended ROM.
        let roms = arguments.prefix { !$0.hasPrefix("-") }.filter { !isMedia($0) }
        if let romPath = roms.first {
            open(rom: URL(fileURLWithPath: romPath), extended: roms.dropFirst().first.map { URL(fileURLWithPath: $0) })
        } else if let romPath = UserDefaults.standard.string(forKey: "kickstartPath")
                    ?? ["Kickstart ROMs/kickstart-1.3.rom"].first(where: { FileManager.default.fileExists(atPath: $0) }) {
            open(rom: URL(fileURLWithPath: romPath),
                 extended: UserDefaults.standard.string(forKey: "extendedROMPath").map { URL(fileURLWithPath: $0) })
        } else {
            chooseROM()
        }
        if let adf = arguments.first(where: { $0.lowercased().hasSuffix(".adf") }) {
            insert(adf: URL(fileURLWithPath: adf))
        }
        if let hdf = arguments.first(where: { $0.lowercased().hasSuffix(".hdf") }) {
            attach(hardDisk: URL(fileURLWithPath: hdf))
        }
        // Paced by the display's refresh rather than a timer, so frames reach the screen on vsync.
        view.onRefresh = { [weak self] in self?.refresh() }
    }

    /// When the next PAL frame (50 a second) is due, on the CACurrentMediaTime clock.
    private var nextFrameTime = 0.0

    /// Runs the PAL frames due by this display refresh. More than 0.1 s behind (or in warp,
    /// which paces itself) the clock restarts instead of catching up.
    private func refresh() {
        let now = CACurrentMediaTime()
        if emulator.warp || emulator.diskBusy() || now - nextFrameTime > 0.1 { nextFrameTime = now }
        while now >= nextFrameTime {
            nextFrameTime += 1.0 / 50.0
            tick()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { emulator.saveHardDisk() }

    /// Debug: with MACMIGA_DUMP=path every shown frame is appended to that file as raw 0xAARRGGBB pixels.
    private let frameDump: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["MACMIGA_DUMP"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    /// Debug: one line per shown frame in /tmp/macmiga-trace.log (bitplane pointers, scroll, copper list).
    private let traceLog: FileHandle? = {
        FileManager.default.createFile(atPath: "/tmp/macmiga-trace.log", contents: nil)
        return FileHandle(forWritingAtPath: "/tmp/macmiga-trace.log")
    }()

    private func tick() {
        if emulator.warp || emulator.diskBusy() {
            // As many frames as fit in 15 ms of each 20 ms tick, so the window stays responsive.
            let deadline = Date().addingTimeInterval(0.015)
            repeat { emulator.runFrame(playAudio: false) }
                while emulator.machine != nil && Date() < deadline && (emulator.warp || emulator.diskBusy())
        } else {
            emulator.runFrame()
        }
        if let video = emulator.machine?.memory.video {
            fitCrop(to: video.displayedLines)
            view.show(video)
            if let frameDump { frameDump.write(video.pixels.withUnsafeBufferPointer { Data(buffer: $0) }) }
            traceLog?.write(Data("\(video.frameCount) \(video.traceDisplayed)\n".utf8))
        }
        updateDriveLights()
    }

    /// Lines the cropped view fits, and a different range seen in recent frames with how many
    /// frames in a row it has been seen.
    private var croppedLines = DisplayView.standardLines
    private var candidateLines = DisplayView.standardLines, candidateFrames = 0

    /// With Crop Borders on, follows the lines the game shows bitplanes on once they have
    /// stayed the same for half a second (screens switching DMA mid-frame show partial ranges
    /// for a frame or two). Frames without bitplanes, or with fewer than 100 lines of them,
    /// keep the current crop.
    private func fitCrop(to lines: ClosedRange<Int>?) {
        guard UserDefaults.standard.bool(forKey: "CropBorders"), let lines, lines.count >= 100,
              lines != croppedLines else { candidateFrames = 0; return }
        if lines == candidateLines { candidateFrames += 1 } else { candidateLines = lines; candidateFrames = 1 }
        guard candidateFrames >= 25 else { return }
        croppedLines = lines
        showArea(cropped: true, keepingWidth: true)
    }

    /// Names the disks in the drives; the Kickstart ROM is checked in Machine ▸ Kickstart ROM.
    private func updateTitle() {
        var parts = ["DF0: " + (emulator.diskURL?.lastPathComponent ?? "empty")]
        if let hardDisk = emulator.hardDiskURL { parts.append("DH0: " + hardDisk.lastPathComponent) }
        if emulator.machine == nil { parts.append("No Kickstart") }
        if emulator.warp { parts.append("Warp") }
        if view.mouseCaptured { parts.append("⌘ releases the mouse") }
        window.title = parts.joined(separator: "   ")
    }

    // MARK: Drive lights

    /// Activity lights at the left of the title bar, as in the C64 emulator: DF0 (green while
    /// the floppy motor runs; the A500's drive light is wired to the motor) and DH0 (green while
    /// blocks are read, orange while they are written; shown only with a hard disk attached).
    /// The Kickstart ROM gets no light: it is read on every instruction, so it would always be lit.
    private let driveLights = (0..<2).map { NSView(frame: NSRect(x: 6 + $0 * 48, y: 8, width: 12, height: 12)) }
    private let driveLabels = ["DF0", "DH0"].enumerated().map { index, name -> NSTextField in
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 21 + index * 48, y: 7, width: 28, height: 14)
        return label
    }
    private var lastHardDiskCounts = (read: 0, written: 0), hardDiskLitFrames = 0, hardDiskWriting = false
    private var lastLights: [NSColor?] = [.clear, .clear] // neither colour nor hidden, so the first update sets both

    private func addDriveLights() {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 102, height: 28))
        for (light, label) in zip(driveLights, driveLabels) {
            light.wantsLayer = true
            light.layer?.cornerRadius = 6
            box.addSubview(light)
            box.addSubview(label)
        }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = box
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
        updateDriveLights()
    }

    private func updateDriveLights() {
        let drive = emulator.machine?.memory.drive
        let floppy: NSColor = drive?.motorOn == true ? .systemGreen : .systemGray
        var hard: NSColor?
        if let disk = emulator.hardDisk {
            let counts = (read: disk.blocksRead, written: disk.blocksWritten)
            if counts != lastHardDiskCounts {
                hardDiskWriting = counts.written != lastHardDiskCounts.written
                hardDiskLitFrames = 5 // 100 ms, so single block transfers are visible
                lastHardDiskCounts = counts
            } else if hardDiskLitFrames > 0 {
                hardDiskLitFrames -= 1
            }
            hard = hardDiskLitFrames == 0 ? .systemGray : hardDiskWriting ? .systemOrange : .systemGreen
        }
        let lights = [floppy, hard]
        let help = [drive?.motorOn == true ? "motor on" : "idle",
                    hardDiskLitFrames == 0 ? "idle" : hardDiskWriting ? "writing" : "reading"]
        for index in 0..<2 where lights[index] != lastLights[index] {
            lastLights[index] = lights[index]
            driveLights[index].isHidden = lights[index] == nil
            driveLabels[index].isHidden = lights[index] == nil
            driveLights[index].layer?.backgroundColor = lights[index]?.cgColor
            driveLights[index].toolTip = "\(driveLabels[index].stringValue): \(help[index])"
            driveLabels[index].toolTip = driveLights[index].toolTip
        }
    }

    /// Game controllers report changes on the main queue; connect/disconnect refreshes port 2.
    private func observeControllers() {
        let attach: @MainActor @Sendable (GCController) -> Void = { [weak self] pad in
            pad.handlerQueue = .main
            let changed = { MainActor.assumeIsolated { self?.view.updateJoystick() } }
            pad.extendedGamepad?.valueChangedHandler = { _, _ in changed() }
            pad.microGamepad?.valueChangedHandler = { _, _ in changed() }
        }
        GCController.controllers().forEach(attach)
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    GCController.controllers().forEach(attach)
                    self?.view.updateJoystick()
                }
            }
        }
    }

    @objc func toggleCursorJoystick(_ sender: NSMenuItem) {
        view.cursorKeysAsJoystick.toggle()
        view.releaseJoystick()
        UserDefaults.standard.set(view.cursorKeysAsJoystick, forKey: "CursorKeysJoystick")
        sender.state = view.cursorKeysAsJoystick ? .on : .off
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacMiga"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
        updateTitle()
    }

    private func open(rom url: URL, extended: URL?) {
        do { try emulator.load(rom: url, extended: extended) } catch {
            alert("Could not load \((extended ?? url).lastPathComponent): \(error)")
        }
        view.updateJoystick()
        updateTitle()
    }

    private func insert(adf url: URL) {
        do { try emulator.insert(adf: url) } catch { alert("Could not insert \(url.lastPathComponent): \(error)") }
        updateTitle()
    }

    private func attach(hardDisk url: URL?) {
        do { try emulator.attach(hardDisk: url) } catch {
            alert("Could not attach \(url?.lastPathComponent ?? "hard disk"): \(error)")
        }
        view.updateJoystick()
        updateTitle()
    }

    private func choose(_ extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A newly chosen Kickstart starts without an extended ROM.
    @objc func chooseROM() { if let url = choose(["rom", "bin"]) { open(rom: url, extended: nil) } }
    @objc func chooseExtendedROM() {
        guard let rom = emulator.romURL else { chooseROM(); return }
        if let url = choose(["rom", "bin"]) { open(rom: rom, extended: url) }
    }
    @objc func chooseADF() { if let url = choose(["adf", "dms"]) { insert(adf: url) } }
    @objc func ejectDisk() { emulator.eject(); updateTitle() }
    @objc func chooseHardDisk() { if let url = choose(["hdf"]) { attach(hardDisk: url) } }
    @objc func detachHardDisk() { attach(hardDisk: nil) }

    /// Builds a hardfile from a Mac folder or an LHA archive, saves it where the user chooses
    /// and attaches it, so that what the Amiga writes later is kept in that file. A WHDLoad
    /// install without WHDLoad gets WHDLoad's archive added if the user picks it, and the
    /// startup-sequence then starts the game through WHDLoad, which needs fast RAM.
    @objc func newHardDisk() {
        let open = NSOpenPanel()
        open.message = "Choose a folder or an LHA archive to make a hard disk from"
        open.canChooseDirectories = true
        open.allowedContentTypes = ["lha", "lzh"].compactMap { UTType(filenameExtension: $0) }
        guard open.runModal() == .OK, let source = open.url else { return }
        var sources = [source]
        let entries = (try? VolumeEntry.entries(of: source)) ?? []
        if VolumeEntry.whdloadSlaves(in: entries).count == 1, VolumeEntry.whdload(in: entries) == nil {
            let question = NSAlert()
            question.messageText = "\(source.lastPathComponent) is a WHDLoad install"
            question.informativeText = "Add WHDLoad to the disk to start it through WHDLoad (choose WHDLoad's archive or folder, "
                + "for example WHDLoad_usr.lha from whdload.de). WHDLoad needs Kickstart 2.0 or later and fast RAM."
            question.addButton(withTitle: "Add WHDLoad…")
            question.addButton(withTitle: "Without WHDLoad")
            question.addButton(withTitle: "Cancel")
            switch question.runModal() {
            case .alertFirstButtonReturn:
                let pick = NSOpenPanel()
                pick.message = "Choose WHDLoad's archive or folder"
                pick.canChooseDirectories = true
                pick.allowedContentTypes = ["lha", "lzh"].compactMap { UTType(filenameExtension: $0) }
                if let last = UserDefaults.standard.url(forKey: "WHDLoadArchive") { pick.directoryURL = last.deletingLastPathComponent() }
                guard pick.runModal() == .OK, let whdload = pick.url else { return }
                UserDefaults.standard.set(whdload, forKey: "WHDLoadArchive")
                sources.append(whdload)
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        let save = NSSavePanel()
        save.message = "Save the new hard disk image"
        save.allowedContentTypes = ["hdf"].compactMap { UTType(filenameExtension: $0) }
        save.directoryURL = source.deletingLastPathComponent()
        save.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + ".hdf"
        guard save.runModal() == .OK, let destination = save.url else { return }
        do {
            // Kickstart 1.x (before version 36) has no Fast File System in ROM.
            let version = emulator.romURL.flatMap { try? Data(contentsOf: $0) }.map { $0.count > 13 ? Int($0[12]) << 8 | Int($0[13]) : 0 }
            // With WHDLoad, the Kickstart images beside the loaded one go to Devs/Kickstarts
            // under the names WHDLoad's Kickstart emulation looks for.
            let folder = emulator.romURL?.deletingLastPathComponent()
            let files = folder.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
            let kickstarts = sources.count > 1
                ? files.compactMap { url in (try? Data(contentsOf: url)).flatMap { VolumeEntry.whdloadKickstart(Array($0), date: AmigaDate(days: 0)) } }
                : []
            try Data(try FastFileSystem.hardfile(from: sources, autoStart: true, fastFileSystem: (version ?? 40) >= 36,
                                                 kickstarts: kickstarts)).write(to: destination)
        } catch {
            alert("Could not make a hard disk from \(source.lastPathComponent): \(error)")
            return
        }
        // WHDLoad cannot start a game without fast RAM ("Can't allocate ExpMem").
        if sources.count > 1, emulator.fastRAM == 0 {
            try? emulator.setFastRAM(megabytes: 8)
            fastRAMMenu?.items.forEach { $0.state = $0.tag == emulator.fastRAM ? .on : .off }
        }
        attach(hardDisk: destination)
    }
    /// An item of the Fast RAM submenu; its tag is the size in MiB.
    @objc func chooseFastRAM(_ sender: NSMenuItem) {
        do { try emulator.setFastRAM(megabytes: sender.tag) } catch { alert("Reset failed: \(error)") }
        sender.menu?.items.forEach { $0.state = $0.tag == emulator.fastRAM ? .on : .off }
        view.updateJoystick()
    }
    @objc func toggleWarp(_ sender: NSMenuItem) {
        emulator.warp.toggle()
        sender.state = emulator.warp ? .on : .off
        updateTitle()
    }
    @objc func toggleInstantLoad(_ sender: NSMenuItem) {
        emulator.instantLoad.toggle()
        sender.state = emulator.instantLoad ? .on : .off
    }
    @objc func toggleBigChipRAM(_ sender: NSMenuItem) {
        do { try emulator.setBigChipRAM(!emulator.bigChipRAM) } catch { alert("Reset failed: \(error)") }
        sender.state = emulator.bigChipRAM ? .on : .off
        view.updateJoystick()
    }
    @objc func toggleCropBorders(_ sender: NSMenuItem) {
        let cropped = sender.state != .on
        UserDefaults.standard.set(cropped, forKey: "CropBorders")
        sender.state = cropped ? .on : .off
        showArea(cropped: cropped)
    }

    /// Shows the whole frame or the cropped area, keeping the window's height (or width) and
    /// its pixel aspect (each beam line two points high, each hires pixel one point wide).
    private func showArea(cropped: Bool, keepingWidth: Bool = false) {
        let area = cropped ? DisplayView.croppedArea(lines: croppedLines) : DisplayView.fullArea
        guard area != view.visibleArea else { return }
        view.visibleArea = area
        let aspect = NSSize(width: area.width, height: area.height * 2)
        let content = window.contentLayoutRect.size
        window.contentAspectRatio = aspect
        let size = keepingWidth ? NSSize(width: content.width, height: content.width * aspect.height / aspect.width)
                                : NSSize(width: content.height * aspect.width / aspect.height, height: content.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    @objc func resetMachine() {
        do { try emulator.reset() } catch { alert("Reset failed: \(error)") }
        view.updateJoystick()
        updateTitle()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit MacMiga", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let machineItem = NSMenuItem()
        let machine = NSMenu(title: "Machine")
        let kickstart = NSMenu(title: "Kickstart ROM")
        kickstart.delegate = self // refilled each time it opens
        menuNeedsUpdate(kickstart)
        machine.addItem(withTitle: "Kickstart ROM", action: nil, keyEquivalent: "").submenu = kickstart
        machine.addItem(withTitle: "Open Extended ROM ($E00000)…", action: #selector(chooseExtendedROM), keyEquivalent: "")
        machine.addItem(withTitle: "Insert Disk (DF0)…", action: #selector(chooseADF), keyEquivalent: "o")
        machine.addItem(withTitle: "Eject Disk", action: #selector(ejectDisk), keyEquivalent: "e")
        machine.addItem(.separator())
        machine.addItem(withTitle: "Attach Hard Disk (DH0)…", action: #selector(chooseHardDisk), keyEquivalent: "d")
        machine.addItem(withTitle: "New Hard Disk from Folder or LHA…", action: #selector(newHardDisk), keyEquivalent: "")
        machine.addItem(withTitle: "Detach Hard Disk", action: #selector(detachHardDisk), keyEquivalent: "")
        let fast = NSMenu(title: "Fast RAM")
        fastRAMMenu = fast
        for size in Emulator.fastRAMSizes {
            let item = fast.addItem(withTitle: size == 0 ? "None" : "\(size) MB", action: #selector(chooseFastRAM(_:)), keyEquivalent: "")
            item.tag = size
            item.state = size == emulator.fastRAM ? .on : .off
            item.target = self
        }
        machine.addItem(withTitle: "Fast RAM", action: nil, keyEquivalent: "").submenu = fast
        let chip = machine.addItem(withTitle: "1 MB Chip RAM (ECS Agnus)", action: #selector(toggleBigChipRAM(_:)),
                                   keyEquivalent: "")
        chip.state = emulator.bigChipRAM ? .on : .off
        machine.addItem(.separator())
        machine.addItem(withTitle: "Reset", action: #selector(resetMachine), keyEquivalent: "r")
        let warp = machine.addItem(withTitle: "Warp Speed", action: #selector(toggleWarp(_:)), keyEquivalent: "t")
        warp.state = emulator.warp ? .on : .off
        let instant = machine.addItem(withTitle: "Instant Load (Skip Disk Wait)", action: #selector(toggleInstantLoad(_:)),
                                      keyEquivalent: "l")
        instant.state = emulator.instantLoad ? .on : .off
        machine.addItem(.separator())
        let cursor = machine.addItem(withTitle: "Arrow Keys Control Joystick (Port 2)",
                                     action: #selector(toggleCursorJoystick(_:)), keyEquivalent: "j")
        cursor.state = view.cursorKeysAsJoystick ? .on : .off
        machine.items.forEach { $0.target = self }
        machineItem.submenu = machine
        main.addItem(machineItem)
        let viewItem = NSMenuItem()
        viewItem.submenu = NSMenu(title: "View")
        let crop = viewItem.submenu!.addItem(withTitle: "Crop Borders", action: #selector(toggleCropBorders(_:)), keyEquivalent: "b")
        crop.target = self
        crop.state = UserDefaults.standard.bool(forKey: "CropBorders") ? .on : .off
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }
}

/// Machine ▸ Kickstart ROM lists the ROM files (.rom, .bin) in the folder of the loaded
/// Kickstart and in `Kickstart ROMs` beside the working directory, the loaded one checked;
/// choosing one restarts the machine with it, without an extended ROM.
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let folders = [emulator.romURL?.deletingLastPathComponent(), URL(fileURLWithPath: "Kickstart ROMs")]
            .compactMap { $0?.standardizedFileURL }
        var roms: [URL] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            where ["rom", "bin"].contains(file.pathExtension.lowercased()) && !roms.contains(file.standardizedFileURL) {
                roms.append(file.standardizedFileURL)
            }
        }
        for rom in roms {
            let item = menu.addItem(withTitle: rom.lastPathComponent, action: #selector(chooseListedROM(_:)), keyEquivalent: "")
            item.representedObject = rom
            item.state = rom == emulator.romURL?.standardizedFileURL ? .on : .off
            item.target = self
        }
        if !roms.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Other Kickstart ROM…", action: #selector(chooseROM), keyEquivalent: "k").target = self
    }

    @objc func chooseListedROM(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(rom: url, extended: nil) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
