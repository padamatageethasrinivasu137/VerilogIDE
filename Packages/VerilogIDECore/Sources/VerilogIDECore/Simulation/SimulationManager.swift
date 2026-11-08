import Foundation

public enum DumpPolicy: Sendable { case ask, generateWrapper, skip }

public struct SimulationOptions: Sendable {
    public var testbenchModule: String?
    public var languageStandard = "2012"
    public var includeDirs: [String] = []
    public var defines: [String] = []          // "NAME" or "NAME=VALUE"
    public var extraFlags: [String] = []
    public var timeoutSeconds: TimeInterval = 60
    public var dumpPolicy: DumpPolicy = .ask
    public var waveformDir = "simulation"      // relative to the project, or absolute
    public init() {}
}

public enum SimulationError: LocalizedError {
    case toolMissing(String)
    case noTestbench
    case multipleTestbenches([TestbenchCandidate])
    case testbenchNotFound(String)
    case waveformDumpMissing(String)
    case ioError(String)
    public var errorDescription: String? {
        switch self {
        case .toolMissing(let t): return "\(t) was not found. Install it (brew install icarus-verilog) or set its path in Settings ▸ Tools."
        case .noTestbench: return "No testbench found. Create or select a Verilog testbench before running the simulation."
        case .multipleTestbenches: return "Multiple testbenches found. Select the one to run."
        case .testbenchNotFound(let n): return "Testbench module '\(n)' was not found in the project."
        case .waveformDumpMissing(let n): return "Testbench '\(n)' does not call $dumpfile and $dumpvars, so no waveform will be produced."
        case .ioError(let m): return m
        }
    }
}

public struct LogLine: Identifiable, Sendable {
    public enum Kind: Sendable { case command, output, error, info, success }
    public let id = UUID()
    public let text: String
    public let kind: Kind
    public init(_ text: String, _ kind: Kind) { self.text = text; self.kind = kind }
}

public struct SimulationPlan: Sendable {
    public var projectRoot: URL
    public var testbench: VerilogModule
    public var sourceFiles: [URL]
    public var iverilog: String
    public var vvp: String
    public var buildDir: URL
    public var simulationDir: URL
    public var vvpFile: URL
    public var expectedVCD: URL?
    public var wrapperFile: URL?
    public var wrapperSource: String?
    public var compileArguments: [String]
    public var runArguments: [String]
    public var timeout: TimeInterval
    public var warnings: [String]
}

public struct SimulationOutcome: Sendable {
    public var success: Bool
    public var compileExitCode: Int32
    public var runExitCode: Int32?
    public var timedOut: Bool
    public var cancelled: Bool
    public var duration: TimeInterval
    public var diagnostics: [Diagnostic]
    public var vcd: VCDInfo?
    public var vcdProblem: String?
    public var failureMarkers: Int
    public var summary: String
}

public final class SimulationManager: @unchecked Sendable {
    private let locator: ToolLocator
    private let lock = NSLock()
    private var current: ProcessHandle?
    private var stopRequested = false
    public init(locator: ToolLocator = .shared) { self.locator = locator }

    // MARK: Planning (pure; no disk writes)

    public func plan(index: SourceIndex, projectRoot: URL, options: SimulationOptions) throws -> SimulationPlan {
        guard let iverilog = locator.locate(.iverilog) else { throw SimulationError.toolMissing("Icarus Verilog (iverilog)") }
        guard let vvp = locator.locate(.vvp) else { throw SimulationError.toolMissing("VVP (vvp)") }

        let candidates = TestbenchDetector.candidates(in: index)
        let tb: VerilogModule
        if let name = options.testbenchModule, !name.isEmpty {
            guard let m = index.module(named: name) else { throw SimulationError.testbenchNotFound(name) }
            tb = m
        } else if candidates.isEmpty { throw SimulationError.noTestbench }
        else if candidates.count > 1 { throw SimulationError.multipleTestbenches(candidates) }
        else { tb = candidates[0].module }

        guard let deps = index.dependencies(of: tb.name) else { throw SimulationError.testbenchNotFound(tb.name) }
        var warnings = deps.warnings

        let root = projectRoot.standardizedFileURL
        let simDir: URL = options.waveformDir.hasPrefix("/") ? URL(fileURLWithPath: options.waveformDir)
                                                              : root.appendingPathComponent(options.waveformDir)
        let stamp = Self.timestamp()
        let buildDir = root.appendingPathComponent("build/sim/\(stamp)")
        let vvpFile = buildDir.appendingPathComponent("simulation.vvp")

        // Waveform handling: never touch the user's testbench; use a generated wrapper when dumping is missing.
        var wrapperFile: URL?, wrapperSource: String?
        var expected: URL?
        let declaresDump = tb.hasDumpfile && tb.hasDumpvars
        func vcdPath(_ name: String) -> URL { name.hasPrefix("/") ? URL(fileURLWithPath: name) : simDir.appendingPathComponent(name) }
        if declaresDump { expected = vcdPath(tb.dumpfileName ?? "dump.vcd") }
        else {
            switch options.dumpPolicy {
            case .ask: throw SimulationError.waveformDumpMissing(tb.name)
            case .skip: warnings.append("No waveform will be generated (testbench has no $dumpfile/$dumpvars).")
            case .generateWrapper:
                let target = vcdPath(tb.dumpfileName ?? "waveform.vcd")
                expected = target
                wrapperFile = buildDir.appendingPathComponent("__ide_wave_dump.v")
                wrapperSource = """
                // Generated by Verilog IDE. Not part of your project; your testbench is unchanged.
                module __ide_wave_dump;
                  initial begin
                    $dumpfile("\(target.path)");
                    $dumpvars(0, \(tb.name));
                  end
                endmodule

                """
                warnings.append("Waveform dumping is injected through a generated wrapper module.")
            }
        }

        var args = ["-g\(options.languageStandard)", "-s", tb.name]
        if wrapperFile != nil { args += ["-s", "__ide_wave_dump"] }
        args += ["-o", vvpFile.path]
        var inc: [String] = deps.includeDirs.map { relativePath($0, to: root) }
        inc += options.includeDirs
        var seen = Set<String>()
        for d in inc where seen.insert(d).inserted { args += ["-I", d] }
        for d in options.defines { args += ["-D", d] }
        args += options.extraFlags
        if let w = wrapperFile { args.append(w.path) }
        args += deps.files.map { relativePath($0, to: root) }

        return SimulationPlan(projectRoot: root, testbench: tb, sourceFiles: deps.files, iverilog: iverilog, vvp: vvp,
                              buildDir: buildDir, simulationDir: simDir, vvpFile: vvpFile, expectedVCD: expected,
                              wrapperFile: wrapperFile, wrapperSource: wrapperSource, compileArguments: args,
                              runArguments: ["-n", vvpFile.path], timeout: options.timeoutSeconds, warnings: warnings)
    }

    static func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    // MARK: Execution

    public func stop() {
        lock.lock(); stopRequested = true; let h = current; lock.unlock()
        h?.terminate()
    }
    private func setCurrent(_ h: ProcessHandle?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        current = h
        return stopRequested
    }

    public func execute(_ plan: SimulationPlan, onLog: @escaping @Sendable (LogLine) -> Void) async -> SimulationOutcome {
        lock.withLock {
            stopRequested = false
        }
        let start = Date()
        let fm = FileManager.default
        func fail(_ summary: String, compile: Int32 = 0, run: Int32? = nil, diags: [Diagnostic] = [],
                  timedOut: Bool = false, cancelled: Bool = false) -> SimulationOutcome {
            SimulationOutcome(success: false, compileExitCode: compile, runExitCode: run, timedOut: timedOut, cancelled: cancelled,
                              duration: Date().timeIntervalSince(start), diagnostics: diags, vcd: nil, vcdProblem: nil,
                              failureMarkers: 0, summary: summary)
        }
        do {
            try fm.createDirectory(at: plan.buildDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: plan.simulationDir, withIntermediateDirectories: true)
            if let w = plan.wrapperFile, let src = plan.wrapperSource { try src.write(to: w, atomically: true, encoding: .utf8) }
            // Stale-artifact guard: a previous VCD must never be mistaken for this run's output.
            if let v = plan.expectedVCD, fm.fileExists(atPath: v.path) { try fm.removeItem(at: v) }
        } catch { return fail("Could not prepare build directory: \(error.localizedDescription)") }

        for w in plan.warnings { onLog(LogLine("⚠︎ \(w)", .info)) }

        // 1. Compile
        onLog(LogLine("$ " + displayCommand(plan.iverilog, plan.compileArguments), .command))
        let ch = ProcessHandle()
        if setCurrent(ch) { return fail("Stopped.", cancelled: true) }
        let compile = await ProcessRunner.run(executable: plan.iverilog, arguments: plan.compileArguments, cwd: plan.projectRoot,
                                              timeout: 120, handle: ch) { stream, text in
            onLog(LogLine(text.trimmingCharacters(in: .newlines), stream == .stderr ? .error : .output))
        }
        let diags = DiagnosticParser.parseIcarus(compile.stderr + "\n" + compile.stdout, baseDir: plan.projectRoot)
        if compile.cancelled { return fail("Stopped.", compile: compile.exitCode, diags: diags, cancelled: true) }
        if compile.exitCode != 0 || !fm.fileExists(atPath: plan.vvpFile.path) {
            onLog(LogLine("Compilation failed (exit \(compile.exitCode)). GTKWave was not launched.", .error))
            return fail("Compilation failed", compile: compile.exitCode, diags: diags)
        }
        onLog(LogLine("Compiled in \(String(format: "%.2f", compile.duration)) s", .success))

        // 2. Run
        onLog(LogLine("$ " + displayCommand(plan.vvp, plan.runArguments) + "   (cwd: \(plan.simulationDir.path))", .command))
        let rh = ProcessHandle()
        if setCurrent(rh) { return fail("Stopped.", compile: 0, cancelled: true) }
        let markers = Locked(0)
        let run = await ProcessRunner.run(executable: plan.vvp, arguments: plan.runArguments, cwd: plan.simulationDir,
                                          timeout: plan.timeout, handle: rh) { stream, text in
            for line in text.split(whereSeparator: \.isNewline) {
                let s = String(line)
                if s.range(of: #"(?i)\b(error|fail(ed|ure)?|assertion)\b"#, options: .regularExpression) != nil { markers.with { $0 += 1 } }
                onLog(LogLine(s, stream == .stderr ? .error : .output))
            }
        }
        _ = setCurrent(nil)
        if run.cancelled { return fail("Stopped.", run: run.exitCode, diags: diags, cancelled: true) }
        if run.timedOut {
            onLog(LogLine("Simulation exceeded the \(Int(plan.timeout)) s timeout and was terminated. Does the testbench call $finish?", .error))
            return fail("Timed out after \(Int(plan.timeout)) s", run: run.exitCode, diags: diags, timedOut: true)
        }
        if run.exitCode != 0 {
            onLog(LogLine("vvp exited with status \(run.exitCode).", .error))
            return fail("Simulation failed (exit \(run.exitCode))", run: run.exitCode, diags: diags)
        }

        // 3. Waveform validation
        var info: VCDInfo?, problem: String?
        if let v = plan.expectedVCD {
            do {
                if let m = (try? fm.attributesOfItem(atPath: v.path))?[.modificationDate] as? Date, m < start.addingTimeInterval(-1) {
                    throw WaveformError.missing(v)   // older than this run ⇒ stale
                }
                info = try WaveformManager.inspect(v)
                onLog(LogLine("Waveform: \(v.path) (\(info!.variables.count) signals, \(info!.bytes) bytes)", .success))
            } catch { problem = error.localizedDescription; onLog(LogLine(problem!, .error)) }
        }
        Self.prune(buildRoot: plan.buildDir.deletingLastPathComponent(), keep: 5)
        let dur = Date().timeIntervalSince(start)
        onLog(LogLine("Simulation finished in \(String(format: "%.2f", dur)) s", .success))
        return SimulationOutcome(success: true, compileExitCode: 0, runExitCode: run.exitCode, timedOut: false, cancelled: false,
                                 duration: dur, diagnostics: diags, vcd: info, vcdProblem: problem, failureMarkers: markers.get,
                                 summary: "Simulation finished")
    }

    static func prune(buildRoot: URL, keep: Int) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: buildRoot, includingPropertiesForKeys: nil) else { return }
        for old in items.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
