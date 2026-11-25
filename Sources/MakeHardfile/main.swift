import Foundation
import MacMigaCore

/// Builds a hardfile (one FFS or OFS partition, for MacMiga's DH0) from Mac folders and LHA archives.
var arguments = Array(CommandLine.arguments.dropFirst())
var name: String?
var freeBytes: Int?
var startup: String?
var list = false
var excluded: [[String]] = []
var skipNames = false
var extract = false
var autoStart = false
var ofs = false
while let first = arguments.first, first.hasPrefix("--") {
    arguments.removeFirst()
    if first == "--list" { list = true }
    else if first == "--extract" { extract = true }
    else if first == "--skip-long-names" { skipNames = true }
    else if first == "--auto" { autoStart = true } // run the only program, as the app does
    else if first == "--ofs" { ofs = true }        // for Kickstart 1.x
    else if first == "--exclude", !arguments.isEmpty { // a path from the top of a source, any case
        excluded.append(arguments.removeFirst().lowercased().split(separator: "/").map(String.init))
    }
    else if first == "--name", !arguments.isEmpty { name = arguments.removeFirst() }
    else if first == "--startup", !arguments.isEmpty { // each use adds a line
        startup = (startup.map { $0 + "\n" } ?? "") + arguments.removeFirst()
    }
    else if first == "--free", let value = arguments.first.flatMap({ Int($0) }), value >= 0 {
        freeBytes = value << 20
        arguments.removeFirst()
    } else { arguments = [] }
}
guard list ? arguments.count == 1 : extract ? arguments.count == 2 : arguments.count >= 2 else {
    print("""
    Usage: MakeHardfile [--name VOLUME] [--free MiB] [--startup "COMMAND"]... [--exclude PATH]...
                        [--auto] [--ofs] [--skip-long-names] <folder | archive.lha>... <output.hdf>
           MakeHardfile --list <folder | archive.lha>
           MakeHardfile --extract <archive.lha> <new folder>
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
    } else if extract {
        // Unpacks the archive into a folder on the Mac, for example to get at an ADF inside it.
        let folder = URL(fileURLWithPath: output)
        let entries = try VolumeEntry.entries(of: source)
        for entry in entries {
            let url = entry.path.reduce(folder) { $0.appendingPathComponent($1) }
            if let contents = entry.contents {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents).write(to: url)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        print("\(output): \(entries.count) entries")
    } else {
        let sources = arguments.dropLast().map { URL(fileURLWithPath: $0) }
        var skipped: [String] = []
        let image = try FastFileSystem.hardfile(from: sources, name: name, freeBytes: freeBytes, startupSequence: startup,
                                                autoStart: autoStart, fastFileSystem: !ofs) { path in
            if excluded.contains(path.map { $0.lowercased() }) { return false }
            if skipNames, let last = path.last, !FastFileSystem.canStore(name: last) {
                skipped.append(path.joined(separator: "/"))
                return false
            }
            return true
        }
        for path in skipped { print("Left out (an Amiga volume cannot hold this name): \(path)") }
        try Data(image).write(to: URL(fileURLWithPath: output))
        print("\(output): \(image.count) bytes, \(image.count / HardDisk.cylinderSize) cylinders")
    }
} catch {
    print("MakeHardfile: \(error)")
    exit(1)
}
