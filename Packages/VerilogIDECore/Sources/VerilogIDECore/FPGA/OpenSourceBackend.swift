import Foundation

/// EXPERIMENTAL open-source flow: Yosys → nextpnr-xilinx → Project X-Ray (fasm2frames, xc7frames2bit).
/// It is only offered when the user has supplied a chipdb and X-Ray data for the part; nothing is assumed.
public struct OpenSourceXilinxBackend: FPGABackend {
    public init() {}
    public var id: String { "yosys-nextpnr-xilinx" }
    public var displayName: String { "Yosys + nextpnr-xilinx (experimental, 7-series)" }
    public var isExperimental: Bool { true }

    public func supports(part: XilinxPart) -> Bool { ["xc7a", "xc7z", "xc7k"].contains(part.familyPrefix ?? "") }

    public func detect(locator: ToolLocator, config: FPGAProjectConfig) -> BackendStatus {
        var m: [String] = []
        if locator.locate(.yosys) == nil { m.append("Yosys is not installed.") }
        if locator.locate(.nextpnrXilinx) == nil { m.append("nextpnr-xilinx is not installed.") }
        let o = config.openSource
        let fm = FileManager.default
        if o.chipdbPath.isEmpty || !fm.fileExists(atPath: o.chipdbPath) { m.append("No chipdb (.bin) configured for \(config.part).") }
        if o.prjxrayDBRoot.isEmpty || !fm.fileExists(atPath: o.prjxrayDBRoot) { m.append("Project X-Ray database root is not configured.") }
        if o.fasm2framesPath.isEmpty || o.frames2bitPath.isEmpty { m.append("fasm2frames.py / xc7frames2bit paths are not configured.") }
        return BackendStatus(available: m.isEmpty, messages: m)
    }

    public func capabilities(config: FPGAProjectConfig) -> BackendCapabilities { [.synthesis, .implementation, .bitstream, .utilizationReports, .timingReports] }

    public func plan(_ stage: FPGAStage, config: FPGAProjectConfig, layout: BuildLayout, sources: [URL], includeDirs: [URL],
                     locator: ToolLocator) throws -> BuildPlan {
        var plan = BuildPlan()
        let rel = layout.rel
        let json = rel(layout.synthDir) + "/\(config.top).json"
        let routed = rel(layout.implDir) + "/\(config.top)_routed.json"
        let fasm = rel(layout.implDir) + "/\(config.top).fasm"
        let frames = rel(layout.bitDir) + "/\(config.top).frames"
        switch stage {
        case .synthesis:
            guard let yosys = locator.locate(.yosys) else { throw FPGAError.toolMissing("Yosys is not installed (brew install yosys).") }
            var script = ""
            for s in sources where ["v", "sv"].contains(s.pathExtension.lowercased()) {
                script += "read_verilog \(s.pathExtension.lowercased() == "sv" ? "-sv " : "")\(rel(s))\n"
            }
            script += "synth_xilinx -flatten -abc9 -arch xc7 -top \(config.top)\nwrite_json \(json)\ntee -o \(rel(layout.reportsDir))/synth_yosys_stat.txt stat\n"
            let ys = layout.tclDir.appendingPathComponent("synth.ys")
            plan.generated.append(GeneratedFile(url: ys, contents: script))
            plan.steps = [BuildStep(title: "Yosys synthesis", executable: yosys,
                                    arguments: ["-l", rel(layout.reportsDir) + "/synth_yosys.log", "-s", rel(ys)], cwd: layout.root)]
        case .implementation:
            guard let npr = locator.locate(.nextpnrXilinx) else { throw FPGAError.toolMissing("nextpnr-xilinx is not installed.") }
            var args = ["--chipdb", config.openSource.chipdbPath, "--json", json, "--write", routed, "--fasm", fasm,
                        "--log", rel(layout.reportsDir) + "/impl_nextpnr.log"]
            for x in config.constraintFiles where FileManager.default.fileExists(atPath: layout.root.appendingPathComponent(x).path) { args += ["--xdc", x] }
            plan.steps = [BuildStep(title: "nextpnr-xilinx place & route", executable: npr, arguments: args, cwd: layout.root)]
            plan.notes.append("nextpnr-xilinx applies only a subset of XDC; unsupported lines are reported by the constraint check, not silently ignored.")
        case .bitstream:
            let o = config.openSource
            let db = o.prjxrayDBRoot + "/" + o.xrayArch
            plan.steps = [
                BuildStep(title: "fasm2frames", executable: "/usr/bin/env",
                          arguments: ["python3", o.fasm2framesPath, "--db-root", db, "--part", config.part, fasm, frames], cwd: layout.root),
                BuildStep(title: "xc7frames2bit", executable: o.frames2bitPath,
                          arguments: ["--part_file", "\(db)/\(config.part)/part.yaml", "--part_name", config.part,
                                      "--frm_file", frames, "--output_file", rel(layout.bitstreamURL(top: config.top))], cwd: layout.root),
            ]
        case .program:
            throw FPGAError.unsupported("Programming is handled by the programmer (openFPGALoader), not by this backend.")
        }
        return plan
    }

    public func collectReports(layout: BuildLayout) -> ReportBundle {
        var b = ReportBundle()
        if let t = readTextFile(layout.reportsDir.appendingPathComponent("synth_yosys_stat.txt")) { b.resources += ReportParsers.yosysStat(t) }
        if let t = readTextFile(layout.reportsDir.appendingPathComponent("impl_nextpnr.log")) {
            b.resources += ReportParsers.nextpnrUtilization(t)
            var s = TimingSummary()
            let clocks = ReportParsers.nextpnrClocks(t)
            s.clocks = clocks.compactMap { c in c.targetMHz.map { ClockInfo(name: c.name, periodNs: 1000 / $0, frequencyMHz: $0) } }
            s.constraintsMet = clocks.isEmpty ? nil : clocks.allSatisfy { $0.pass }
            if let f = clocks.first { s.criticalPath = CriticalPath(slackNs: nil, met: f.pass, source: nil, destination: nil, dataPathDelayNs: nil,
                                                                    rawText: clocks.map { "Max frequency for '\($0.name)': \($0.fmaxMHz) MHz (\($0.pass ? "PASS" : "FAIL"))" }.joined(separator: "\n")) }
            b.timing = s
        }
        b.reportFiles = ((try? FileManager.default.contentsOfDirectory(at: layout.reportsDir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        return b
    }
}
