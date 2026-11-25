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
var international = false
var directoryCache = false
var rdb = false
var fileSystems: [String] = []
while let first = arguments.first, first.hasPrefix("--") {
    arguments.removeFirst()
    if first == "--list" { list = true }
    else if first == "--extract" { extract = true }
    else if first == "--skip-long-names" { skipNames = true }
    else if first == "--auto" { autoStart = true } // run the only program, as the app does
    else if first == "--ofs" { ofs = true }        // for Kickstart 1.x
    else if first == "--intl" { international = true } // DOS\2/DOS\3, for Kickstart 2.04+
    else if first == "--dircache" { directoryCache = true } // DOS\4/DOS\5, for Kickstart 3.0+
    else if first == "--rdb" { rdb = true }        // a partitioned image from hardfiles
    else if first == "--fs", !arguments.isEmpty { fileSystems.append(arguments.removeFirst()) }
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
if rdb { makePartitionedImage(arguments, fileSystems: fileSystems) }
guard list ? arguments.count == 1 : extract ? arguments.count == 2 : arguments.count >= 2 else {
    print("""
    Usage: MakeHardfile [--name VOLUME] [--free MiB] [--startup "COMMAND"]... [--exclude PATH]...
                        [--auto] [--ofs] [--intl] [--dircache] [--skip-long-names] <folder | archive.lha>... <output.hdf>
           MakeHardfile --rdb [--fs HEXTYPE:VERSION.REVISION:FILE]... <PARTITION>... <output.hdf>
             PARTITION: NAME=FILE.hdf or NAME=<MiB>M,type=HEXTYPE, then any of ,pri=N ,noboot ,nomount ,type=HEXTYPE
             e.g. --fs 50465303:19.2:pfs3aio DH0=system.hdf DH1=work.hdf,pri=-1 PFS=200M,type=50465303,noboot
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
                                                autoStart: autoStart, fastFileSystem: !ofs,
                                                international: international, directoryCache: directoryCache) { path in
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

/// `--rdb`: puts hardfiles (and empty partitions) behind a partition table, with file systems.
func makePartitionedImage(_ arguments: [String], fileSystems: [String]) -> Never {
    func fail(_ message: String) -> Never {
        print("MakeHardfile: \(message)")
        exit(1)
    }
    guard arguments.count >= 2 else { fail("--rdb needs at least one partition and the output file") }
    do {
        let systems = try fileSystems.map { text -> RigidDiskBuilder.FileSystem in
            let parts = text.split(separator: ":", maxSplits: 2).map(String.init)
            let version = parts.count == 3 ? parts[1].split(separator: ".").compactMap { UInt32($0) } : []
            guard parts.count == 3, let type = UInt32(parts[0], radix: 16), (1...2).contains(version.count) else {
                fail("--fs wants HEXTYPE:VERSION.REVISION:FILE, not \(text)")
            }
            let url = URL(fileURLWithPath: parts[2])
            return RigidDiskBuilder.FileSystem(dosType: type, version: version[0] << 16 | (version.count > 1 ? version[1] : 0),
                                               program: Array(try Data(contentsOf: url)), name: url.lastPathComponent)
        }
        let partitions = try arguments.dropLast().map { text -> RigidDiskBuilder.Partition in
            let fields = text.split(separator: ",").map(String.init)
            guard let equals = fields[0].firstIndex(of: "=") else { fail("a partition is NAME=FILE or NAME=<MiB>M, not \(text)") }
            let name = String(fields[0][..<equals]), value = String(fields[0][fields[0].index(after: equals)...])
            var type: UInt32?
            for option in fields.dropFirst() where option.hasPrefix("type=") {
                guard let parsed = UInt32(option.dropFirst(5), radix: 16) else { fail("bad type in \(text)") }
                type = parsed
            }
            var partition: RigidDiskBuilder.Partition
            if value.uppercased().hasSuffix("M"), let megabytes = Int(value.dropLast()), megabytes > 0 {
                guard let type else { fail("an empty partition needs type=HEXTYPE: \(text)") }
                partition = RigidDiskBuilder.Partition(name: name, cylinders: megabytes << 20 / HardDisk.cylinderSize, dosType: type)
            } else {
                partition = RigidDiskBuilder.Partition(name: name, volume: Array(try Data(contentsOf: URL(fileURLWithPath: value))),
                                                       dosType: type)
            }
            for option in fields.dropFirst() {
                if option == "noboot" { partition.bootable = false }
                else if option == "nomount" { partition.automount = false }
                else if option.hasPrefix("pri="), let priority = Int(option.dropFirst(4)), (-128...127).contains(priority) {
                    partition.bootPriority = priority
                } else if !option.hasPrefix("type=") { fail("unknown option \(option) in \(text)") }
            }
            return partition
        }
        let image = try RigidDiskBuilder.image(partitions: partitions, fileSystems: systems)
        try Data(image).write(to: URL(fileURLWithPath: arguments[arguments.count - 1]))
        let disk = try HardDisk(image: image)
        print("\(arguments[arguments.count - 1]): \(image.count) bytes, \(disk.cylinders) cylinders")
        for partition in disk.partitions {
            print("  \(partition.name): blocks \(partition.firstBlock)-\(partition.firstBlock + partition.blockCount - 1), "
                  + String(format: "type $%08X, boot priority %d", partition.dosType, partition.bootPriority))
        }
        for system in disk.fileSystems {
            print(String(format: "  file system $%08X version %d.%d: ", system.dosType, system.version >> 16, system.version & 0xFFFF) + system.name)
        }
    } catch {
        fail("\(error)")
    }
    exit(0)
}
