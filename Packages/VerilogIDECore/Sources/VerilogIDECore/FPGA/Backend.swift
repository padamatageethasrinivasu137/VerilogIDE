import Foundation

public enum FPGAStage: String, Codable, CaseIterable, Sendable, Identifiable {
    case synthesis, implementation, bitstream, program
    public var id: String { rawValue }
    public var title: String {
        switch self { case .synthesis: return "Synthesis"; case .implementation: return "Implementation"
                      case .bitstream: return "Bitstream"; case .program: return "Program" }
    }
    var order: Int { FPGAStage.allCases.firstIndex(of: self)! }
}

public struct BackendCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let synthesis = BackendCapabilities(rawValue: 1)
    public static let implementation = BackendCapabilities(rawValue: 2)
    public static let bitstream = BackendCapabilities(rawValue: 4)
    public static let programming = BackendCapabilities(rawValue: 8)
    public static let utilizationReports = BackendCapabilities(rawValue: 16)
    public static let timingReports = BackendCapabilities(rawValue: 32)
    public static let remoteExecution = BackendCapabilities(rawValue: 64)
    public func supports(_ stage: FPGAStage) -> Bool {
        switch stage {
        case .synthesis: return contains(.synthesis)
        case .implementation: return contains(.implementation)
        case .bitstream: return contains(.bitstream)
        case .program: return contains(.programming)
        }
    }
}

public struct RemoteConfig: Codable, Equatable, Sendable {
    public var host = ""
    public var user = ""
    public var port = 22
    public var identityFile = ""
    public var remoteDir = ""            // no whitespace; "~/" prefix allowed
    public var toolSetupScript = ""      // e.g. /tools/Xilinx/Vivado/2023.2/settings64.sh
    public var vivadoCommand = "vivado"
    public var approvedSourceSync = false
    public init() {}
    public var isComplete: Bool { !host.isEmpty && !remoteDir.isEmpty }
    public var target: String { user.isEmpty ? host : "\(user)@\(host)" }
}

public struct OpenSourceConfig: Codable, Equatable, Sendable {
    public var chipdbPath = ""
    public var prjxrayDBRoot = ""
    public var fasm2framesPath = ""
    public var frames2bitPath = ""
    public var xrayArch = "artix7"
    public init() {}
}

public struct ClockConstraint: Codable, Hashable, Sendable {
    public var port: String
    public var periodNs: Double
    public var name: String
    public init(port: String, periodNs: Double, name: String) { self.port = port; self.periodNs = periodNs; self.name = name }
}

public struct PinAssignment: Codable, Hashable, Identifiable, Sendable {
    public var id: String { port }
    public var port: String           // "led[0]" or "clk"
    public var pin: String
    public var ioStandard: String
    public init(port: String, pin: String, ioStandard: String) { self.port = port; self.pin = pin; self.ioStandard = ioStandard }
}

public struct FPGAProjectConfig: Codable, Equatable, Sendable {
    public var name: String
    public var part: String
    public var top: String
    public var language = "Verilog"
    public var backendID = "vivado-remote"
    public var programmerID = "openfpgaloader"     // or "vivado-hw"
    public var board = ""
    public var cable = ""
    public var constraintFiles: [String] = ["constraints/pins.xdc"]
    public var pinAssignments: [PinAssignment] = []
    public var clocks: [ClockConstraint] = []
    public var remote = RemoteConfig()
    public var openSource = OpenSourceConfig()

    public init(name: String, part: String, top: String) { self.name = name; self.part = part; self.top = top }

    enum CodingKeys: String, CodingKey { case name, part, top, language, backendID, programmerID, board, cable, constraintFiles, pinAssignments, clocks, remote, openSource }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        part = try c.decode(String.self, forKey: .part)
        top = try c.decode(String.self, forKey: .top)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "Verilog"
        backendID = try c.decodeIfPresent(String.self, forKey: .backendID) ?? "vivado-remote"
        programmerID = try c.decodeIfPresent(String.self, forKey: .programmerID) ?? "openfpgaloader"
        board = try c.decodeIfPresent(String.self, forKey: .board) ?? ""
        cable = try c.decodeIfPresent(String.self, forKey: .cable) ?? ""
        constraintFiles = try c.decodeIfPresent([String].self, forKey: .constraintFiles) ?? ["constraints/pins.xdc"]
        pinAssignments = try c.decodeIfPresent([PinAssignment].self, forKey: .pinAssignments) ?? []
        clocks = try c.decodeIfPresent([ClockConstraint].self, forKey: .clocks) ?? []
        remote = try c.decodeIfPresent(RemoteConfig.self, forKey: .remote) ?? RemoteConfig()
        openSource = try c.decodeIfPresent(OpenSourceConfig.self, forKey: .openSource) ?? OpenSourceConfig()
    }

    public static func configURL(_ root: URL) -> URL { root.appendingPathComponent(".fpga/project.json") }
    public static func load(from root: URL) -> FPGAProjectConfig? {
        guard let d = try? Data(contentsOf: configURL(root)) else { return nil }
        return try? JSONDecoder().decode(FPGAProjectConfig.self, from: d)
    }
    public func save(to root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".fpga"), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.configURL(root), options: .atomic)
    }
}

/// Per-device build directories so different parts never share artifacts.
public struct BuildLayout: Sendable {
    public let root: URL
    public let part: String
    public init(root: URL, part: String) { self.root = root.standardizedFileURL; self.part = part }
    public var buildDir: URL { root.appendingPathComponent("build/\(part)") }
    public var synthDir: URL { buildDir.appendingPathComponent("synthesis") }
    public var implDir: URL { buildDir.appendingPathComponent("implementation") }
    public var bitDir: URL { buildDir.appendingPathComponent("bitstream") }
    public var tclDir: URL { buildDir.appendingPathComponent("tcl") }
    public var reportsDir: URL { root.appendingPathComponent("reports/\(part)") }
    public var stateDir: URL { root.appendingPathComponent(".fpga/state/\(part)") }
    public func rel(_ u: URL) -> String { relativePath(u, to: root) }
    public func bitstreamURL(top: String) -> URL { bitDir.appendingPathComponent("\(top).bit") }
    public func ensureDirectories() throws {
        for d in [synthDir, implDir, bitDir, tclDir, reportsDir, stateDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

/// Marker-file based dependency tracking: a stage is only trusted if its marker is newer than all of its inputs.
public enum ArtifactTracker {
    static func marker(_ stage: FPGAStage, _ l: BuildLayout) -> URL { l.stateDir.appendingPathComponent("\(stage.rawValue).ok") }

    public static func markSuccess(_ stage: FPGAStage, layout: BuildLayout) {
        try? FileManager.default.createDirectory(at: layout.stateDir, withIntermediateDirectories: true)
        try? Date().description.write(to: marker(stage, layout), atomically: true, encoding: .utf8)
    }

    /// Deletes markers and artifacts of `stage` and every later stage, so stale outputs can never be reused.
    public static func invalidate(from stage: FPGAStage, layout: BuildLayout) {
        let fm = FileManager.default
        for s in FPGAStage.allCases where s.order >= stage.order {
            try? fm.removeItem(at: marker(s, layout))
            switch s {
            case .synthesis: clear(layout.synthDir); clearReports(layout, prefix: "synth_")
            case .implementation: clear(layout.implDir); clearReports(layout, prefix: "impl_")
            case .bitstream: clear(layout.bitDir)
            case .program: break
            }
        }
    }
    private static func clear(_ dir: URL) {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
    }
    private static func clearReports(_ l: BuildLayout, prefix: String) {
        for f in (try? FileManager.default.contentsOfDirectory(at: l.reportsDir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: f) }
    }

    /// Returns nil when `stage` may run; otherwise a human-readable reason.
    public static func blockingReason(for stage: FPGAStage, layout: BuildLayout, inputs: [URL]) -> String? {
        guard stage != .synthesis else { return nil }
        guard let prev = FPGAStage(rawValue: FPGAStage.allCases[stage.order - 1].rawValue) else { return nil }
        let m = marker(prev, layout)
        guard let mt = (try? FileManager.default.attributesOfItem(atPath: m.path))?[.modificationDate] as? Date else {
            return "\(prev.title) has not completed successfully. Run it first."
        }
        let newest = inputs.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
        if let newest, newest > mt { return "Sources or constraints changed after \(prev.title.lowercased()) ran. Re-run \(prev.title.lowercased())." }
        return nil
    }
}

public struct GeneratedFile: Sendable { public let url: URL; public let contents: String
    public init(url: URL, contents: String) { self.url = url; self.contents = contents } }

public struct BuildStep: Identifiable, Sendable {
    public let id = UUID()
    public var title: String
    public var executable: String
    public var arguments: [String]
    public var cwd: URL
    public var isRemote = false
    public var timeout: TimeInterval? = nil
    public var display: String { displayCommand(executable, arguments) }
}

public struct BuildPlan: Sendable {
    public var generated: [GeneratedFile] = []
    public var steps: [BuildStep] = []
    public var notes: [String] = []
}

public struct BackendStatus: Sendable {
    public var available: Bool
    public var messages: [String]
}

public enum FPGAError: LocalizedError {
    case unsupported(String), toolMissing(String), remoteNotConfigured, remoteNotApproved, invalid(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let m), .toolMissing(let m), .invalid(let m): return m
        case .remoteNotConfigured: return "Remote build host is not fully configured (host and remote directory are required)."
        case .remoteNotApproved: return "Sending sources to the remote host has not been approved yet."
        }
    }
}

public protocol FPGABackend: Sendable {
    var id: String { get }
    var displayName: String { get }
    var isExperimental: Bool { get }
    func detect(locator: ToolLocator, config: FPGAProjectConfig) -> BackendStatus
    func capabilities(config: FPGAProjectConfig) -> BackendCapabilities
    func supports(part: XilinxPart) -> Bool
    func plan(_ stage: FPGAStage, config: FPGAProjectConfig, layout: BuildLayout, sources: [URL], includeDirs: [URL],
              locator: ToolLocator) throws -> BuildPlan
    func collectReports(layout: BuildLayout) -> ReportBundle
}

public struct BackendRecommendation: Sendable { public var backendID: String?; public var explanation: String }

public enum BackendRegistry {
    public static let all: [any FPGABackend] = [VivadoBackend(mode: .local), VivadoBackend(mode: .remote), OpenSourceXilinxBackend()]
    public static func backend(id: String) -> (any FPGABackend)? { all.first { $0.id == id } }

    /// Picks a backend for the configured part from what is actually usable; never claims support it cannot back up.
    public static func recommend(config: FPGAProjectConfig, locator: ToolLocator) -> BackendRecommendation {
        guard let part = XilinxPart.parse(config.part) else {
            return BackendRecommendation(backendID: nil, explanation: "'\(config.part)' is not a recognizable Xilinx part number.")
        }
        var why: [String] = []
        for b in all {
            guard b.supports(part: part) else { why.append("\(b.displayName): does not support \(part.raw)."); continue }
            let st = b.detect(locator: locator, config: config)
            if st.available { return BackendRecommendation(backendID: b.id, explanation: "\(b.displayName) is available for \(part.raw).") }
            why.append("\(b.displayName): \(st.messages.joined(separator: " "))")
        }
        return BackendRecommendation(backendID: nil, explanation: why.joined(separator: "\n"))
    }
}
