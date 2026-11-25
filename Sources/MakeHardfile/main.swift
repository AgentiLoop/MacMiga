import Foundation
import MacMigaCore

/// Builds a hardfile (one FFS partition, for MacMiga's DH0) from a Mac folder or an LHA archive.
var arguments = Array(CommandLine.arguments.dropFirst())
var name: String?
var freeBytes: Int?
var startup: String?
var list = false
while let first = arguments.first, first.hasPrefix("--") {
    arguments.removeFirst()
    if first == "--list" { list = true }
    else if first == "--name", !arguments.isEmpty { name = arguments.removeFirst() }
    else if first == "--startup", !arguments.isEmpty { startup = arguments.removeFirst() }
    else if first == "--free", let value = arguments.first.flatMap({ Int($0) }), value >= 0 {
        freeBytes = value << 20
        arguments.removeFirst()
    } else { arguments = [] }
}
guard arguments.count == (list ? 1 : 2) else {
    print("""
    Usage: MakeHardfile [--name VOLUME] [--free MiB] [--startup "COMMANDS"] <folder | archive.lha> <output.hdf>
           MakeHardfile --list <folder | archive.lha>
    """)
    exit(2)
}
let source = URL(fileURLWithPath: arguments[0])
do {
    if list {
        let entries = try VolumeEntry.entries(of: source)
        for entry in entries {
            let size = entry.contents.map { String($0.count) } ?? "(dir)"
            print(size.padding(toLength: 10, withPad: " ", startingAt: 0) + entry.path.joined(separator: "/"))
        }
        print("\(entries.count) entries, \(entries.reduce(0) { $0 + ($1.contents?.count ?? 0) }) bytes")
    } else {
        let image = try FastFileSystem.hardfile(from: source, name: name, freeBytes: freeBytes, startupSequence: startup)
        try Data(image).write(to: URL(fileURLWithPath: arguments[1]))
        print("\(arguments[1]): \(image.count) bytes, \(image.count / HardDisk.cylinderSize) cylinders")
    }
} catch {
    print("MakeHardfile: \(error)")
    exit(1)
}
