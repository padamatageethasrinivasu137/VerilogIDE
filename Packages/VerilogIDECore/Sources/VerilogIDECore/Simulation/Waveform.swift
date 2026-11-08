import Foundation

public enum SignalKind: String, Sendable { case clock, reset, control, input, output, other }

public struct VCDVariable: Identifiable, Hashable, Sendable {
    public var id: String { fullName }
    public let name: String
    public let scopePath: [String]
    public let type: String
    public let width: Int
    public let rangeSuffix: String
    /// VCD identifier code. Different hierarchy paths can alias the same underlying signal.
    public let identifierCode: String

    public init(name: String, scopePath: [String], type: String, width: Int, rangeSuffix: String, identifierCode: String = "") {
        self.name = name
        self.scopePath = scopePath
        self.type = type
        self.width = width
        self.rangeSuffix = rangeSuffix
        self.identifierCode = identifierCode
    }

    public var fullName: String { (scopePath + [name]).joined(separator: ".") }
    /// Name as GTKWave expects it in a save file (vectors carry their bit range).
    public var gtkwaveName: String { fullName + (width > 1 ? (rangeSuffix.isEmpty ? "[\(width - 1):0]" : rangeSuffix) : "") }
    public var kind: SignalKind {
        let n = name.lowercased()
        if n.contains("clk") || n.contains("clock") { return .clock }
        if n.contains("rst") || n.contains("reset") { return .reset }
        if ["enable", "en", "load", "write", "read", "valid", "ready", "start", "done", "sel", "select", "clear"].contains(where: { n == $0 || n.hasPrefix($0 + "_") || n.hasSuffix("_" + $0) }) { return .control }
        // In a conventional Verilog testbench, driven reg/logic signals are
        // inputs to the DUT and observed wire/tri signals are DUT outputs.
        if type == "reg" || type == "logic" || type == "integer" { return .input }
        if type == "wire" || type == "tri" { return .output }
        return .other
    }
}

public struct VCDInfo: Sendable {
    public let url: URL
    public let bytes: Int
    public let timescale: String?
    public let variables: [VCDVariable]
    /// Last VCD timestamp, expressed in native VCD ticks.
    public let endTime: UInt64
    public var scopes: [String] { Array(Set(variables.map { $0.scopePath.joined(separator: ".") })).sorted() }

    /// One representative per VCD identifier. Different hierarchy paths can alias
    /// the same net; prefer the shallowest declaration (normally the testbench port).
    public var orderedVariables: [VCDVariable] {
        // The root VCD scope is the selected testbench. Prefer its declarations
        // over internal DUT declarations; port connections are not additional
        // user-facing testbench signals even when Icarus assigns them new VCD IDs.
        let testbenchSignals = variables.filter { $0.scopePath.count == 1 }
        let source = testbenchSignals.isEmpty ? variables : testbenchSignals

        var canonicalByCode: [String: VCDVariable] = [:]
        for variable in source {
            let key = variable.identifierCode.isEmpty ? "name:\(variable.fullName)" : "code:\(variable.identifierCode)"
            if let existing = canonicalByCode[key] {
                if variable.scopePath.count < existing.scopePath.count {
                    canonicalByCode[key] = variable
                }
            } else {
                canonicalByCode[key] = variable
            }
        }

        var emitted = Set<String>()
        let canonical = source.filter { variable in
            let key = variable.identifierCode.isEmpty ? "name:\(variable.fullName)" : "code:\(variable.identifierCode)"
            guard canonicalByCode[key]?.fullName == variable.fullName else { return false }
            return emitted.insert(key).inserted
        }

        let rank: [SignalKind: Int] = [.clock: 0, .reset: 1, .control: 2, .input: 3, .output: 4, .other: 5]
        return canonical.enumerated().filter { $0.element.kind != .other }.sorted {
            let a = rank[$0.element.kind, default: 5], b = rank[$1.element.kind, default: 5]
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
}

public enum WaveformError: LocalizedError {
    case missing(URL), empty(URL), notVCD(URL), noVariables(URL), noData(URL)
    case gtkwaveMissing, launchFailed(String)
    public var errorDescription: String? {
        switch self {
        case .missing(let u): return "Waveform file was not created: \(u.path)"
        case .empty(let u): return "Waveform file is empty: \(u.lastPathComponent)"
        case .notVCD(let u): return "\(u.lastPathComponent) is not a valid VCD file (no $enddefinitions section)."
        case .noVariables(let u): return "\(u.lastPathComponent) declares no signals. Check that $dumpvars names the testbench module."
        case .noData(let u): return "\(u.lastPathComponent) has a header but no value changes. The simulation may have ended at time 0."
        case .gtkwaveMissing: return "GTKWave is not installed or its path is not configured. The simulation itself succeeded; open the VCD later with Open Waveform."
        case .launchFailed(let m): return "GTKWave failed to launch: \(m)"
        }
    }
}

public final class WaveformManager: @unchecked Sendable {
    private let locator: ToolLocator
    private let lock = NSLock()
    private var launched: Process?
    public init(locator: ToolLocator = .shared) { self.locator = locator }

    /// Validates a VCD (exists, non-empty, has definitions and value changes) and reads its signal hierarchy.
    public static func inspect(_ url: URL) throws -> VCDInfo {
        guard FileManager.default.fileExists(atPath: url.path) else { throw WaveformError.missing(url) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
        guard size > 0 else { throw WaveformError.empty(url) }
        let fh = try FileHandle(forReadingFrom: url); defer { try? fh.close() }
        let chunk = try fh.read(upToCount: 8 * 1024 * 1024) ?? Data()
        let text = String(decoding: chunk, as: UTF8.self)
        guard let endDefs = text.range(of: "$enddefinitions") else { throw WaveformError.notVCD(url) }
        let tokens = text[..<endDefs.lowerBound].split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var scope: [String] = [], vars: [VCDVariable] = [], timescale: String?
        var i = 0
        func upToEnd(_ from: Int) -> ([String], Int) {
            var j = from, out: [String] = []
            while j < tokens.count, tokens[j] != "$end" { out.append(tokens[j]); j += 1 }
            return (out, j + 1)
        }
        while i < tokens.count {
            switch tokens[i] {
            case "$timescale": let (t, n) = upToEnd(i + 1); timescale = t.joined(); i = n
            case "$scope": let (t, n) = upToEnd(i + 1); if t.count >= 2 { scope.append(t[1]) }; i = n
            case "$upscope": let (_, n) = upToEnd(i + 1); if !scope.isEmpty { scope.removeLast() }; i = n
            case "$var":
                let (t, n) = upToEnd(i + 1)
                if t.count >= 4 {
                    vars.append(VCDVariable(name: t[3], scopePath: scope, type: t[0], width: Int(t[1]) ?? 1,
                                            rangeSuffix: t.count > 4 ? t[4] : "", identifierCode: t[2]))
                }
                i = n
            default: i += 1
            }
        }
        guard !vars.isEmpty else { throw WaveformError.noVariables(url) }
        let after = text[endDefs.upperBound...]
        guard after.contains("#") else { throw WaveformError.noData(url) }
        let endTime = try lastTimestamp(in: url)
        return VCDInfo(url: url, bytes: size, timescale: timescale, variables: vars, endTime: endTime)
    }

    /// Scans timestamp records without loading the complete value-change section into memory.
    private static func lastTimestamp(in url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var carry = ""
        var last: UInt64 = 0
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            let text = carry + String(decoding: data, as: UTF8.self)
            var lines = text.components(separatedBy: "\n")
            carry = lines.popLast() ?? ""
            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.first == "#", let tick = UInt64(line.dropFirst()) {
                    last = max(last, tick)
                }
            }
        }
        let finalLine = carry.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalLine.first == "#", let tick = UInt64(finalLine.dropFirst()) {
            last = max(last, tick)
        }
        guard last > 0 else { throw WaveformError.noData(url) }
        return last
    }

    /// Writes selected canonical signals and the complete native VCD time range.
    public static func writeSaveFile(vcd: URL, signals: [VCDVariable], endTime: UInt64, to url: URL) throws {
        let escapedPath = vcd.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var s = "[*]\n[*] Generated by Verilog IDE\n[*]\n[dumpfile] \"\(escapedPath)\"\n[timestart] 0\n[timeend] \(endTime)\n@28\n"
        for variable in signals {
            s += variable.gtkwaveName + "\n"
        }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Launches GTKWave with the generated save file and applies Zoom Full after the VCD is loaded.

    public func launch(vcd: URL, saveFile: URL?) async throws {
        guard let exe = locator.locate(.gtkwave) else {
            throw WaveformError.gtkwaveMissing
        }

        guard FileManager.default.fileExists(atPath: vcd.path) else {
            throw WaveformError.missing(vcd)
        }

        if let saveFile,
           !FileManager.default.fileExists(atPath: saveFile.path) {
            throw WaveformError.missing(saveFile)
        }

        let previous = lock.withLock {
            let previous = launched
            launched = nil
            return previous
        }

        if let previous, previous.isRunning {
            previous.terminate()
        }

        let process = Process()
        var arguments = [vcd.path]

        if let saveFile {
            arguments.append(saveFile.path)
        }

        if exe.hasSuffix(".app") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", exe, "--args"] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = arguments
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = locator.enrichedPath(base: environment["PATH"])
        process.environment = environment

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw WaveformError.launchFailed(error.localizedDescription)
        }

        // GTKWave may hand off its GUI and terminate the original
        // launcher process. Its exit status is not a reliable
        // indication of whether the GUI was opened successfully.
        try? await Task.sleep(nanoseconds: 300_000_000)

        lock.withLock {
            launched = process.isRunning ? process : nil
        }
    }

}
