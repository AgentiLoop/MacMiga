import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Standalone diagnostic compiled alongside MacMigaCore, not a boot compatibility test.
@main
struct KickstartProbe {
    static func main() throws {
        var paths = Array(CommandLine.arguments.dropFirst())
        var limit = 10_000
        var frameDirectory: String?
        var adfPath: String?
        while paths.count >= 2, paths[0].hasPrefix("--") {
            if paths[0] == "--limit", let value = Int(paths[1]), value > 0 { limit = value }
            else if paths[0] == "--frames" { frameDirectory = paths[1] }
            else if paths[0] == "--adf" { adfPath = paths[1] }
            else { break }
            paths.removeFirst(2)
        }
        guard !paths.isEmpty else {
            print("Usage: KickstartProbe [--limit N] [--frames DIR] [--adf DISK.adf] <raw ROM path> [<raw ROM path> ...]")
            return
        }
        for path in paths {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            var machine = try AmigaMachine(kickstart: Array(bytes))
            if let adfPath {
                try machine.memory.insertDisk(adf: Array(try Data(contentsOf: URL(fileURLWithPath: adfPath))))
                print("DF0: \(URL(fileURLWithPath: adfPath).lastPathComponent)")
            }
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(bytes.count) bytes")
            print(String(format: "Reset: SSP=$%08X PC=$%08X", machine.cpu.supervisorStackPointer, machine.cpu.programCounter))
            var completed = 0
            do {
                for _ in 0..<limit {
                    try machine.step()
                    completed += 1
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
            let custom = machine.memory.custom
            print(String(format: "BPLCON0=$%04X DIW=$%04X-$%04X DDF=$%04X-$%04X", custom.register(0x100), custom.register(0x08E), custom.register(0x090), custom.register(0x092), custom.register(0x094)))
            print("COLOR00-07: " + (0..<8).map { String(format: "$%03X", custom.register(0x180 + $0 * 2)) }.joined(separator: " "))
            if let directory = frameDirectory {
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
                try writePNG(machine.memory.video, to: url)
                print("Last frame written to \(url.path)")
            }
        }
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
