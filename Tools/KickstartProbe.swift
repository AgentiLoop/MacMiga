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
        var fastRAM = 0
        var chipRAM = 512 * 1024
        var trace = 0
        var presses: [(frame: Int, key: UInt8)] = []
        var fires: [Int] = []
        while paths.count >= 2, paths[0].hasPrefix("--") {
            if paths[0] == "--limit", let value = Int(paths[1]), value > 0 { limit = value }
            else if paths[0] == "--frames" { frameDirectory = paths[1] }
            else if paths[0] == "--adf" { adfPath = paths[1] }
            else if paths[0] == "--hdf" { hardDiskPath = paths[1] }
            else if paths[0] == "--hdf-out" { hardDiskOutput = paths[1] }
            else if paths[0] == "--fast", let value = Int(paths[1]), value >= 0 { fastRAM = value << 20 }
            else if paths[0] == "--trace", let value = Int(paths[1]), value >= 0 { trace = value }
            else if paths[0] == "--chip", let value = Int(paths[1]), [512, 1024, 2048].contains(value) { chipRAM = value << 10 }
            else if paths[0] == "--key", let (frame, key) = Self.keyPress(paths[1]) { presses.append((frame, key)) }
            else if paths[0] == "--fire", let frame = Int(paths[1]) { fires.append(frame) }
            else { break }
            paths.removeFirst(2)
        }
        guard !paths.isEmpty else {
            print("Usage: KickstartProbe [--limit N] [--frames DIR] [--adf DISK.adf] [--hdf DISK.hdf] [--hdf-out COPY.hdf] [--fast MiB] [--chip 512|1024|2048] [--trace N] [--key FRAME:HEXCODE]... [--fire FRAME]... <raw ROM path> [<raw ROM path> ...]")
            return
        }
        for path in paths {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            let hardDisk = try hardDiskPath.map { try HardDisk(image: Array(try Data(contentsOf: URL(fileURLWithPath: $0)))) }
            var machine = try AmigaMachine(kickstart: Array(bytes), chipRAMSize: chipRAM, fastRAMSize: fastRAM, hardDisk: hardDisk)
            if let adfPath {
                try machine.memory.insertDisk(adf: Array(try Data(contentsOf: URL(fileURLWithPath: adfPath))))
                print("DF0: \(URL(fileURLWithPath: adfPath).lastPathComponent)")
            }
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(bytes.count) bytes")
            print(String(format: "Reset: SSP=$%08X PC=$%08X", machine.cpu.supervisorStackPointer, machine.cpu.programCounter))
            var completed = 0
            do {
                var frame = -1
                for _ in 0..<limit {
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
                print("Hard disk \(hardDisk.isPartitioned ? "with partition table" : "hardfile"): " + partitions.joined(separator: ", "))
                print("Hard disk: \(hardDisk.blocksRead) blocks read, \(hardDisk.blocksWritten) written")
                if let hardDiskOutput {
                    try Data(hardDisk.bytes).write(to: URL(fileURLWithPath: hardDiskOutput))
                    print("Hard disk image written to \(hardDiskOutput)")
                }
            }
            if let directory = frameDirectory {
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
                try writePNG(machine.memory.video, to: url)
                print("Last frame written to \(url.path)")
            }
        }
    }

    /// What the running Kickstart has found, read from exec's and graphics.library's own
    /// structures: the memory list, and (Kickstart 2.0 and newer) the chip revision bits.
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
        return lines
    }

    /// Parses `FRAME:HEXCODE`, e.g. `3000:59` for F10 at frame 3000.
    static func keyPress(_ text: String) -> (Int, UInt8)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let frame = Int(parts[0]), let key = UInt8(parts[1], radix: 16) else { return nil }
        return (frame, key)
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
