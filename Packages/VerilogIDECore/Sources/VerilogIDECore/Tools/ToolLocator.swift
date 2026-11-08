import Foundation

public enum Tool: String, CaseIterable, Codable, Sendable, Identifiable {
    case iverilog, vvp, gtkwave, yosys, nextpnrXilinx = "nextpnr-xilinx", openFPGALoader, verilator, vivado, ssh, rsync, brew
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iverilog: return "Icarus Verilog (iverilog)"
        case .vvp: return "VVP runtime (vvp)"
        case .gtkwave: return "GTKWave"
        case .yosys: return "Yosys"
        case .nextpnrXilinx: return "nextpnr-xilinx"
        case .openFPGALoader: return "openFPGALoader"
        case .verilator: return "Verilator"
        case .vivado: return "AMD Vivado"
        case .ssh: return "OpenSSH client"
        case .rsync: return "rsync"
        case .brew: return "Homebrew"
        }
    }

    public var versionArguments: [String] {
        switch self {
        case .iverilog, .vvp, .yosys: return ["-V"]
        case .openFPGALoader: return ["--Version"]
        case .vivado: return ["-version"]
        case .ssh: return ["-V"]
        default: return ["--version"]
        }
    }

    public var brewFormula: String? {
        switch self {
        case .iverilog, .vvp: return "icarus-verilog"
        case .yosys: return "yosys"
        case .verilator: return "verilator"
        case .openFPGALoader: return "openfpgaloader"
        default: return nil   // gtkwave / nextpnr-xilinx: no formula we rely on; see installHint
        }
    }

    public var installHint: String {
        switch self {
        case .iverilog, .vvp: return "brew install icarus-verilog"
        case .gtkwave: return "Install GTKWave (Homebrew or the official macOS build), then use Detect Tools or set the path manually."
        case .yosys: return "brew install yosys"
        case .verilator: return "brew install verilator"
        case .openFPGALoader: return "brew install openfpgaloader"
        case .nextpnrXilinx: return "Build from github.com/gatecat/nextpnr-xilinx (needs a chipdb and Project X-Ray data). Experimental."
        case .vivado: return "Vivado has no native macOS build. Use the Remote backend (Linux/Windows host or VM over SSH)."
        case .ssh, .rsync: return "Ships with macOS."
        case .brew: return "See https://brew.sh"
        }
    }
}

public enum ToolStatus: Equatable, Sendable {
    case installed
    case available(String)            // missing but installable with the given command
    case unsupportedLocally(String)   // cannot run natively on macOS
    case missing(String)              // missing, manual install
    public var label: String {
        switch self {
        case .installed: return "Installed"
        case .available: return "Available to install"
        case .unsupportedLocally: return "Not supported on macOS"
        case .missing: return "Missing"
        }
    }
}

public struct ToolInfo: Identifiable, Sendable {
    public var id: String { tool.rawValue }
    public let tool: Tool
    public let path: String?
    public let version: String?
    public let status: ToolStatus
}

/// Resolves executables without relying on the GUI app's PATH.
public final class ToolLocator: @unchecked Sendable {
    public static let shared = ToolLocator()
    private let lock = NSLock()
    private var overrides: [Tool: String] = [:]
    private var shellPathCache: [String]?
    public init() {}

    public func setOverride(_ path: String?, for tool: Tool) {
        lock.lock(); defer { lock.unlock() }
        if let p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { overrides[tool] = p }
        else { overrides.removeValue(forKey: tool) }
    }
    public func override(for tool: Tool) -> String? { lock.lock(); defer { lock.unlock() }; return overrides[tool] }
    public func resetCache() { lock.lock(); shellPathCache = nil; lock.unlock() }

    private static let fixedDirs = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
                                    "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    // GUI bundle layouts vary between GTKWave builds; these are probes, not guarantees.
    private static let bundleCandidates: [Tool: [String]] = [
        .gtkwave: ["/Applications/gtkwave.app/Contents/Resources/bin/gtkwave",
                   "/Applications/GTKWave.app/Contents/Resources/bin/gtkwave",
                   "/Applications/gtkwave.app/Contents/MacOS/gtkwave",
                   "/Applications/GTKWave.app/Contents/MacOS/gtkwave"]
    ]

    private static func vivadoBinDirs() -> [String] {
        let home = NSHomeDirectory()
        var out: [String] = []
        for base in ["/tools/Xilinx/Vivado", "/opt/Xilinx/Vivado", "/usr/local/Xilinx/Vivado", home + "/Xilinx/Vivado"] {
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: base) {
                out += versions.sorted(by: >).map { "\(base)/\($0)/bin" }
            }
        }
        return out
    }

    private func shellPath() -> [String] {
        lock.lock(); if let c = shellPathCache { lock.unlock(); return c }; lock.unlock()
        var result: [String] = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { p.terminate() } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                result = String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
            }
        } catch {}
        lock.lock(); shellPathCache = result; lock.unlock()
        return result
    }

    public func searchDirectories() -> [String] {
        var dirs = Self.fixedDirs + shellPath()
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += Self.vivadoBinDirs()
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isUsable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return path.hasSuffix(".app") }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public func locate(_ tool: Tool) -> String? {
        if let o = override(for: tool) { return Self.isUsable(o) ? o : nil }
        for d in searchDirectories() {
            let c = d + "/" + tool.rawValue
            if Self.isUsable(c) { return c }
        }
        for c in Self.bundleCandidates[tool] ?? [] where Self.isUsable(c) { return c }
        return nil
    }

    /// PATH value that includes every directory where we found tools, so child processes (iverilog → ivlpp/vvp) resolve helpers.
    public func enrichedPath(base: String?) -> String {
        var dirs = searchDirectories()
        dirs += (base ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    public func status(for tool: Tool) -> ToolStatus {
        if locate(tool) != nil { return .installed }
        if tool == .vivado { return .unsupportedLocally(tool.installHint) }
        if let f = tool.brewFormula, locate(.brew) != nil { return .available("brew install \(f)") }
        return .missing(tool.installHint)
    }

    public func info(for tool: Tool) async -> ToolInfo {
        let path = locate(tool)
        var version: String?
        if let path, !path.hasSuffix(".app") {
            let r = await ProcessRunner.run(executable: path, arguments: tool.versionArguments,
                                            timeout: tool == .vivado ? 40 : 8)
            let text = r.stdout.isEmpty ? r.stderr : r.stdout
            version = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        return ToolInfo(tool: tool, path: path, version: version, status: status(for: tool))
    }

    public func allInfo() async -> [ToolInfo] {
        var out: [ToolInfo] = []
        for t in Tool.allCases { out.append(await info(for: t)) }
        return out
    }
}
