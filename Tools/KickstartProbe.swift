import Foundation
import ImageIO
import MacMigaCore
import UniformTypeIdentifiers

/// Standalone diagnostic compiled alongside MacMigaCore, not a boot compatibility test.
@main
struct KickstartProbe {
    static func main() throws {
        var paths = Array(CommandLine.arguments.dropFirst())
        var limit = 10_000
        var frameDirectory: String?
        var adfPath: String?
        var hardDiskPath: String?
        var hardDiskOutput: String?
        var extendedROMPath: String?
        var fastRAM = 0
        var chipRAM = 512 * 1024
        var trace = 0
        var history = 0
        var exceptionsFrom: Int?
        var watch: (address: UInt32, fromFrame: Int)?
        var presses: [(frame: Int, key: UInt8)] = []
        var fires: [Int] = []
        var moves: [(frame: Int, dx: Int, dy: Int)] = []
        var clicks: [Int] = []
        var rightHolds: [(frame: Int, frames: Int)] = []
        var snapshots: [Int] = []
        while paths.count >= 2, paths[0].hasPrefix("--") {
            if paths[0] == "--limit", let value = Int(paths[1]), value > 0 { limit = value }
            else if paths[0] == "--frames" { frameDirectory = paths[1] }
            else if paths[0] == "--adf" { adfPath = paths[1] }
            else if paths[0] == "--hdf" { hardDiskPath = paths[1] }
            else if paths[0] == "--hdf-out" { hardDiskOutput = paths[1] }
            else if paths[0] == "--ext" { extendedROMPath = paths[1] }
            else if paths[0] == "--fast", let value = Int(paths[1]), value >= 0 { fastRAM = value << 20 }
            else if paths[0] == "--trace", let value = Int(paths[1]), value >= 0 { trace = value }
            else if paths[0] == "--wild", let value = Int(paths[1]), value > 0 { history = value }
            else if paths[0] == "--exceptions", let value = Int(paths[1]) { exceptionsFrom = value }
            else if paths[0] == "--watch", let (frame, address) = Self.watchpoint(paths[1]) { watch = (address, frame) }
            else if paths[0] == "--chip", let value = Int(paths[1]), [512, 1024, 2048].contains(value) { chipRAM = value << 10 }
            else if paths[0] == "--key", let (frame, key) = Self.keyPress(paths[1]) { presses.append((frame, key)) }
            else if paths[0] == "--fire", let frame = Int(paths[1]) { fires.append(frame) }
            else if paths[0] == "--mouse", let numbers = Self.numbers(paths[1], count: 3) { moves.append((numbers[0], numbers[1], numbers[2])) }
            else if paths[0] == "--click", let frame = Int(paths[1]) { clicks.append(frame) }
            else if paths[0] == "--right", let numbers = Self.numbers(paths[1], count: 2) { rightHolds.append((numbers[0], numbers[1])) }
            else if paths[0] == "--snapshot", let frame = Int(paths[1]) { snapshots.append(frame) }
            else { break }
            paths.removeFirst(2)
        }
        guard !paths.isEmpty else {
            print("Usage: KickstartProbe [--limit N] [--frames DIR] [--adf DISK.adf] [--hdf DISK.hdf] [--hdf-out COPY.hdf] [--ext EXTENDED.rom] [--fast MiB] [--chip 512|1024|2048] [--trace N] [--wild N] [--exceptions FRAME] [--watch FRAME:HEXADDRESS] [--key FRAME:HEXCODE]... [--fire FRAME]... [--mouse FRAME:DX:DY]... [--click FRAME]... [--right FRAME:FRAMES]... [--snapshot FRAME]... <raw ROM path> [<raw ROM path> ...]")
            return
        }
        for path in paths {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            // As in the app, an image file that cannot be written is a write-protected disk.
            let hardDisk = try hardDiskPath.map {
                try HardDisk(image: Array(try Data(contentsOf: URL(fileURLWithPath: $0), options: .alwaysMapped)),
                             writeProtected: !FileManager.default.isWritableFile(atPath: $0))
            }
            let extendedROM = try extendedROMPath.map { Array(try Data(contentsOf: URL(fileURLWithPath: $0))) } ?? []
            var machine = try AmigaMachine(kickstart: Array(bytes), extendedROM: extendedROM, chipRAMSize: chipRAM, fastRAMSize: fastRAM, hardDisk: hardDisk)
            if let adfPath {
                try machine.memory.insertDisk(adf: Array(try Data(contentsOf: URL(fileURLWithPath: adfPath))))
                print("DF0: \(URL(fileURLWithPath: adfPath).lastPathComponent)")
            }
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(bytes.count) bytes")
            print(String(format: "Reset: SSP=$%08X PC=$%08X", machine.cpu.supervisorStackPointer, machine.cpu.programCounter))
            var completed = 0
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            // Mouse counts still to send for each scripted move, a few per frame as a hand would.
            var pending = moves.map { (dx: $0.dx, dy: $0.dy) }
            do {
                var frame = -1
                // With --wild: the last instructions executed, to show how the PC left the
                // 24-bit address space or got into the mirrors of chip RAM (which no program
                // does on purpose).
                var recent = [(pc: UInt32, sr: UInt16, a7: UInt32)](repeating: (0, 0, 0), count: history)
                // With --exceptions: the handler addresses of vectors 2–11 (bus error … line F),
                // re-read every frame, and how many times one was entered and reported.
                var handlers: [UInt32] = []
                var reported = 0
                // With --watch: the long word at an address in RAM, and the changes reported.
                var watched: UInt32?
                var changes = 0
                for _ in 0..<limit {
                    if let watch, frame >= watch.fromFrame, changes < 20 {
                        let before = machine.cpu.programCounter, cpu = machine.cpu
                        try machine.step()
                        completed += 1
                        let value = (try? machine.memory.readLong(at: watch.address)) ?? 0
                        if let old = watched, old != value {
                            changes += 1
                            let registers = (0..<8).map { String(format: "%08X", cpu[address: $0]) }.joined(separator: " ")
                            let words = (0..<3).map { String(format: "%04X", (try? machine.memory.readWord(at: before &+ UInt32($0 * 2))) ?? 0) }
                            let custom = machine.memory.custom
                            print(String(format: "$%06X changed from $%08X to $%08X in frame %d during the instruction at $%08X: %@ A: %@", watch.address, old, value,
                                         machine.memory.video.frameCount, before, words.joined(separator: " "), registers))
                            print(String(format: "  Blitter: BLTCON0=$%04X BLTCON1=$%04X BLTSIZE=$%04X C=$%06X B=$%06X A=$%06X D=$%06X; DSKPT=$%06X DMACON=$%04X",
                                         custom.register(0x40), custom.register(0x42), custom.register(0x58), custom.blitterPointers[0], custom.blitterPointers[1],
                                         custom.blitterPointers[2], custom.blitterPointers[3], custom.diskPointer, custom.dmacon))
                        }
                        watched = value
                        frame = machine.memory.video.frameCount
                        continue
                    }
                    if let from = exceptionsFrom, frame >= from, reported < 40 {
                        let before = machine.cpu.programCounter, wasSupervisor = machine.cpu.statusRegister & 0x2000 != 0
                        let stack = machine.cpu.supervisorStackPointer
                        if history > 0 { recent[completed % history] = (before, machine.cpu.statusRegister, machine.cpu[address: 7]) }
                        try machine.step()
                        completed += 1
                        let after = machine.cpu.programCounter
                        if machine.cpu.supervisorStackPointer < stack, let vector = handlers.firstIndex(of: after), vector != 6, after &- before > 10 { // not 8, privilege: AROS's way into supervisor mode
                            reported += 1
                            if reported == 1, history > 0 { // how the first one came about
                                for index in 0..<history {
                                    let entry = recent[(completed + index) % history]
                                    let words = (0..<3).map { String(format: "%04X", (try? machine.memory.readWord(at: entry.pc &+ UInt32($0 * 2))) ?? 0) }
                                    print(String(format: "  $%08X: %@  SR=%04X A7=%08X", entry.pc, words.joined(separator: " "), entry.sr, entry.a7))
                                }
                            }
                            let words = (0..<3).map { String(format: "%04X", (try? machine.memory.readWord(at: before &+ UInt32($0 * 2))) ?? 0) }
                            let data = (0..<8).map { String(format: "%08X", machine.cpu[data: $0]) }.joined(separator: " ")
                            let address = (0..<7).map { String(format: "%08X", machine.cpu[address: $0]) }.joined(separator: " ")
                            print(String(format: "Vector %d taken in frame %d at $%08X: %@ (%@ mode) SSP=$%08X USP=$%08X D: %@ A: %@", vector + 2, frame, before,
                                         words.joined(separator: " "), wasSupervisor ? "supervisor" : "user", stack, machine.cpu.userStackPointer, data, address))
                        }
                        if machine.memory.video.frameCount != frame {
                            frame = machine.memory.video.frameCount
                            handlers = (2...11).map { (try? machine.memory.readLong(at: UInt32($0 * 4))) ?? 0 }
                        }
                        continue
                    }
                    if history > 0 {
                        let pc = machine.cpu.programCounter
                        if pc > 0xFF_FFFF || (pc >= UInt32(chipRAM) && pc < 0x20_0000) {
                            print(String(format: "PC left the address space or entered the mirrors of chip RAM after %d instructions, in frame %d. Last %d instructions:", completed, frame, history))
                            for index in 0..<history {
                                let entry = recent[(completed + index) % history]
                                let words = (0..<3).map { String(format: "%04X", (try? machine.memory.readWord(at: entry.pc &+ UInt32($0 * 2))) ?? 0) }
                                print(String(format: "  $%08X: %@  SR=%04X A7=%08X", entry.pc, words.joined(separator: " "), entry.sr, entry.a7))
                            }
                            break
                        }
                        recent[completed % history] = (pc, machine.cpu.statusRegister, machine.cpu[address: 7])
                    }
                    try machine.step()
                    completed += 1
                    guard machine.memory.video.frameCount != frame else { continue }
                    // Scripted input: a key is held for 5 frames, the port-2 fire button for 10.
                    frame = machine.memory.video.frameCount
                    for press in presses {
                        if press.frame == frame { machine.key(press.key, pressed: true) }
                        if press.frame + 5 == frame { machine.key(press.key, pressed: false) }
                    }
                    if fires.contains(frame) { machine.joystick(Joystick(), fire: true) }
                    if fires.contains(frame - 10) { machine.joystick(Joystick(), fire: false) }
                    if !moves.isEmpty || !clicks.isEmpty || !rightHolds.isEmpty {
                        // The mouse moves at most 8 counts a frame; the left button is held for 5 frames.
                        var dx = 0, dy = 0
                        for index in moves.indices where moves[index].frame <= frame {
                            let stepX = max(-8, min(8, pending[index].dx)), stepY = max(-8, min(8, pending[index].dy))
                            pending[index].dx -= stepX; pending[index].dy -= stepY
                            dx += stepX; dy += stepY
                        }
                        machine.mouse(dx: dx, dy: dy, left: clicks.contains { $0 <= frame && frame < $0 + 5 },
                                      right: rightHolds.contains { $0.frame <= frame && frame < $0.frame + $0.frames })
                    }
                    if snapshots.contains(frame), let directory = frameDirectory {
                        try writePNG(machine.memory.video, to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(frame).png"))
                    }
                }
                print(String(format: "Stopped at the %d-instruction limit at PC=$%08X SR=$%04X; no boot success inferred.", limit, machine.cpu.programCounter, machine.cpu.statusRegister))
                print(String(format: "Emulated %.2f s; stopped=%@ INTENA=$%04X INTREQ=$%04X DMACON=$%04X", Double(machine.clock) / Double(AmigaMachine.cpuClock), machine.cpu.isStopped ? "yes" : "no", machine.memory.custom.intena, machine.memory.custom.intreq, machine.memory.custom.dmacon))
            } catch {
                print(String(format: "Stopped after %d completed instructions at PC=$%08X", completed, machine.cpu.programCounter))
                if let opcode = try? machine.memory.readWord(at: machine.cpu.programCounter) {
                    print(String(format: "Next opcode: $%04X", opcode))
                }
                print("Diagnostic: \(error)")
            }
            print("Frames completed: \(machine.memory.video.frameCount)")
            for _ in 0..<trace {
                let pc = machine.cpu.programCounter
                let words = (0..<3).map { String(format: "%04X", (try? machine.memory.readWord(at: pc &+ UInt32($0 * 2))) ?? 0) }
                let data = (0..<8).map { String(format: "%08X", machine.cpu[data: $0]) }.joined(separator: " ")
                let address = (0..<8).map { String(format: "%08X", machine.cpu[address: $0]) }.joined(separator: " ")
                print(String(format: "$%06X: %@  SR=%04X D: %@ A: %@", pc & 0xFF_FFFF, words.joined(separator: " "),
                             machine.cpu.statusRegister, data, address))
                do { try machine.step() } catch { print("Diagnostic: \(error)"); break }
            }
            let custom = machine.memory.custom
            print(String(format: "BPLCON0=$%04X DIW=$%04X-$%04X DDF=$%04X-$%04X", custom.register(0x100), custom.register(0x08E), custom.register(0x090), custom.register(0x092), custom.register(0x094)))
            print("COLOR00-07: " + (0..<8).map { String(format: "$%03X", custom.register(0x180 + $0 * 2)) }.joined(separator: " "))
            for line in systemReport(&machine.memory) { print(line) }
            if !custom.serialOutput.isEmpty {
                print("Serial output (\(custom.serialOutput.count) bytes):")
                print(String(String.UnicodeScalarView(custom.serialOutput.map { Unicode.Scalar($0) })))
            }
            let boards = machine.memory.expansion.boards.map { board in
                "\(board.kind) " + (board.base.map { String(format: "at $%06X", $0) } ?? "not configured")
            }
            if !boards.isEmpty { print("Expansion boards: " + boards.joined(separator: ", ")) }
            if let hardDisk {
                let partitions = hardDisk.partitions.map { partition in
                    let type = String(format: "$%08X", partition.dosType)
                    return "\(partition.name) (DosType \(type), blocks \(partition.firstBlock)-\(partition.firstBlock + partition.blockCount - 1), boot priority \(partition.bootPriority))"
                }
                print("Hard disk \(hardDisk.isPartitioned ? "with partition table" : "hardfile")\(hardDisk.isWriteProtected ? ", write-protected" : ""): " + partitions.joined(separator: ", "))
                if !hardDisk.fileSystems.isEmpty {
                    let systems = hardDisk.fileSystems.map { system in
                        String(format: "DosType $%08X version %d.%d", system.dosType, system.version >> 16, system.version & 0xFFFF)
                            + (system.name.isEmpty ? "" : " \"\(system.name)\"")
                            + (system.program.map { " (\($0.hunks.count) hunk\($0.hunks.count == 1 ? "" : "s"), \($0.loadSize) bytes)" } ?? " (program not readable)")
                    }
                    print("File systems in the partition table: " + systems.joined(separator: ", "))
                }
                print("Hard disk: \(hardDisk.blocksRead) blocks read, \(hardDisk.blocksWritten) written")
                if let hardDiskOutput {
                    try Data(hardDisk.bytes).write(to: URL(fileURLWithPath: hardDiskOutput))
                    print("Hard disk image written to \(hardDiskOutput)")
                }
            }
            if let directory = frameDirectory {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
                try writePNG(machine.memory.video, to: url)
                print("Last frame written to \(url.path)")
            }
        }
    }

    /// What the running Kickstart has found, read from exec's, graphics.library's and
    /// dos.library's own structures: the memory list, (Kickstart 2.0 and newer) the chip
    /// revision bits, the entries of FileSystem.resource, and DOS's devices and volumes.
    /// Empty when ExecBase is not set up.
    static func systemReport(_ memory: inout AmigaMemory) -> [String] {
        guard let sysBase = try? memory.readLong(at: 4), sysBase & 1 == 0, sysBase != 0,
              let check = try? memory.readLong(at: sysBase + 38), check == ~sysBase else { return [] }
        func name(of node: UInt32) -> String {
            guard var address = try? memory.readLong(at: node + 10) else { return "" }
            var bytes: [UInt8] = []
            while bytes.count < 40, let byte = try? memory.readByte(at: address), byte != 0 { bytes.append(byte); address += 1 }
            return String(decoding: bytes, as: UTF8.self)
        }
        /// Nodes of the exec list whose header is at `list`.
        func nodes(_ list: UInt32) -> [UInt32] {
            var result: [UInt32] = []
            var node = (try? memory.readLong(at: list)) ?? 0
            while result.count < 64, node != 0, node & 1 == 0, let next = try? memory.readLong(at: node), next != 0 {
                result.append(node)
                node = next
            }
            return result
        }
        var lines: [String] = []
        for header in nodes(sysBase + 322) {
            let attributes = (try? memory.readWord(at: header + 14)) ?? 0
            let lower = (try? memory.readLong(at: header + 20)) ?? 0
            let upper = (try? memory.readLong(at: header + 24)) ?? 0
            let free = (try? memory.readLong(at: header + 28)) ?? 0
            let kind = attributes & 2 != 0 ? "chip" : attributes & 4 != 0 ? "fast" : "other"
            lines.append(String(format: "Exec memory: %@ $%06X-$%06X, %d bytes free (%@)", kind, lower, upper, free, name(of: header)))
        }
        for library in nodes(sysBase + 378) where name(of: library) == "graphics.library" {
            let version = (try? memory.readWord(at: library + 20)) ?? 0
            guard version >= 36, let bits = try? memory.readByte(at: library + 236) else { continue }
            lines.append(String(format: "graphics.library %d ChipRevBits0=$%02X (ECS Agnus %@, ECS Denise %@, AGA %@)", version, bits,
                                bits & 1 != 0 ? "yes" : "no", bits & 2 != 0 ? "yes" : "no", bits & 0x0C != 0 ? "yes" : "no"))
        }
        for resource in nodes(sysBase + 336) where name(of: resource) == "FileSystem.resource" {
            let entries = nodes(resource + 18).map { entry in
                String(format: "$%08X %d.%d", (try? memory.readLong(at: entry + 14)) ?? 0,
                       ((try? memory.readLong(at: entry + 18)) ?? 0) >> 16, ((try? memory.readLong(at: entry + 18)) ?? 0) & 0xFFFF)
            }
            lines.append("FileSystem.resource (DosType and version): " + entries.joined(separator: ", "))
        }
        // dos.library: dl_Root -> rn_Info -> di_DevInfo, a chain of BPTRs.
        for library in nodes(sysBase + 378) where name(of: library) == "dos.library" {
            func pointer(_ address: UInt32) -> UInt32 { ((try? memory.readLong(at: address)) ?? 0) << 2 }
            let root = (try? memory.readLong(at: library + 34)) ?? 0
            guard root != 0, root & 1 == 0 else { continue }
            var entry = pointer(pointer(root + 24) + 4)
            var devices: [String] = [], volumes: [String] = []
            var count = 0
            while entry != 0, count < 64 {
                count += 1
                var text = pointer(entry + 40)
                let length = Int((try? memory.readByte(at: text)) ?? 0)
                var bytes: [UInt8] = []
                for _ in 0..<min(length, 30) { text += 1; bytes.append((try? memory.readByte(at: text)) ?? 0x3F) }
                let label = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
                let task = (try? memory.readLong(at: entry + 8)) ?? 0
                switch (try? memory.readLong(at: entry + 4)) ?? 99 {
                case 0: devices.append(String(format: "%@ (segment list $%06X, %@)", label, pointer(entry + 32), task != 0 ? "handler running" : "handler not started"))
                case 2: volumes.append("\"\(label)\"")
                default: break
                }
                entry = pointer(entry)
            }
            lines.append("DOS devices: " + devices.joined(separator: ", "))
            lines.append("DOS volumes: " + (volumes.isEmpty ? "none" : volumes.joined(separator: ", ")))
        }
        return lines
    }

    /// Parses `FRAME:HEXCODE`, e.g. `3000:59` for F10 at frame 3000.
    static func keyPress(_ text: String) -> (Int, UInt8)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let frame = Int(parts[0]), let key = UInt8(parts[1], radix: 16) else { return nil }
        return (frame, key)
    }

    /// Parses `FRAME:HEXADDRESS`, e.g. `11000:4`.
    static func watchpoint(_ text: String) -> (Int, UInt32)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let frame = Int(parts[0]), let address = UInt32(parts[1], radix: 16) else { return nil }
        return (frame, address)
    }

    /// Parses `count` integers separated by colons, e.g. `23000:40:-12`.
    static func numbers(_ text: String, count: Int) -> [Int]? {
        let values = text.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
        return values.count == count ? values : nil
    }

    static func writePNG(_ video: Video, to url: URL) throws {
        var bytes = [UInt8]()
        bytes.reserveCapacity(video.pixels.count * 4)
        for pixel in video.pixels {
            bytes += [UInt8(pixel >> 16 & 0xFF), UInt8(pixel >> 8 & 0xFF), UInt8(pixel & 0xFF), 255]
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: Video.width, height: Video.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: Video.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
