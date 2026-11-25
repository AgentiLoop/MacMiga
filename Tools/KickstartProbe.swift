import Foundation

/// Standalone diagnostic compiled alongside MacMigaCore, not a boot compatibility test.
@main
struct KickstartProbe {
    static func main() throws {
        let paths = CommandLine.arguments.dropFirst()
        guard !paths.isEmpty else {
            print("Usage: KickstartProbe <raw ROM path> [<raw ROM path> ...]")
            return
        }
        for path in paths {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            var memory = try AmigaMemory(kickstart: Array(bytes))
            var cpu = MC68000()
            try cpu.reset(memory: &memory)
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(bytes.count) bytes")
            print(String(format: "Reset: SSP=$%08X PC=$%08X", cpu.supervisorStackPointer, cpu.programCounter))
            var completed = 0
            do {
                for _ in 0..<10_000 {
                    try cpu.step(memory: &memory)
                    completed += 1
                }
                print("Stopped at the 10000-instruction limit; no boot success inferred.")
            } catch {
                print(String(format: "Stopped after %d completed instructions at PC=$%08X", completed, cpu.programCounter))
                if let opcode = try? memory.readWord(at: cpu.programCounter) {
                    print(String(format: "Next opcode: $%04X", opcode))
                }
                print("Diagnostic: \(error)")
            }
        }
    }
}
