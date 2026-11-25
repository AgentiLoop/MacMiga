import AppKit
import AVFoundation
import GameController
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

final class DisplayView: NSView {
    var emulator: Emulator?
    /// Pixels of the frame on screen, kept to tell whether the next frame differs.
    private var shownPixels = Data()
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

    // The frame is the contents of the view's layer, which the window server scales with
    // nearest-neighbour sampling; nothing is drawn through Core Graphics at window size.
    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = .black
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layerContentsRedrawPolicy = .never
        return layer
    }

    /// Shows the frame unless it is the one already on screen, which costs no redraw at all.
    func show(_ video: Video) {
        let unchanged = video.pixels.withUnsafeBytes { new in
            shownPixels.withUnsafeBytes { old in
                old.count == new.count && memcmp(old.baseAddress, new.baseAddress, new.count) == 0
            }
        }
        guard !unchanged else { return }
        shownPixels = video.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: shownPixels as CFData) else { return }
        // In the window's own colour space Core Animation takes the pixels as they are; any
        // other space makes it convert every frame on the CPU.
        layer?.contents = CGImage(width: Video.width, height: Video.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: Video.width * 4,
                                  space: window?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

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
    /// of the 736-pixel-wide view, so scale by the view size to keep pointer speed 1:1.
    private func moveMouse(_ event: NSEvent) {
        guard mouseCaptured else { return }
        remainder.x += Double(event.deltaX) * Double(Video.width) / (2 * bounds.width)
        remainder.y += Double(event.deltaY) * Double(Video.height) / bounds.height
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let emulator = Emulator()
    var window: NSWindow!
    /// The Fast RAM submenu, whose check marks change when a WHDLoad disk turns fast RAM on.
    private var fastRAMMenu: NSMenu?
    let view = DisplayView(frame: NSRect(x: 0, y: 0, width: Video.width, height: Video.height * 2))
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        view.wantsLayer = true
        window.contentView = view
        window.contentAspectRatio = view.frame.size
        window.center()
        view.emulator = emulator
        emulator.onError = { [weak self] message in self?.alert(message) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        window.acceptsMouseMovedEvents = true
        NSApp.activate(ignoringOtherApps: true)
        view.onMouseCaptureChange = { [weak self] in self?.updateTitle() }
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
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 50.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { emulator.saveHardDisk() }

    private func tick() {
        if emulator.warp {
            // As many frames as fit in 15 ms of each 20 ms tick, so the window stays responsive.
            let deadline = Date().addingTimeInterval(0.015)
            repeat { emulator.runFrame(playAudio: false) } while emulator.machine != nil && Date() < deadline
        } else {
            emulator.runFrame()
        }
        if let video = emulator.machine?.memory.video { view.show(video) }
    }

    private func updateTitle() {
        let rom = (emulator.romURL?.lastPathComponent ?? "no Kickstart")
            + (emulator.extendedROMURL.map { " + \($0.lastPathComponent)" } ?? "")
        let disk = emulator.diskURL?.lastPathComponent ?? "empty"
        let hardDisk = emulator.hardDiskURL.map { " — DH0: \($0.lastPathComponent)" } ?? ""
        let hint = view.mouseCaptured ? " — ⌘ releases the mouse" : ""
        let warp = emulator.warp ? " — warp" : ""
        window.title = "MacMiga — \(rom) — DF0: \(disk)\(hardDisk)\(warp)\(hint)"
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
    @objc func chooseADF() { if let url = choose(["adf"]) { insert(adf: url) } }
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
    @objc func toggleBigChipRAM(_ sender: NSMenuItem) {
        do { try emulator.setBigChipRAM(!emulator.bigChipRAM) } catch { alert("Reset failed: \(error)") }
        sender.state = emulator.bigChipRAM ? .on : .off
        view.updateJoystick()
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
        machine.addItem(withTitle: "Open Kickstart ROM…", action: #selector(chooseROM), keyEquivalent: "k")
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
        machine.addItem(.separator())
        let cursor = machine.addItem(withTitle: "Arrow Keys Control Joystick (Port 2)",
                                     action: #selector(toggleCursorJoystick(_:)), keyEquivalent: "j")
        cursor.state = view.cursorKeysAsJoystick ? .on : .off
        machine.items.forEach { $0.target = self }
        machineItem.submenu = machine
        main.addItem(machineItem)
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
