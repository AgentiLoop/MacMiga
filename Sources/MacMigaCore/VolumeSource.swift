import Foundation

extension VolumeEntry {
    /// Reads a Mac folder, with everything below it, as volume entries (paths relative to
    /// the folder, sorted by name). Only regular files and directories are taken; symbolic
    /// links and other special files are left out, as are `.DS_Store` and `._*` files.
    /// Dates are the modification dates as wall-clock time in `timeZone`. A file or directory
    /// whose path `include` rejects is left out without being read, a directory with
    /// everything below it.
    public static func entries(ofFolder folder: URL, timeZone: TimeZone = .current,
                               include: ([String]) -> Bool = { _ in true }) throws -> [VolumeEntry] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var entries: [VolumeEntry] = []
        func visit(_ directory: URL, _ path: [String]) throws {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let name = child.lastPathComponent.precomposedStringWithCanonicalMapping
                guard name != ".DS_Store", !name.hasPrefix("._"), include(path + [name]) else { continue }
                let values = try child.resourceValues(forKeys: Set(keys))
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                    from: values.contentModificationDate ?? Date())
                let date = AmigaDate(year: parts.year ?? 1978, month: parts.month ?? 1, day: parts.day ?? 1,
                                     hour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0)
                if values.isDirectory == true {
                    entries.append(VolumeEntry(path: path + [name], contents: nil, date: date))
                    try visit(child, path + [name])
                } else if values.isRegularFile == true {
                    entries.append(VolumeEntry(path: path + [name], contents: Array(try Data(contentsOf: child)), date: date))
                }
            }
        }
        try visit(folder, [])
        return entries
    }
}

extension VolumeEntry {
    /// The entries of a Mac folder or of an LHA archive (`.lha`, `.lzh`), without those whose
    /// path, or the path of a directory above them, `include` rejects.
    public static func entries(of source: URL, include: ([String]) -> Bool = { _ in true }) throws -> [VolumeEntry] {
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { return try entries(ofFolder: source, include: include) }
        return try LHA.unpack(Array(try Data(contentsOf: source))).filter { entry in
            (1...entry.path.count).allSatisfy { include(Array(entry.path.prefix($0))) }
        }
    }
}

extension FastFileSystem {
    /// Builds a hardfile from Mac folders and LHA archives, whose contents are merged into
    /// one volume (a file found in several sources is taken from the last). The volume is
    /// named `name`, or after the first folder or archive (characters AmigaDOS does not
    /// allow become `_`, and the name is cut to 30 characters), and dated now.
    /// `startupSequence`, if given, becomes the text of `S/Startup-Sequence`, replacing one
    /// from the sources. Without one, `autoStart` makes a startup-sequence (see
    /// `VolumeEntry.startupSequence(for:)`) if the sources have none. Files and directories whose path `include` rejects are left out.
    /// `fastFileSystem` false writes an OFS volume, for Kickstart 1.x; `international` the
    /// international mode; `directoryCache` the directory-cache mode.
    public static func hardfile(from sources: [URL], name: String? = nil, freeBytes: Int? = nil,
                                startupSequence: String? = nil, autoStart: Bool = false,
                                fastFileSystem: Bool = true, international: Bool = false, directoryCache: Bool = false,
                                include: ([String]) -> Bool = { _ in true }) throws -> [UInt8] {
        precondition(!sources.isEmpty)
        var entries = try sources.flatMap { try VolumeEntry.entries(of: $0, include: include) }
        let source = sources[0]
        let base = source.pathExtension.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let fallback = String(String.UnicodeScalarView(base.precomposedStringWithCanonicalMapping.unicodeScalars
            .map { $0.value < 0x20 || $0.value > 0xFF || $0 == "/" || $0 == ":" ? "_" : $0 }.prefix(30)))
        let now = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let date = AmigaDate(year: now.year ?? 1978, month: now.month ?? 1, day: now.day ?? 1,
                             hour: now.hour ?? 0, minute: now.minute ?? 0, second: now.second ?? 0)
        var startupSequence = startupSequence
        if startupSequence == nil, autoStart { startupSequence = VolumeEntry.startupSequence(for: entries) }
        if let startupSequence {
            // AmigaDOS reads scripts as ISO Latin-1 (accents composed, as macOS may pass
            // them decomposed); other characters become `?`.
            let text = (startupSequence + "\n").precomposedStringWithCanonicalMapping.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : 0x3F }
            entries.append(VolumeEntry(path: ["S", "Startup-Sequence"], contents: text, date: date))
        }
        return try hardfile(named: name ?? (fallback.isEmpty ? "MacMigaHD" : fallback), entries: entries,
                            freeBytes: freeBytes, date: date, fastFileSystem: fastFileSystem, international: international,
                            directoryCache: directoryCache)
    }
}

extension VolumeEntry {
    /// Whether the entry is an AmigaDOS load file (it starts with HUNK_HEADER).
    var isProgram: Bool { contents?.starts(with: [0, 0, 3, 0xF3]) == true }

    /// The WHDLoad slaves among the entries: programs named `*.slave`.
    public static func whdloadSlaves(in entries: [VolumeEntry]) -> [VolumeEntry] {
        entries.filter { $0.isProgram && $0.path.last?.lowercased().hasSuffix(".slave") == true }
    }

    /// The WHDLoad program among the entries: a program named `WHDLoad` in a `C` directory.
    public static func whdload(in entries: [VolumeEntry]) -> VolumeEntry? {
        entries.first { $0.isProgram && $0.path.count >= 2 && $0.path.suffix(2).map { $0.lowercased() } == ["c", "whdload"] }
    }

    /// A startup-sequence that starts the entries' software, for entries without
    /// `S/Startup-Sequence`: with exactly one WHDLoad slave and the WHDLoad program, WHDLoad
    /// starts the slave from its directory; otherwise the only program (slaves and WHDLoad
    /// aside) is run. Nil when there is a startup-sequence already or nothing unambiguous to start.
    public static func startupSequence(for entries: [VolumeEntry]) -> String? {
        guard !entries.contains(where: { $0.path.map { $0.lowercased() } == ["s", "startup-sequence"] }) else { return nil }
        // Paths with spaces are quoted for the shell.
        func quoted(_ text: String) -> String { text.contains(" ") ? "\"\(text)\"" : text }
        let slaves = whdloadSlaves(in: entries)
        if slaves.count == 1, let whdload = whdload(in: entries) {
            let slave = slaves[0].path
            return (slave.count > 1 ? "CD \(quoted(slave.dropLast().joined(separator: "/")))\n" : "")
                + "\(quoted("SYS:" + whdload.path.joined(separator: "/"))) \(quoted(slave.last!)) PRELOAD"
        }
        let whdloadPath = whdload(in: entries)?.path
        let programs = entries.filter { $0.isProgram && $0.path != whdloadPath && $0.path.last?.lowercased().hasSuffix(".slave") == false }
        return programs.count == 1 ? quoted(programs[0].path.joined(separator: "/")) : nil
    }
}
