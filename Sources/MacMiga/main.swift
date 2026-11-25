import AppKit
import AVFoundation
import MacMigaCore
import UniformTypeIdentifiers

/// MacMiga app: one window showing the emulated PAL display, driven at 50 frames per second
/// on the main thread. Keyboard and mouse events inside the window go to the Amiga.
@MainActor
final class Emulator {
    private(set) var machine: AmigaMachine?
    private(set) var romURL: URL?
    private(set) var diskURL: URL?
    private var disk: [UInt8]?
    var onError: ((String) -> Void)?
    let audio = AudioOutput()

    func load(rom url: URL) throws {
        var machine = try AmigaMachine(kickstart: Array(try Data(contentsOf: url)))
        if let audio { machine.memory.audio.sampleRate = audio.sampleRate }
        self.machine = machine
        romURL = url
        UserDefaults.standard.set(url.path, forKey: "kickstartPath")
        if let disk { try self.machine?.memory.insertDisk(adf: disk) }
    }

    func reset() throws {
        if let romURL { try load(rom: romURL) }
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

    /// Runs until the chipset completes one more frame (bounded so a bug cannot hang the UI).
    func runFrame() {
        guard var machine else { return }
        let start = machine.memory.video.frameCount
        do {
            var steps = 0
            while machine.memory.video.frameCount == start && steps < 400_000 {
                try machine.step()
                steps += 1
            }
            audio?.queue.push(machine.memory.audio.drainSamples())
            self.machine = machine
        } catch {
            self.machine = nil
            onError?(String(format: "Emulation stopped at PC=$%08X: %@", machine.cpu.programCounter, "\(error)"))
        }
    }

    func key(_ code: UInt8, pressed: Bool) { machine?.key(code, pressed: pressed) }

    func mouse(dx: Int, dy: Int, left: Bool, right: Bool) {
        machine?.mouse(dx: dx, dy: dy, left: left, right: right)
    }
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
    var image: CGImage?
    private var left = false, right = false
    private var modifiersDown = Set<UInt16>()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(.black)
        context.fill(bounds)
        guard let image else { return }
        context.interpolationQuality = .none
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    func show(_ video: Video) {
        let data = video.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        image = CGImage(width: Video.width, height: Video.height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: Video.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                 | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        guard !event.isARepeat, let code = amigaKeys[event.keyCode] else { return }
        emulator?.key(code, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        if let code = amigaKeys[event.keyCode] { emulator?.key(code, pressed: false) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = amigaKeys[event.keyCode] else { return }
        let pressed = !modifiersDown.contains(event.keyCode)
        if pressed { modifiersDown.insert(event.keyCode) } else { modifiersDown.remove(event.keyCode) }
        emulator?.key(code, pressed: pressed)
    }

    private func sendMouse(_ event: NSEvent?) {
        let dx = Int((event?.deltaX ?? 0).rounded()), dy = Int((event?.deltaY ?? 0).rounded())
        emulator?.mouse(dx: dx, dy: dy, left: left, right: right)
    }

    override func mouseMoved(with event: NSEvent) { sendMouse(event) }
    override func mouseDragged(with event: NSEvent) { sendMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(event) }
    override func mouseDown(with event: NSEvent) { left = true; sendMouse(nil) }
    override func mouseUp(with event: NSEvent) { left = false; sendMouse(nil) }
    override func rightMouseDown(with event: NSEvent) { right = true; sendMouse(nil) }
    override func rightMouseUp(with event: NSEvent) { right = false; sendMouse(nil) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let emulator = Emulator()
    var window: NSWindow!
    let view = DisplayView(frame: NSRect(x: 0, y: 0, width: Video.width, height: Video.height * 2))
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.contentView = view
        window.contentAspectRatio = view.frame.size
        window.center()
        view.emulator = emulator
        emulator.onError = { [weak self] message in self?.alert(message) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        window.acceptsMouseMovedEvents = true
        NSApp.activate(ignoringOtherApps: true)

        let arguments = Array(CommandLine.arguments.dropFirst())
        let romPath = arguments.first { !$0.lowercased().hasSuffix(".adf") }
            ?? UserDefaults.standard.string(forKey: "kickstartPath")
            ?? ["Kickstart ROMs/kickstart-1.3.rom"].first { FileManager.default.fileExists(atPath: $0) }
        if let romPath { open(rom: URL(fileURLWithPath: romPath)) } else { chooseROM() }
        if let adf = arguments.first(where: { $0.lowercased().hasSuffix(".adf") }) {
            insert(adf: URL(fileURLWithPath: adf))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 50.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func tick() {
        emulator.runFrame()
        if let video = emulator.machine?.memory.video { view.show(video) }
    }

    private func updateTitle() {
        let rom = emulator.romURL?.lastPathComponent ?? "no Kickstart"
        let disk = emulator.diskURL?.lastPathComponent ?? "empty"
        window.title = "MacMiga — \(rom) — DF0: \(disk)"
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MacMiga"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
        updateTitle()
    }

    private func open(rom url: URL) {
        do { try emulator.load(rom: url) } catch { alert("Could not load \(url.lastPathComponent): \(error)") }
        updateTitle()
    }

    private func insert(adf url: URL) {
        do { try emulator.insert(adf: url) } catch { alert("Could not insert \(url.lastPathComponent): \(error)") }
        updateTitle()
    }

    private func choose(_ extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @objc func chooseROM() { if let url = choose(["rom", "bin"]) { open(rom: url) } }
    @objc func chooseADF() { if let url = choose(["adf"]) { insert(adf: url) } }
    @objc func ejectDisk() { emulator.eject(); updateTitle() }
    @objc func resetMachine() {
        do { try emulator.reset() } catch { alert("Reset failed: \(error)") }
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
        machine.addItem(withTitle: "Insert Disk (DF0)…", action: #selector(chooseADF), keyEquivalent: "o")
        machine.addItem(withTitle: "Eject Disk", action: #selector(ejectDisk), keyEquivalent: "e")
        machine.addItem(.separator())
        machine.addItem(withTitle: "Reset", action: #selector(resetMachine), keyEquivalent: "r")
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
