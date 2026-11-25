import Foundation

/// Standalone diagnostic compiled alongside MacMigaCore, not a boot compatibility test.
@main
struct KickstartProbe {
    static func main() throws {
        var paths = Array(CommandLine.arguments.dropFirst())
        var limit = 10_000
        if paths.count >= 2, paths[0] == "--limit", let value = Int(paths[1]), value > 0 {
            limit = value
            paths.removeFirst(2)
        }
        guard !paths.isEmpty else {
            print("Usage: KickstartProbe [--limit N] <raw ROM path> [<raw ROM path> ...]")
            return
        }
        for path in paths {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            var machine = try AmigaMachine(kickstart: Array(bytes))
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
        }
    }
}
