import Foundation
import M68K

// Runs the MC68000 against the two SingleStepTests sets for the 68000. Each test is a single
// instruction with the complete state of the registers and memory before and after, and the
// number of CPU clocks it takes.
//
//   github.com/SingleStepTests/680x0, folder 68000/v1: `.json.gz` files, about 8,000 tests per
//     operation, generated with a reference emulator.
//   github.com/SingleStepTests/m68000, folder v1: `.json.bin` files, 2,500 tests per
//     operation, generated with MAME's 68000, which is built from the chip's microcode.
//
// Neither was measured on a 68000, and they disagree with each other in places, so a difference
// is a question to settle with the Motorola manuals rather than a verdict. The tests are not
// part of this repository; download them and pass the folder.
//
//   swift run -c release M68KSingleStep [--show N] [--address-errors] [--clocks] [--only TEXT]
//                                       <folder | file.json[.gz] | file.json.bin>...
//
// A test passes when D0–D7, A0–A6, USP, SSP, SR, PC and every listed byte of memory match
// and nothing else was written. The bus cycles and the prefetch queue are not compared (this
// core models neither). Tests in which the 68000 took an address error are counted apart:
// "exact" when everything matches, "state only" when everything but the seven words of the
// exception frame does, "wrong" otherwise. The clocks `step` returns are compared with the
// test's length and counted in the last two columns; they do not make a test fail. The exit
// status is 0 when no test failed and none is "wrong".
// `--show N` lists the first N failures of each file, `--address-errors` those among the
// address-error tests instead, and `--clocks` the tests whose time differs instead of the
// failures; `--only TEXT` runs the tests whose name contains TEXT.

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

/// The processor and the listed memory before or after a test. `pc` is the address of the
/// instruction that executes next.
struct State {
    /// D0–D7, A0–A6, USP, SSP.
    var registers = [UInt32](repeating: 0, count: 17)
    var sr: UInt16 = 0
    var pc: UInt32 = 0
    /// The two words at `pc`.
    var prefetch: [UInt16] = []
    var ram: [(address: UInt32, value: UInt8)] = []
}

struct Test {
    var name = ""
    var initial = State()
    var final = State()
    /// CPU clocks the instruction takes.
    var length = 0
    /// Function code and address of each read bus cycle, in order.
    var reads: [(function: Int, address: Int)] = []
}

struct FormatError: Error, CustomStringConvertible {
    var description: String
}

/// The `.json` form of the 680x0 set, gzipped or not.
func loadJSON(_ url: URL) throws -> [Test] {
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
    func number(_ state: [String: Any], _ key: String) -> UInt32 {
        UInt32(truncatingIfNeeded: (state[key] as? NSNumber)?.int64Value ?? 0)
    }
    func state(_ json: [String: Any]) -> State {
        var state = State()
        for index in 0..<8 { state.registers[index] = number(json, "d\(index)") }
        for index in 0..<7 { state.registers[8 + index] = number(json, "a\(index)") }
        state.registers[15] = number(json, "usp")
        state.registers[16] = number(json, "ssp")
        state.sr = UInt16(truncatingIfNeeded: number(json, "sr"))
        state.pc = number(json, "pc")
        state.prefetch = (json["prefetch"] as? [NSNumber] ?? []).map { UInt16(truncatingIfNeeded: $0.intValue) }
        state.ram = (json["ram"] as? [[NSNumber]] ?? []).map {
            (UInt32(truncatingIfNeeded: $0[0].int64Value) & 0xFF_FFFF, UInt8(truncatingIfNeeded: $0[1].intValue))
        }
        return state
    }
    return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).compactMap { json in
        guard let initial = json["initial"] as? [String: Any], let final = json["final"] as? [String: Any] else { return nil }
        let reads = (json["transactions"] as? [[Any]] ?? []).filter { $0.count >= 4 && $0[0] as? String == "r" }
            .map { (function: ($0[2] as? NSNumber)?.intValue ?? 0, address: ($0[3] as? NSNumber)?.intValue ?? 0) }
        return Test(name: json["name"] as? String ?? "", initial: state(initial), final: state(final),
                    length: (json["length"] as? NSNumber)?.intValue ?? 0, reads: reads)
    }
}

/// The `.json.bin` form of the m68000 set: little-endian records, as its `decode.py` reads
/// them. That set records as PC the address of the next prefetch, which is 4 past the
/// instruction that executes next; 4 is subtracted here.
func loadBinary(_ url: URL) throws -> [Test] {
    let data = [UInt8](try Data(contentsOf: url))
    var position = 0
    func long() throws -> UInt32 {
        guard position + 4 <= data.count else { throw FormatError(description: "\(url.lastPathComponent) is truncated") }
        defer { position += 4 }
        return UInt32(data[position]) | UInt32(data[position + 1]) << 8 | UInt32(data[position + 2]) << 16 | UInt32(data[position + 3]) << 24
    }
    func record(_ magic: UInt32) throws {
        _ = try long()
        guard try long() == magic else { throw FormatError(description: "\(url.lastPathComponent): unexpected record at byte \(position - 4)") }
    }
    func state() throws -> State {
        try record(0x0123_4567)
        var state = State()
        for index in 0..<17 { state.registers[index] = try long() }
        state.sr = UInt16(truncatingIfNeeded: try long())
        state.pc = try long() &- 4
        state.prefetch = [UInt16(truncatingIfNeeded: try long()), UInt16(truncatingIfNeeded: try long())]
        for _ in 0..<(try long()) {
            let address = try long() & 0xFF_FFFF
            guard position + 2 <= data.count else { throw FormatError(description: "\(url.lastPathComponent) is truncated") }
            // A word of memory: high byte at the even address.
            state.ram.append((address, data[position + 1]))
            state.ram.append((address | 1, data[position]))
            position += 2
        }
        return state
    }
    guard try long() == 0x1A3F_5D71 else { throw FormatError(description: "\(url.lastPathComponent) is not a test file") }
    var tests: [Test] = []
    for _ in 0..<(try long()) {
        try record(0xABC1_2367)
        var test = Test()
        try record(0x89AB_CDEF)
        let length = Int(try long())
        guard position + length <= data.count else { throw FormatError(description: "\(url.lastPathComponent) is truncated") }
        test.name = String(decoding: data[position..<position + length], as: UTF8.self)
        position += length
        test.initial = try state()
        test.final = try state()
        try record(0x4567_89AB)
        test.length = Int(try long())
        for _ in 0..<(try long()) {
            guard position + 5 <= data.count else { throw FormatError(description: "\(url.lastPathComponent) is truncated") }
            let kind = data[position]
            position += 5 // kind and its length in clocks
            guard kind != 0 else { continue } // idle
            let function = try long(), address = try long()
            position += 12 // data bus, UDS, LDS
            if kind == 2 { test.reads.append((Int(function), Int(address))) }
        }
        tests.append(test)
    }
    return tests
}

struct Tally {
    var tests = 0
    var passed = 0
    var failed = 0
    /// Address-error tests: all, those matching exactly, and those matching outside the frame.
    var addressErrors = 0
    var addressErrorsExact = 0
    var addressErrorsState = 0
    /// Tests whose time in CPU clocks differs from the test's length: those without an
    /// address error, and those with one.
    var clocksWrong = 0
    var addressErrorClocksWrong = 0
    var examples: [String] = []

    static func + (a: Tally, b: Tally) -> Tally {
        Tally(tests: a.tests + b.tests, passed: a.passed + b.passed, failed: a.failed + b.failed,
              addressErrors: a.addressErrors + b.addressErrors, addressErrorsExact: a.addressErrorsExact + b.addressErrorsExact,
              addressErrorsState: a.addressErrorsState + b.addressErrorsState,
              clocksWrong: a.clocksWrong + b.clocksWrong,
              addressErrorClocksWrong: a.addressErrorClocksWrong + b.addressErrorClocksWrong, examples: [])
    }
}

func run(_ url: URL, show: Int, showFrames: Bool, showClocks: Bool, only: String?) throws -> Tally {
    var tally = Tally()
    var memory = Memory()
    let registerNames = (0..<8).map { "D\($0)" } + (0..<7).map { "A\($0)" } + ["USP", "SSP"]
    for test in try url.pathExtension == "bin" ? loadBinary(url) : loadJSON(url) {
        if let only, !test.name.contains(only) { continue }
        let initial = test.initial, final = test.final
        // Clear what the previous test left behind.
        for address in memory.written { memory.bytes[Int(address)] = 0 }
        memory.written.removeAll(keepingCapacity: true)

        var cpu = MC68000()
        cpu.statusRegister = initial.sr
        for index in 0..<8 { cpu[data: index] = initial.registers[index] }
        for index in 0..<7 { cpu[address: index] = initial.registers[8 + index] }
        cpu.userStackPointer = initial.registers[15]
        cpu.supervisorStackPointer = initial.registers[16]
        cpu.programCounter = initial.pc
        // The two prefetched words are the instruction's first two words.
        for (index, word) in initial.prefetch.enumerated() { try memory.writeWord(word, at: initial.pc &+ UInt32(index * 2)) }
        for (address, value) in initial.ram { try memory.writeByte(value, at: address) }
        let setUp = memory.written.count

        // For finding a test that crashes the core: the last name printed is the culprit.
        if ProcessInfo.processInfo.environment["M68K_NAMES"] != nil { FileHandle.standardError.write(Data((test.name + "\n").utf8)) }
        var differences: [String] = []
        var clocks = 0
        do { clocks = try cpu.step(memory: &memory) } catch { differences.append("threw \(error)") }

        let registers = (0..<8).map { cpu[data: $0] } + (0..<7).map { cpu[address: $0] } + [cpu.userStackPointer, cpu.supervisorStackPointer]
        for index in 0..<17 where registers[index] != final.registers[index] {
            differences.append(String(format: "%@=%08X not %08X", registerNames[index], registers[index], final.registers[index]))
        }
        if cpu.statusRegister != final.sr & 0xA71F {
            differences.append(String(format: "SR=%04X not %04X", cpu.statusRegister, final.sr))
        }
        if cpu.programCounter != final.pc { differences.append(String(format: "PC=%08X not %08X", cpu.programCounter, final.pc)) }

        // Memory: every listed byte, and no write to an unlisted one. The seven words of an
        // address-error frame are reported apart.
        // The 68000 took an address error if it read the vector at addresses 12 and 14 and then
        // fetched two words of the handler (an instruction that reads its operand there
        // fetches one word afterwards).
        let reads = test.reads
        var isAddressError = false
        if let vector = reads.indices.dropLast().last(where: { reads[$0].address == 12 && reads[$0 + 1].address == 14 }) {
            isAddressError = reads[(vector + 2)...].filter { $0.function == 6 }.count == 2
        }
        let frame = final.registers[16] & 0xFF_FFFF
        var frameDifferences: [String] = []
        var listed = Set<UInt32>()
        for (address, value) in final.ram {
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
        if clocks != test.length {
            if isAddressError { tally.addressErrorClocksWrong += 1 } else { tally.clocksWrong += 1 }
        }
        var all = differences + (isAddressError ? frameDifferences.map { "frame " + $0 } : [])
        if showClocks { all = clocks == test.length ? [] : ["\(clocks) clocks not \(test.length)"] }
        if !all.isEmpty, tally.examples.count < show, isAddressError == showFrames {
            tally.examples.append("    \(test.name)\(isAddressError ? " [address error]" : ""): " + all.prefix(8).joined(separator: ", "))
        }
    }
    return tally
}

var arguments = Array(CommandLine.arguments.dropFirst())
var show = 0
var only: String?
var showFrames = false
var showClocks = false
while let first = arguments.first, first.hasPrefix("--") {
    arguments.removeFirst()
    if first == "--show", let value = arguments.first.flatMap({ Int($0) }) { show = value; arguments.removeFirst() }
    else if first == "--only", !arguments.isEmpty { only = arguments.removeFirst() }
    else if first == "--address-errors" { showFrames = true }
    else if first == "--clocks" { showClocks = true }
    else { arguments = [] }
}
guard !arguments.isEmpty else {
    print("Usage: M68KSingleStep [--show N] [--address-errors] [--clocks] [--only TEXT] <folder | file.json[.gz] | file.json.bin>...")
    exit(2)
}
let suffixes = [".json", ".json.gz", ".json.bin"]
func label(_ file: URL) -> String {
    let name = file.lastPathComponent
    for suffix in suffixes.reversed() where name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
    return name
}
var files: [URL] = []
for argument in arguments {
    let url = URL(fileURLWithPath: argument)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
        files += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { file in suffixes.contains { file.lastPathComponent.hasSuffix($0) } }
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
nonisolated func runAll(_ list: [URL], show: Int, showFrames: Bool, showClocks: Bool, only: String?) -> Results {
    let results = Results()
    DispatchQueue.concurrentPerform(iterations: list.count) { index in
        results.set(index, Result { try run(list[index], show: show, showFrames: showFrames, showClocks: showClocks, only: only) })
    }
    return results
}
let results = runAll(files, show: show, showFrames: showFrames, showClocks: showClocks, only: only)
var total = Tally()
var unreadable = false
print("file                  tests  passed  failed | address errors: exact  state only  wrong | clocks wrong: plain  address errors")
for (index, file) in files.enumerated() {
    switch results.get(index) {
    case .success(let tally)?:
        total = total + tally
        let state = tally.addressErrorsState - tally.addressErrorsExact, wrong = tally.addressErrors - tally.addressErrorsState
        print(label(file).padding(toLength: 20, withPad: " ", startingAt: 0)
              + String(format: "%7d %7d %7d | %21d %11d %6d | %19d %15d", tally.tests, tally.passed, tally.failed,
                       tally.addressErrorsExact, state, wrong, tally.clocksWrong, tally.addressErrorClocksWrong))
        for example in tally.examples { print(example) }
    case .failure(let error)?:
        unreadable = true
        print("\(label(file)): \(error)")
    case nil: break
    }
}
print("total".padding(toLength: 20, withPad: " ", startingAt: 0)
      + String(format: "%7d %7d %7d | %21d %11d %6d | %19d %15d", total.tests, total.passed, total.failed,
               total.addressErrorsExact, total.addressErrorsState - total.addressErrorsExact,
               total.addressErrors - total.addressErrorsState, total.clocksWrong, total.addressErrorClocksWrong))
exit(!unreadable && total.failed == 0 && total.addressErrors == total.addressErrorsState ? 0 : 1)
