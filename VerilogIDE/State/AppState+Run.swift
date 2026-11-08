import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VerilogIDECore

// MARK: Logging
extension AppState {
    func log(_ ch: LogChannel, _ line: LogLine) {
        logs[ch, default: []].append(line)
        if logs[ch]!.count > 6000 { logs[ch]!.removeFirst(1000) }
    }
    func clearLog(_ ch: LogChannel) { logs[ch] = [] }

    func clearCurrentBottomTab() {
        switch bottomTab {
        case .terminal:
            if let id = terminals.activeGroup { terminals.clear(in: id) }
        case .problems: diagnostics.removeAll()
        case .simulation: clearLog(.sim)
        case .output: clearLog(.output)
        case .signals:
            selectedSignals = []
            lastVCD = nil
            signalOrder = []
        case .synthesis:
            clearLog(.synthesis)
            resources.removeAll { $0.stage == .synthesis }
        case .implementation:
            clearLog(.implementation)
            resources.removeAll { $0.stage == .implementation }
        case .timing: timing = nil
        case .hardware:
            clearLog(.hardware)
            detected = []
            usbDevices = []
        case .history: clearHistory()
        case .search: searchResults = []
        }
    }

    /// Thread-safe sink for process output; keeps partial lines until their newline arrives.
    func makeSink(_ ch: LogChannel) -> @Sendable (VerilogIDECore.OutputStream, String) -> Void {
        let carry = Locked<[String: String]>([:])
        return { [weak self] stream, text in
            var lines: [String] = []
            carry.with { c in
                var parts = ((c[stream.rawValue] ?? "") + text).components(separatedBy: "\n")
                c[stream.rawValue] = parts.removeLast()
                lines = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { for l in lines { self?.log(ch, LogLine(l, stream == .stderr ? .error : .output)) } } }
        }
    }

    func recordHistory(_ stage: String, started: Date, success: Bool, summary: String) {
        guard let root = activeProjectRoot else { return }
        BuildHistory.append(BuildRecord(stage: stage, started: started, duration: Date().timeIntervalSince(started), success: success, summary: summary), to: root)
        history = BuildHistory.load(root)
    }

    func stopProcess() {
        cancelRequested = true
        simulation.stop(); fpgaHandle?.terminate()
        statusText = "Stopping…"
    }
}

// MARK: Simulation
extension AppState {
    func simulationOptions() -> SimulationOptions {
        let d = UserDefaults.standard
        var o = SimulationOptions()
        o.timeoutSeconds = d.num("simTimeout", 60)
        o.waveformDir = d.str("waveformDir", "simulation")
        o.extraFlags = d.str("compilerFlags").split(whereSeparator: \.isWhitespace).map(String.init)
        return o
    }

    func runSimulation(choice: String? = nil, dumpPolicy: DumpPolicy = .ask) {
        guard !isBusy else { return }
        guard let root = activeProjectRoot else { showError("No project open", "Open a folder or create a project first."); return }
        isBusy = true; busyLabel = "Simulating"; cancelRequested = false; statusText = "Preparing simulation…"
        Task {
            defer { isBusy = false }
            if UserDefaults.standard.flag("autoSaveBeforeRun", true) { saveAll() }
            else if dirtyCount > 0 { log(.sim, LogLine("Unsaved editor changes are NOT part of this simulation.", .info)) }
            let index = await Task.detached { SourceIndex.build(root: root) }.value
            var opts = simulationOptions()
            let def = UserDefaults.standard.str("defaultTestbench")
            opts.testbenchModule = choice ?? (!def.isEmpty && index.module(named: def) != nil ? def : nil)
            opts.dumpPolicy = dumpPolicy
            do {
                let plan = try simulation.plan(index: index, projectRoot: root, options: opts)
                await executeSimulation(plan)
            } catch let e as SimulationError {
                statusText = "Ready"
                switch e {
                case .noTestbench: sheet = .noTestbench
                case .multipleTestbenches(let c): sheet = .testbenchChooser(c)
                case .waveformDumpMissing(let n): sheet = .dumpMissing(n)
                default: showError("Cannot run simulation", e.localizedDescription)
                }
            } catch { showError("Cannot run simulation", error.localizedDescription) }
        }
    }

    func executeSimulation(_ plan: SimulationPlan) async {
        let started = Date()
        clearLog(.sim)
        diagnostics.removeAll { $0.source == "iverilog" }
        bottomTab = .simulation; showBottomPanel = true
        statusText = "Simulating \(plan.testbench.name)…"
        let outcome = await simulation.execute(plan) { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(.sim, line) } }
        }
        diagnostics += outcome.diagnostics
        recordHistory("Simulation", started: started, success: outcome.success, summary: "\(plan.testbench.name): \(outcome.summary)")
        if !outcome.success {
            statusText = outcome.summary
            if outcome.diagnostics.contains(where: { $0.severity == .error }) { bottomTab = .problems }
            return
        }
        if outcome.failureMarkers > 0 { log(.sim, LogLine("Output contains \(outcome.failureMarkers) line(s) mentioning error/fail/assertion. Review the log.", .info)) }
        if let info = outcome.vcd {
            lastVCD = info
            let defaultsOrder = info.orderedVariables.map { $0.id }
            let savedOrder = UserDefaults.standard.stringArray(forKey: "verilogIDE.signalOrder") ?? []
            signalOrder = savedOrder.filter { defaultsOrder.contains($0) } + defaultsOrder.filter { !savedOrder.contains($0) }
            selectedSignals = Set(defaultsOrder)
            statusText = "Simulation finished — waveform ready"
            if UserDefaults.standard.flag("autoLaunchGTKWave", true) { openWaveform(vcdURL: info.url) }
        } else { statusText = outcome.vcdProblem ?? "Simulation finished (no waveform requested)" }
    }


    func openWaveform(vcdURL: URL? = nil) {
        Task {
            var url = vcdURL ?? lastVCD?.url

            if url == nil {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.init(filenameExtension: "vcd")!]
                panel.directoryURL = activeProjectRoot?.appendingPathComponent("simulation")

                guard panel.runModal() == .OK else {
                    return
                }

                url = panel.url
            }

            guard let url else {
                return
            }

            do {
                let info = try WaveformManager.inspect(url)

                if lastVCD?.url != url {
                    lastVCD = info

                    let defaultsOrder = info.orderedVariables.map { $0.id }
                    let savedOrder = UserDefaults.standard.stringArray(
                        forKey: "verilogIDE.signalOrder"
                    ) ?? []

                    signalOrder =
                        savedOrder.filter { defaultsOrder.contains($0) }
                        + defaultsOrder.filter { !savedOrder.contains($0) }

                    selectedSignals = Set(defaultsOrder)
                }

                let byID = Dictionary(
                    uniqueKeysWithValues: info.variables.map { ($0.id, $0) }
                )

                let ordered =
                    signalOrder.compactMap { byID[$0] }
                    + info.orderedVariables.filter {
                        !signalOrder.contains($0.id)
                    }

                let chosen = ordered.filter {
                    selectedSignals.contains($0.id)
                }

                let save = url.deletingLastPathComponent()
                    .appendingPathComponent(
                        url.deletingPathExtension().lastPathComponent + ".ide.gtkw"
                    )

                try WaveformManager.writeSaveFile(
                    vcd: url,
                    signals: Array(chosen.prefix(400)),
                    endTime: info.endTime,
                    to: save
                )

                try await waveform.launch(
                    vcd: url,
                    saveFile: save
                )

                log(
                    .sim,
                    LogLine(
                        "Opened \(url.lastPathComponent) in GTKWave with \(min(400, chosen.count)) ordered signals.",
                        .success
                    )
                )

            } catch {
                log(.sim, LogLine(error.localizedDescription, .error))
                bottomTab = .simulation
                showBottomPanel = true
            }
        }
    }


    func createTestbenchTemplate(for module: String) {
        guard let root = activeProjectRoot else { return }
        Task {
            let index = await Task.detached { SourceIndex.build(root: root) }.value
            guard let m = index.module(named: module) else { return }
            let dir = root.appendingPathComponent("testbench"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(module)_tb.v")
            guard !FileManager.default.fileExists(atPath: url.path) else { openFile(url); return }
            try? TestbenchTemplate.generate(for: m).write(to: url, atomically: true, encoding: .utf8)
            refreshTrees(); openFile(url)
        }
    }

    /// Modules that could get a template testbench (those that are not testbenches themselves).
    func designModules() async -> [VerilogModule] {
        guard let root = activeProjectRoot else { return [] }
        let index = await Task.detached { SourceIndex.build(root: root) }.value
        let tbs = Set(TestbenchDetector.candidates(in: index).map { $0.module.name })
        return index.allModuleNames.compactMap { index.module(named: $0) }.filter { !tbs.contains($0.name) }
    }
}

// MARK: FPGA flow
extension AppState {
    func updateConfig(_ c: FPGAProjectConfig) {
        fpgaConfig = c
        if let r = activeProjectRoot { try? c.save(to: r) }
    }

    func reloadReports(root: URL, cfg: FPGAProjectConfig) {
        guard let backend = BackendRegistry.backend(id: cfg.backendID) else { return }
        let b = backend.collectReports(layout: BuildLayout(root: root, part: cfg.part))
        resources = b.resources; timing = b.timing; drcLines = b.drcLines
    }

    func runSteps(_ plan: BuildPlan, channel: LogChannel) async -> (ok: Bool, output: String) {
        let fm = FileManager.default
        for g in plan.generated {
            try? fm.createDirectory(at: g.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? g.contents.write(to: g.url, atomically: true, encoding: .utf8)
        }
        for n in plan.notes { log(channel, LogLine("ℹ︎ \(n)", .info)) }
        let collected = Locked("")
        for step in plan.steps {
            if cancelRequested { log(channel, LogLine("Cancelled.", .error)); return (false, collected.get) }
            log(channel, LogLine("▸ \(step.title)", .info)); log(channel, LogLine("$ " + step.display, .command))
            let h = ProcessHandle(); fpgaHandle = h
            let sink = makeSink(channel)
            let r = await ProcessRunner.run(executable: step.executable, arguments: step.arguments, cwd: step.cwd, timeout: step.timeout, handle: h) { s, t in
                collected.with { $0 += t }; sink(s, t)
            }
            if !r.succeeded {
                log(channel, LogLine(r.cancelled ? "Cancelled." : r.timedOut ? "\(step.title) timed out." : "\(step.title) failed (exit \(r.exitCode)).", .error))
                return (false, collected.get)
            }
            log(channel, LogLine("✓ \(step.title) (\(String(format: "%.1f", r.duration)) s)", .success))
        }
        return (true, collected.get)
    }

    func channel(for s: FPGAStage) -> LogChannel {
        switch s { case .synthesis: return .synthesis; case .implementation: return .implementation; case .bitstream: return .bitstream; case .program: return .hardware }
    }

    func runFPGA(_ stage: FPGAStage) {
        guard !isBusy else { return }
        guard let cfg = fpgaConfig, activeProjectRoot != nil else {
            alert = AppAlert(title: "No FPGA project", message: "Create an FPGA project (or open a folder containing .fpga/project.json) first.",
                             actions: [AlertAction(title: "New FPGA Project…") { self.sheet = .newFPGAProject }, AlertAction(title: "Cancel", role: .cancel)]); return
        }
        if stage == .program { sheet = .programConfirm; return }
        if cfg.backendID == "vivado-remote", !cfg.remote.approvedSourceSync {
            guard cfg.remote.isComplete else { sheet = .fpgaSettings; showError("Remote build host not configured", "Enter the host and remote directory first."); return }
            alert = AppAlert(title: "Upload project sources to \(cfg.remote.target)?",
                             message: "Your HDL sources and constraints will be copied (rsync over SSH) to \(cfg.remote.remoteDir) on that machine. Nothing is sent without your approval.",
                             actions: [AlertAction(title: "Approve & Continue") { var c = cfg; c.remote.approvedSourceSync = true; self.updateConfig(c); self.runFPGA(stage) },
                                       AlertAction(title: "Cancel", role: .cancel)]); return
        }
        isBusy = true; busyLabel = stage.title; cancelRequested = false
        Task { defer { isBusy = false }; await performFPGA(stage, cfg) }
    }

    private func performFPGA(_ stage: FPGAStage, _ cfg: FPGAProjectConfig) async {
        guard let root = activeProjectRoot else { return }
        let started = Date(); let ch = channel(for: stage)
        func finish(_ ok: Bool, _ msg: String) {
            statusText = msg; recordHistory(stage.title, started: started, success: ok, summary: msg)
            if !ok { ArtifactTracker.invalidate(from: stage, layout: BuildLayout(root: root, part: cfg.part)) }
        }
        bottomTab = stage == .synthesis ? .synthesis : stage == .implementation ? .implementation : .output; showBottomPanel = true
        clearLog(ch); statusText = "\(stage.title)…"
        diagnostics.removeAll { ["vivado", "constraints", "fpga-check", "verilator"].contains($0.source) }
        if UserDefaults.standard.flag("autoSaveBeforeRun", true) { saveAll() }

        guard let part = XilinxPart.parse(cfg.part) else { showError("Invalid part", "'\(cfg.part)' is not a Xilinx part number (example: xc7a35tcpg236-1)."); finish(false, "Invalid part"); return }
        guard let backend = BackendRegistry.backend(id: cfg.backendID) else { showError("Unknown backend", cfg.backendID); finish(false, "Unknown backend"); return }
        guard backend.supports(part: part) else { showError("Unsupported device", "\(backend.displayName) does not support \(part.raw)."); finish(false, "Unsupported device"); return }
        guard backend.capabilities(config: cfg).supports(stage) else { showError("Not supported", "\(backend.displayName) cannot run \(stage.title.lowercased())."); finish(false, "Unsupported stage"); return }

        let index = await Task.detached { SourceIndex.build(root: root) }.value
        guard let top = index.module(named: cfg.top), let deps = index.dependencies(of: cfg.top) else {
            showError("Top module not found", "Module '\(cfg.top)' is not defined in any source file."); finish(false, "Top module missing"); return
        }
        let layout = BuildLayout(root: root, part: cfg.part)
        try? layout.ensureDirectories()
        let constraintURLs = cfg.constraintFiles.map { root.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        for w in deps.warnings { log(ch, LogLine("⚠︎ \(w)", .info)) }

        if let reason = ArtifactTracker.blockingReason(for: stage, layout: layout, inputs: deps.files + constraintURLs) {
            log(ch, LogLine(reason, .error)); showError("Cannot run \(stage.title.lowercased())", reason); finish(false, reason); return
        }

        // Pre-flight checks
        if stage == .synthesis {
            guard let iv = locator.locate(.iverilog) else { showError("iverilog missing", "A syntax/hierarchy check needs Icarus Verilog."); finish(false, "iverilog missing"); return }
            let rels = deps.files.map { relativePath($0, to: root) }
            let args = ["-g2012", "-t", "null", "-s", cfg.top] + deps.includeDirs.flatMap { ["-I", relativePath($0, to: root)] } + rels
            log(ch, LogLine("$ " + displayCommand(iv, args), .command))
            let r = await ProcessRunner.run(executable: iv, arguments: args, cwd: root, timeout: 60)
            let d = DiagnosticParser.parseIcarus(r.stderr + "\n" + r.stdout, baseDir: root).map { var x = $0; x.source = "fpga-check"; return x }
            diagnostics += d
            if !r.succeeded { bottomTab = .problems; log(ch, LogLine("HDL hierarchy/syntax check failed — synthesis not started.", .error)); finish(false, "HDL check failed"); return }
            log(ch, LogLine("✓ HDL syntax and hierarchy check passed", .success))
            if let vl = locator.locate(.verilator) {
                let vr = await ProcessRunner.run(executable: vl, arguments: ["--lint-only", "-Wall", "--top-module", cfg.top] + rels, cwd: root, timeout: 60)
                let vd = DiagnosticParser.parseVerilator(vr.stderr, baseDir: root); diagnostics += vd
                if !vd.isEmpty { log(ch, LogLine("Verilator reported \(vd.count) lint message(s); see Problems.", .info)) }
            }
        } else {
            let xdcPath = constraintURLs.first ?? root.appendingPathComponent(cfg.constraintFiles.first ?? "constraints/pins.xdc")
            let d = ConstraintCheck.validate(config: cfg, topPorts: top.ports, db: pinDB, constraintsURL: xdcPath)
            diagnostics += d
            if backend.id == "yosys-nextpnr-xilinx" {
                for c in constraintURLs { for u in XDC.unsupportedLines(readTextFile(c) ?? "", allowed: ["set_property"]) {
                    diagnostics.append(Diagnostic(file: c.path, line: u.line, severity: .warning, message: "Not applied by nextpnr-xilinx: \(u.text)", source: "constraints")) } }
            }
            if d.contains(where: { $0.severity == .error }) {
                bottomTab = .problems; log(ch, LogLine("Constraint validation failed — \(stage.title.lowercased()) not started.", .error)); finish(false, "Invalid constraints"); return
            }
            if constraintURLs.isEmpty { log(ch, LogLine("⚠︎ No constraint file found; timing and pins are unconstrained.", .info)) }
        }

        let plan: BuildPlan
        do { plan = try backend.plan(stage, config: cfg, layout: layout, sources: deps.files, includeDirs: deps.includeDirs, locator: locator) }
        catch { showError("Cannot plan \(stage.title.lowercased())", error.localizedDescription); log(ch, LogLine(error.localizedDescription, .error)); finish(false, error.localizedDescription); return }

        ArtifactTracker.invalidate(from: stage, layout: layout)   // never leave stale outputs behind
        let (ok, output) = await runSteps(plan, channel: ch)
        diagnostics += DiagnosticParser.parseVivado(output, baseDir: root)
        reloadReports(root: root, cfg: cfg)
        if ok {
            if stage == .bitstream {
                let bit = layout.bitstreamURL(top: cfg.top)
                let problems = BitstreamValidator.validate(bit, notOlderThan: started.addingTimeInterval(-1))
                if !problems.isEmpty { problems.forEach { log(ch, LogLine($0, .error)) }; finish(false, "Bitstream validation failed"); return }
                log(ch, LogLine("Bitstream: \(bit.path)", .success))
            }
            ArtifactTracker.markSuccess(stage, layout: layout)
            if stage == .implementation { bottomTab = .timing }
            finish(true, "\(stage.title) finished")
        } else {
            if diagnostics.contains(where: { $0.severity == .error && $0.source == "vivado" }) { bottomTab = .problems }
            finish(false, cancelRequested ? "Cancelled" : "\(stage.title) failed")
        }
    }

    func cleanBuild() {
        guard let root = activeProjectRoot, let cfg = fpgaConfig else { return }
        let l = BuildLayout(root: root, part: cfg.part)
        ArtifactTracker.invalidate(from: .synthesis, layout: l)
        try? FileManager.default.removeItem(at: l.tclDir)
        resources = []; timing = nil; drcLines = []; statusText = "Build directory for \(cfg.part) cleaned"
    }
    func rebuild() {
        cleanBuild()
        Task {
            for s in [FPGAStage.synthesis, .implementation, .bitstream] {
                while isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
                runFPGA(s)
                try? await Task.sleep(nanoseconds: 300_000_000)
                while isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard let root = activeProjectRoot, let cfg = fpgaConfig,
                      FileManager.default.fileExists(atPath: BuildLayout(root: root, part: cfg.part).stateDir.appendingPathComponent("\(s.rawValue).ok").path) else { return }
            }
        }
    }

    // MARK: Hardware / programming
    func detectHardware() {
        guard !isBusy else { return }
        bottomTab = .hardware; showBottomPanel = true
        Task {
            clearLog(.hardware); detected = []
            usbDevices = await HardwareManager.scanUSB()
            log(.hardware, LogLine("USB scan: \(usbDevices.count) device(s). A USB device alone does not prove an FPGA is reachable.", .info))
            guard let exe = locator.locate(.openFPGALoader) else {
                log(.hardware, LogLine("openFPGALoader is not installed (brew install openfpgaloader); JTAG detection is unavailable.", .error)); return
            }
            let cfg = fpgaConfig
            let args = HardwareManager.detectArguments(board: cfg?.board ?? "", cable: cfg?.cable ?? "")
            log(.hardware, LogLine("$ " + displayCommand(exe, args), .command))
            let r = await ProcessRunner.run(executable: exe, arguments: args, timeout: 30, onOutput: nil)
            (r.stdout + "\n" + r.stderr).split(whereSeparator: \.isNewline).forEach { log(.hardware, LogLine(String($0), .output)) }
            detected = HardwareManager.parseDetect(r.stdout + "\n" + r.stderr)
            log(.hardware, detected.isEmpty ? LogLine("No JTAG device was identified (no idcode reported).", .error)
                                            : LogLine("Identified \(detected.count) JTAG device(s).", .success))
        }
    }

    func program(flash: Bool) {
        guard !isBusy, let root = activeProjectRoot, let cfg = fpgaConfig, let part = XilinxPart.parse(cfg.part) else { return }
        isBusy = true; busyLabel = "Programming"; cancelRequested = false
        bottomTab = .hardware; showBottomPanel = true
        Task {
            defer { isBusy = false }
            let started = Date(); clearLog(.hardware)
            let layout = BuildLayout(root: root, part: cfg.part)
            @MainActor
            func fail(_ m: String) {
                log(.hardware, LogLine(m, .error))
                statusText = m
                recordHistory(
                    "Program",
                    started: started,
                    success: false,
                    summary: m
                )
            }
            if let reason = ArtifactTracker.blockingReason(for: .program, layout: layout, inputs: []) { fail(reason); return }
            let bit = layout.bitstreamURL(top: cfg.top)
            let problems = BitstreamValidator.validate(bit, notOlderThan: nil)
            if !problems.isEmpty { fail(problems.joined(separator: " ")); return }
            if cfg.programmerID == "vivado-hw" {
                guard let b = BackendRegistry.backend(id: cfg.backendID) else { fail("No backend"); return }
                if flash { fail("Flash programming is not offered through Vivado Hardware Manager here."); return }
                do {
                    let plan = try b.plan(.program, config: cfg, layout: layout, sources: [], includeDirs: [], locator: locator)
                    let (ok, _) = await runSteps(plan, channel: .hardware)
                    statusText = ok ? "Programmed \(part.raw)" : "Programming failed"; recordHistory("Program", started: started, success: ok, summary: statusText)
                } catch { fail(error.localizedDescription) }
                return
            }
            guard let exe = locator.locate(.openFPGALoader) else { fail("openFPGALoader is not installed."); return }
            let detectArgs = HardwareManager.detectArguments(board: cfg.board, cable: cfg.cable)
            log(.hardware, LogLine("$ " + displayCommand(exe, detectArgs), .command))
            let d = await ProcessRunner.run(executable: exe, arguments: detectArgs, timeout: 30)
            let devs = HardwareManager.parseDetect(d.stdout + "\n" + d.stderr)
            switch HardwareManager.verify(part: part, devices: devs) {
            case .mismatch(let m): fail("Target mismatch: \(m)"); return
            case .unknown(let m): if devs.isEmpty { fail(m + " Connect the board and check the cable/board selection."); return }; log(.hardware, LogLine("⚠︎ \(m)", .info))
            case .match(let m): log(.hardware, LogLine("✓ Device verified: \(m)", .success))
            }
            let args = HardwareManager.programArguments(board: cfg.board, cable: cfg.cable, bitstream: bit, flash: flash)
            log(.hardware, LogLine("$ " + displayCommand(exe, args), .command))
            let h = ProcessHandle(); fpgaHandle = h
            let r = await ProcessRunner.run(executable: exe, arguments: args, cwd: root, timeout: 300, handle: h, onOutput: makeSink(.hardware))
            let msg = r.succeeded ? "Programmed \(part.raw) (\(flash ? "flash" : "SRAM"))" : "Programming failed (exit \(r.exitCode))"
            log(.hardware, LogLine(msg, r.succeeded ? .success : .error)); statusText = msg
            recordHistory("Program", started: started, success: r.succeeded, summary: msg)
        }
    }

    // MARK: Pins & constraints
    func fetchPackagePins() {
        guard let root = activeProjectRoot, let cfg = fpgaConfig, let b = BackendRegistry.backend(id: cfg.backendID) as? VivadoBackend, !isBusy else {
            showError("Needs a Vivado backend", "Package pins are exported through Vivado (local or remote). Select a Vivado backend in FPGA settings."); return
        }
        if b.mode == .remote && !cfg.remote.approvedSourceSync { showError("Remote not approved", "Approve the remote host by running Synthesize once, or enable it in FPGA settings."); return }
        isBusy = true; busyLabel = "Exporting pins"; bottomTab = .output; showBottomPanel = true; cancelRequested = false
        Task {
            defer { isBusy = false }
            let layout = BuildLayout(root: root, part: cfg.part); try? layout.ensureDirectories()
            do {
                let (plan, _) = try b.planPinExport(config: cfg, layout: layout, locator: locator)
                let (ok, _) = await runSteps(plan, channel: .output)
                pinDB = PinDatabase.load(root: root, part: cfg.part)
                statusText = ok && pinDB != nil ? "Loaded \(pinDB!.pins.count) package pins" : "Pin export failed"
            } catch { showError("Pin export failed", error.localizedDescription) }
        }
    }

    func importBoardXDC() {
        guard let cfg = fpgaConfig else { return }
        let p = NSOpenPanel(); p.message = "Choose the board vendor's official XDC file"
        guard p.runModal() == .OK, let url = p.url, let text = readTextFile(url) else { return }
        let a = XDC.parseAssignments(text, includeCommented: true)
        guard !a.isEmpty else { showError("No pin assignments found", "That file contains no PACKAGE_PIN assignments."); return }
        var db = PinDatabase.fromBoardAssignments(a, part: cfg.part, fileName: url.lastPathComponent)
        if let existing = pinDB, case .vivadoExport = existing.source { db = existing }
        pinDB = db
        var c = cfg
        for x in a where !c.pinAssignments.contains(where: { $0.port == x.port }) { c.pinAssignments.append(x) }
        updateConfig(c)
        statusText = "Imported \(a.count) board pin definitions — review before use"
    }

    func exportXDC() {
        guard let root = activeProjectRoot, let cfg = fpgaConfig else { return }
        let rel = cfg.constraintFiles.first ?? "constraints/pins.xdc"
        let url = root.appendingPathComponent(rel)
        func write() {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try XDC.render(part: cfg.part, assignments: cfg.pinAssignments, clocks: cfg.clocks).write(to: url, atomically: true, encoding: .utf8)
                refreshTrees(); statusText = "Wrote \(rel)"
            } catch { showError("Could not write constraints", error.localizedDescription) }
        }
        if let existing = readTextFile(url), !existing.hasPrefix(XDC.generatedHeader), !existing.hasPrefix("## Pin assignments are generated"), !existing.isEmpty {
            alert = AppAlert(title: "Overwrite \(url.lastPathComponent)?", message: "This file was not generated by Verilog IDE and may contain hand-written constraints.",
                             actions: [AlertAction(title: "Overwrite", role: .destructive) { write() }, AlertAction(title: "Cancel", role: .cancel)])
        } else { write() }
    }

    func installTool(_ tool: Tool) {
        guard let f = tool.brewFormula, let brew = locator.locate(.brew) else { return }
        alert = AppAlert(title: "Install \(tool.displayName) with Homebrew?", message: "This runs `brew install \(f)`. Homebrew verifies package checksums.",
                         actions: [AlertAction(title: "Install") {
                            self.bottomTab = .output; self.showBottomPanel = true
                            Task { let r = await ProcessRunner.run(executable: brew, arguments: ["install", f], timeout: 1800, onOutput: self.makeSink(.output)); self.log(.output, LogLine(r.succeeded ? "Installed \(f)" : "brew install failed", r.succeeded ? .success : .error)); self.refreshTools() }
                         }, AlertAction(title: "Cancel", role: .cancel)])
    }
}
