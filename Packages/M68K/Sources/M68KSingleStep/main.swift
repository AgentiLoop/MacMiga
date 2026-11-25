import Foundation
import M68K

// Runs the MC68000 against the SingleStepTests 68000 set (github.com/SingleStepTests/680x0,
// folder 68000/v1): about 8,000 single instructions per operation, each with the complete
// state of the registers and memory before and after. The set was generated with a reference
// emulator, not measured on a 68000, so a difference is a question to settle with the
// Motorola manuals rather than a verdict. The tests are not part of this repository;
// download them and pass the folder.
//
//   swift run -c release M68KSingleStep [--show N] [--address-errors] [--only TEXT] <folder | file.json[.gz]>...
//
// A test passes when D0–D7, A0–A6, USP, SSP, SR, PC and every listed byte of memory match
// and nothing else was written. Bus timing and the prefetch queue are not compared (this
// core models neither). Tests in which the 68000 took an address error are counted apart:
// "exact" when everything matches, "state only" when everything but the seven words of the
// exception frame does, "wrong" otherwise. The exit status is 0 when no test failed and none
// is "wrong". `--show N` lists the first N failures of each file, `--address-errors`
// those among the address-error tests instead; `--only TEXT` runs the tests whose name
// contains TEXT.

/// 16 MiB of RAM over the whole 24-bit address space, remembering what was written.
struct Memory: M68KBus {
    var bytes = [UInt8](repeating: 0, count: 1 << 24)
    var written: [UInt32] = []

    mutating func readByte(at address: UInt32) throws -> UInt8 { bytes[Int(address & 0xFF_FFFF)] }
    mutating func readWord(at address: UInt32) throws -> UInt16 {
        UInt16(bytes[Int(address & 0xFF_FFFF)]) << 8 | UInt16(bytes[Int((address &+ 1) & 0xFF_FFFF)])
    }
    mutating func readLong(at address: UInt32) throws -> UInt32 {
        UInt32(try readWord(at: address)) << 16 | UInt32(try readWord(at: address &+ 2))
    }
    mutating func writeByte(_ value: UInt8, at address: UInt32) throws {
        bytes[Int(address & 0xFF_FFFF)] = value
        written.append(address & 0xFF_FFFF)
    }
    mutating func writeWord(_ value: UInt16, at address: UInt32) throws {
        try writeByte(UInt8(value >> 8), at: address)
        try writeByte(UInt8(value & 0xFF), at: address &+ 1)
    }
    mutating func writeLong(_ value: UInt32, at address: UInt32) throws {
        try writeWord(UInt16(value >> 16), at: address)
        try writeWord(UInt16(value & 0xFFFF), at: address &+ 2)
    }
}

struct Tally {
    var tests = 0
    var passed = 0
    var failed = 0
    /// Address-error tests: all, those matching exactly, and those matching outside the frame.
    var addressErrors = 0
    var addressErrorsExact = 0
    var addressErrorsState = 0
    var examples: [String] = []

    static func + (a: Tally, b: Tally) -> Tally {
        Tally(tests: a.tests + b.tests, passed: a.passed + b.passed, failed: a.failed + b.failed,
              addressErrors: a.addressErrors + b.addressErrors, addressErrorsExact: a.addressErrorsExact + b.addressErrorsExact,
              addressErrorsState: a.addressErrorsState + b.addressErrorsState, examples: [])
    }
}

func load(_ url: URL) throws -> [[String: Any]] {
    var data = try Data(contentsOf: url)
    if url.pathExtension == "gz" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
    }
    return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
}

func number(_ state: [String: Any], _ key: String) -> UInt32 { UInt32(truncatingIfNeeded: (state[key] as? NSNumber)?.int64Value ?? 0) }

func pairs(_ state: [String: Any]) -> [(address: UInt32, value: UInt8)] {
    (state["ram"] as? [[NSNumber]] ?? []).map { (UInt32(truncatingIfNeeded: $0[0].int64Value) & 0xFF_FFFF, UInt8(truncatingIfNeeded: $0[1].intValue)) }
}

func run(_ url: URL, show: Int, showFrames: Bool, only: String?) throws -> Tally {
    var tally = Tally()
    var memory = Memory()
    for test in try load(url) {
        let name = test["name"] as? String ?? ""
        if let only, !name.contains(only) { continue }
        guard let initial = test["initial"] as? [String: Any], let final = test["final"] as? [String: Any] else { continue }
        // Clear what the previous test left behind.
        for address in memory.written { memory.bytes[Int(address)] = 0 }
        memory.written.removeAll(keepingCapacity: true)

        var cpu = MC68000()
        cpu.statusRegister = UInt16(truncatingIfNeeded: number(initial, "sr"))
        for index in 0..<8 { cpu[data: index] = number(initial, "d\(index)") }
        for index in 0..<7 { cpu[address: index] = number(initial, "a\(index)") }
        cpu.userStackPointer = number(initial, "usp")
        cpu.supervisorStackPointer = number(initial, "ssp")
        let pc = number(initial, "pc")
        cpu.programCounter = pc
        // The two prefetched words are the instruction's first two words.
        let prefetch = (initial["prefetch"] as? [NSNumber] ?? []).map { UInt16(truncatingIfNeeded: $0.intValue) }
        for (index, word) in prefetch.enumerated() { try memory.writeWord(word, at: pc &+ UInt32(index * 2)) }
        for (address, value) in pairs(initial) { try memory.writeByte(value, at: address) }
        let setUp = memory.written.count

        // For finding a test that crashes the core: the last name printed is the culprit.
        if ProcessInfo.processInfo.environment["M68K_NAMES"] != nil { FileHandle.standardError.write(Data((name + "\n").utf8)) }
        var differences: [String] = []
        do { try cpu.step(memory: &memory) } catch { differences.append("threw \(error)") }

        for index in 0..<8 where cpu[data: index] != number(final, "d\(index)") {
            differences.append(String(format: "D%d=%08X not %08X", index, cpu[data: index], number(final, "d\(index)")))
        }
        for index in 0..<7 where cpu[address: index] != number(final, "a\(index)") {
            differences.append(String(format: "A%d=%08X not %08X", index, cpu[address: index], number(final, "a\(index)")))
        }
        if cpu.userStackPointer != number(final, "usp") { differences.append(String(format: "USP=%08X not %08X", cpu.userStackPointer, number(final, "usp"))) }
        if cpu.supervisorStackPointer != number(final, "ssp") { differences.append(String(format: "SSP=%08X not %08X", cpu.supervisorStackPointer, number(final, "ssp"))) }
        if cpu.statusRegister != UInt16(truncatingIfNeeded: number(final, "sr")) & 0xA71F {
            differences.append(String(format: "SR=%04X not %04X", cpu.statusRegister, number(final, "sr")))
        }
        if cpu.programCounter != number(final, "pc") { differences.append(String(format: "PC=%08X not %08X", cpu.programCounter, number(final, "pc"))) }

        // Memory: every listed byte, and no write to an unlisted one. The seven words of an
        // address-error frame are reported apart.
        // The 68000 took an address error if it read the vector at addresses 12 and 14 and then
        // fetched two words of the handler (an instruction that reads its operand there
        // fetches one word afterwards).
        let reads = (test["transactions"] as? [[Any]] ?? []).filter { $0.count >= 4 && $0[0] as? String == "r" }
            .map { (function: ($0[2] as? NSNumber)?.intValue ?? 0, address: ($0[3] as? NSNumber)?.intValue ?? 0) }
        var isAddressError = false
        if let vector = reads.indices.dropLast().last(where: { reads[$0].address == 12 && reads[$0 + 1].address == 14 }) {
            isAddressError = reads[(vector + 2)...].filter { $0.function == 6 }.count == 2
        }
        let frame = number(final, "ssp") & 0xFF_FFFF
        var frameDifferences: [String] = []
        var listed = Set<UInt32>()
        for (address, value) in pairs(final) {
            listed.insert(address)
            guard memory.bytes[Int(address)] != value else { continue }
            let text = String(format: "(%06X)=%02X not %02X", address, memory.bytes[Int(address)], value)
            if isAddressError, address &- frame < 14 { frameDifferences.append(text) } else { differences.append(text) }
        }
        for address in memory.written.dropFirst(setUp) where !listed.contains(address) {
            differences.append(String(format: "stray write to %06X", address))
        }

        tally.tests += 1
        if isAddressError {
            tally.addressErrors += 1
            if differences.isEmpty { tally.addressErrorsState += 1 }
            if differences.isEmpty && frameDifferences.isEmpty { tally.addressErrorsExact += 1 }
        } else if differences.isEmpty {
            tally.passed += 1
        } else {
            tally.failed += 1
        }
        let all = differences + (isAddressError ? frameDifferences.map { "frame " + $0 } : [])
        if !all.isEmpty, tally.examples.count < show, isAddressError == showFrames {
            tally.examples.append("    \(name)\(isAddressError ? " [address error]" : ""): " + all.prefix(8).joined(separator: ", "))
        }
    }
    return tally
}

var arguments = Array(CommandLine.arguments.dropFirst())
var show = 0
var only: String?
var showFrames = false
while let first = arguments.first, first.hasPrefix("--") {
    arguments.removeFirst()
    if first == "--show", let value = arguments.first.flatMap({ Int($0) }) { show = value; arguments.removeFirst() }
    else if first == "--only", !arguments.isEmpty { only = arguments.removeFirst() }
    else if first == "--address-errors" { showFrames = true }
    else { arguments = [] }
}
guard !arguments.isEmpty else {
    print("Usage: M68KSingleStep [--show N] [--address-errors] [--only TEXT] <folder | file.json[.gz]>...")
    exit(2)
}
var files: [URL] = []
for argument in arguments {
    let url = URL(fileURLWithPath: argument)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
        files += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".json") || $0.lastPathComponent.hasSuffix(".json.gz") }
    } else {
        files.append(url)
    }
}
files.sort { $0.lastPathComponent < $1.lastPathComponent }

// One file per core; results are printed in file order.
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var tallies: [Int: Result<Tally, Error>] = [:]
    func set(_ index: Int, _ value: Result<Tally, Error>) { lock.lock(); tallies[index] = value; lock.unlock() }
    func get(_ index: Int) -> Result<Tally, Error>? { lock.lock(); defer { lock.unlock() }; return tallies[index] }
}
/// Not on the main actor, unlike top-level code: the closure runs on Dispatch's worker threads.
nonisolated func runAll(_ list: [URL], show: Int, showFrames: Bool, only: String?) -> Results {
    let results = Results()
    DispatchQueue.concurrentPerform(iterations: list.count) { index in
        results.set(index, Result { try run(list[index], show: show, showFrames: showFrames, only: only) })
    }
    return results
}
let results = runAll(files, show: show, showFrames: showFrames, only: only)
var total = Tally()
print("file                  tests  passed  failed | address errors: exact  state only  wrong")
for (index, file) in files.enumerated() {
    let label = file.lastPathComponent.replacingOccurrences(of: ".json.gz", with: "").replacingOccurrences(of: ".json", with: "")
    switch results.get(index) {
    case .success(let tally)?:
        total = total + tally
        let state = tally.addressErrorsState - tally.addressErrorsExact, wrong = tally.addressErrors - tally.addressErrorsState
        print(label.padding(toLength: 20, withPad: " ", startingAt: 0)
              + String(format: "%7d %7d %7d | %21d %11d %6d", tally.tests, tally.passed, tally.failed, tally.addressErrorsExact, state, wrong))
        for example in tally.examples { print(example) }
    case .failure(let error)?: print("\(label): \(error)")
    case nil: break
    }
}
print("total".padding(toLength: 20, withPad: " ", startingAt: 0)
      + String(format: "%7d %7d %7d | %21d %11d %6d", total.tests, total.passed, total.failed, total.addressErrorsExact,
               total.addressErrorsState - total.addressErrorsExact, total.addressErrors - total.addressErrorsState))
exit(total.failed == 0 && total.addressErrors == total.addressErrorsState ? 0 : 1)
