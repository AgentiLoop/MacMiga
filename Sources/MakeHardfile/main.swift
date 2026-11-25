import Foundation
import MacMigaCore

/// Builds a hardfile (one FFS partition, for MacMiga's DH0) from Mac folders and LHA archives.
var arguments = Array(CommandLine.arguments.dropFirst())
var name: String?
var freeBytes: Int?
var startup: String?
var list = false
while let first = arguments.first, first.hasPrefix("--") {
    arguments.removeFirst()
    if first == "--list" { list = true }
    else if first == "--name", !arguments.isEmpty { name = arguments.removeFirst() }
    else if first == "--startup", !arguments.isEmpty { // each use adds a line
        startup = (startup.map { $0 + "\n" } ?? "") + arguments.removeFirst()
    }
    else if first == "--free", let value = arguments.first.flatMap({ Int($0) }), value >= 0 {
        freeBytes = value << 20
        arguments.removeFirst()
    } else { arguments = [] }
}
guard list ? arguments.count == 1 : arguments.count >= 2 else {
    print("""
    Usage: MakeHardfile [--name VOLUME] [--free MiB] [--startup "COMMAND"]... <folder | archive.lha>... <output.hdf>
           MakeHardfile --list <folder | archive.lha>
    """)
    exit(2)
}
let source = URL(fileURLWithPath: arguments[0])
let output = arguments[arguments.count - 1]
do {
    if list {
        let entries = try VolumeEntry.entries(of: source)
        for entry in entries {
            let size = entry.contents.map { String($0.count) } ?? "(dir)"
            print(size.padding(toLength: 10, withPad: " ", startingAt: 0) + entry.path.joined(separator: "/"))
        }
        print("\(entries.count) entries, \(entries.reduce(0) { $0 + ($1.contents?.count ?? 0) }) bytes")
    } else {
        let sources = arguments.dropLast().map { URL(fileURLWithPath: $0) }
        let image = try FastFileSystem.hardfile(from: sources, name: name, freeBytes: freeBytes, startupSequence: startup)
        try Data(image).write(to: URL(fileURLWithPath: output))
        print("\(output): \(image.count) bytes, \(image.count / HardDisk.cylinderSize) cylinders")
    }
} catch {
    print("MakeHardfile: \(error)")
    exit(1)
}
