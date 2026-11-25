import Testing
@testable import MacMigaCore

private let day = AmigaDate(year: 2026, month: 11, day: 25)

private func longs(_ values: [UInt32]) -> [UInt8] {
    values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - $0 * 8)) } }
}

@Test func volumesBecomePartitionsByteForByte() throws {
    let system = try FastFileSystem.hardfile(named: "System", entries: [VolumeEntry(path: ["S", "Startup-Sequence"],
                                             contents: Array("Echo hi\n".utf8), date: day)], date: day)
    let work = try FastFileSystem.hardfile(named: "Work", entries: [], freeBytes: 1 << 20, date: day, fastFileSystem: false)
    var spare = RigidDiskBuilder.Partition(name: "Spare", cylinders: 10, dosType: 0x5046_5303)
    spare.automount = false
    var second = RigidDiskBuilder.Partition(name: "DH1", volume: work)
    second.bootPriority = -3
    second.bootable = false
    let image = try RigidDiskBuilder.image(partitions: [RigidDiskBuilder.Partition(name: "DH0", volume: system), second, spare])

    let disk = try HardDisk(image: image)
    #expect(disk.isPartitioned)
    #expect(disk.surfaces == 1 && disk.sectorsPerTrack == 32)
    #expect(disk.cylinders * HardDisk.cylinderSize == image.count)
    #expect(disk.partitions.map(\.name) == ["DH0", "DH1"]) // Spare is not mounted
    #expect(disk.partitions.map(\.dosType) == [0x444F_5301, 0x444F_5300])
    #expect(disk.partitions.map(\.bootPriority) == [0, -128])
    #expect(disk.partitions[0].firstBlock == 2 * 32) // after the two cylinders of the table
    #expect(disk.partitions[0].environment[6] == 2)  // reserved blocks, as in a hardfile
    for (partition, volume) in zip(disk.partitions, [system, work]) {
        #expect(partition.blockCount * 512 == volume.count)
        #expect(Array(image[partition.firstBlock * 512..<partition.firstBlock * 512 + volume.count]) == volume)
    }
    #expect(image.count == (2 + system.count / HardDisk.cylinderSize + work.count / HardDisk.cylinderSize + 10) * HardDisk.cylinderSize)
    #expect(disk.fileSystems.isEmpty)
    // The priority is kept for a bootable partition.
    second.bootable = true
    #expect(try HardDisk(image: RigidDiskBuilder.image(partitions: [second])).partitions[0].bootPriority == -3)
}

@Test func fileSystemsAreStoredInTheTable() throws {
    // 300 long words of code: three LoadSeg blocks, the last one partly used.
    let filler = [UInt32](repeating: 0x4E71_4E71, count: 300)
    let program = longs([0x3F3, 0, 1, 0, 0, 300, 0x3E9, 300] + filler + [0x3F2])
    let small = longs([0x3F3, 0, 1, 0, 0, 1, 0x3E9, 1, 0x4E75_4E71, 0x3F2])
    let systems = [RigidDiskBuilder.FileSystem(dosType: 0x5046_5303, version: 0x0013_0002, program: program, name: "pfs3aio"),
                   RigidDiskBuilder.FileSystem(dosType: 0x444F_5301, version: 0x0028_0001, program: small)]
    // Enough partitions and LoadSeg blocks to need a third cylinder for the table.
    let partitions = (0..<60).map { RigidDiskBuilder.Partition(name: "P\($0)", cylinders: 1, dosType: 0x5046_5303) }
    let image = try RigidDiskBuilder.image(partitions: partitions, fileSystems: systems)
    let disk = try HardDisk(image: image)
    #expect(disk.partitions.count == 60)
    #expect(disk.partitions[0].firstBlock == 3 * 32)
    #expect(disk.fileSystems.map(\.dosType) == [0x5046_5303, 0x444F_5301])
    #expect(disk.fileSystems.map(\.version) == [0x0013_0002, 0x0028_0001])
    #expect(disk.fileSystems.map(\.name) == ["pfs3aio", ""])
    #expect(disk.fileSystems.map(\.patchFlags) == [0x180, 0x180])
    #expect(disk.fileSystems[0].fields[4] == 16384 && disk.fileSystems[0].fields[8] == 0xFFFF_FFFF)
    #expect(try disk.fileSystems[0].program == HunkFile(program))
    #expect(try disk.fileSystems[1].program == HunkFile(small))
}

@Test func badPartitionsAndProgramsAreRejected() throws {
    let volume = try FastFileSystem.hardfile(named: "V", entries: [], date: day)
    func build(_ partitions: [RigidDiskBuilder.Partition], _ systems: [RigidDiskBuilder.FileSystem] = []) throws {
        _ = try RigidDiskBuilder.image(partitions: partitions, fileSystems: systems)
    }
    #expect(throws: RigidDiskBuilder.BuildError.partitionCount(0)) { try build([]) }
    #expect(throws: RigidDiskBuilder.BuildError.invalidName("a:b")) { try build([.init(name: "a:b", volume: volume)]) }
    #expect(throws: RigidDiskBuilder.BuildError.invalidName("dh0")) {
        try build([.init(name: "DH0", volume: volume), .init(name: "dh0", volume: volume)])
    }
    #expect(throws: RigidDiskBuilder.BuildError.invalidSize("A")) { try build([.init(name: "A", volume: Array(volume.dropLast(512)))]) }
    #expect(throws: RigidDiskBuilder.BuildError.invalidSize("A")) { try build([.init(name: "A", cylinders: 0, dosType: 1)]) }
    var unformatted = volume
    unformatted.replaceSubrange(0..<4, with: [0, 0, 0, 0])
    #expect(throws: RigidDiskBuilder.BuildError.unknownType("A")) { try build([.init(name: "A", volume: unformatted)]) }
    try build([.init(name: "A", volume: unformatted, dosType: 0x5046_5303)])
    #expect(throws: RigidDiskBuilder.BuildError.invalidProgram("x")) {
        try build([.init(name: "A", volume: volume)], [.init(dosType: 1, version: 1, program: [1, 2, 3, 4], name: "x")])
    }
}
