import SwiftUI
import AppKit
import VerilogIDECore

struct SheetRouter: View {
    @EnvironmentObject var app: AppState
    let sheet: AppSheet
    var body: some View {
        switch sheet {
        case .newSimProject: NewProjectSheet(fpga: false)
        case .newFPGAProject: NewProjectSheet(fpga: true)
        case .fpgaSettings: FPGASettingsSheet()
        case .pinPlanner: PinPlannerSheet()
        case .toolchain: ToolchainSheet()
        case .noTestbench: NoTestbenchSheet()
        case .programConfirm: ProgramConfirmSheet()
        case .testbenchChooser(let c): TestbenchChooserSheet(candidates: c)
        case .dumpMissing(let n): DumpMissingSheet(testbench: n)
        case .prompt(let p): PromptSheet(request: p)
        }
    }
}

struct SheetFrame<Content: View>: View {
    let title: String; var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary).font(.callout) }
            content
        }.padding(20).frame(minWidth: 460)
    }
}

struct PromptSheet: View {
    @EnvironmentObject var app: AppState
    let request: PromptRequest
    @State private var text = ""
    var body: some View {
        SheetFrame(title: request.title, subtitle: request.message.isEmpty ? nil : request.message) {
            TextField("Name", text: $text).textFieldStyle(.roundedBorder).onSubmit(go)
            HStack { Spacer(); Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(request.confirmTitle, action: go).keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.onAppear { text = request.initial }
    }
    func go() { let t = text.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }; app.sheet = nil; request.handler(t) }
}

struct NewProjectSheet: View {
    @EnvironmentObject var app: AppState
    let fpga: Bool
    @State private var name = "my_project"
    @State private var dir = URL(fileURLWithPath: UserDefaults.standard.str("defaultProjectDir", NSHomeDirectory() + "/Documents"))
    @State private var part = "xc7a35tcpg236-1"
    @State private var top = "top"
    @State private var language = "Verilog"
    @State private var backend = "vivado-remote"
    @State private var programmer = "openfpgaloader"
    var partInfo: XilinxPart? { XilinxPart.parse(part) }
    var body: some View {
        SheetFrame(title: fpga ? "New FPGA Project" : "New Project",
                   subtitle: fpga ? "Any AMD/Xilinx part works. The part number is validated by Vivado; nothing is assumed about your board." : "Creates src/, testbench/, simulation/ and a README.") {
            Form {
                TextField("Project name", text: $name)
                HStack { Text("Location"); Spacer(); Text(dir.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; if p.runModal() == .OK, let u = p.url { dir = u } } }
                if fpga {
                    Picker("Language", selection: $language) { Text("Verilog").tag("Verilog"); Text("SystemVerilog").tag("SystemVerilog") }
                    Text("Manufacturer: AMD / Xilinx").foregroundStyle(.secondary)
                    TextField("Part number", text: $part).help("Example: xc7a35tcpg236-1, xc7z020clg400-1, xcku040-ffva1156-2-e")
                    Text(partInfo == nil ? "Not a recognizable Xilinx part number." : (partInfo!.isLegacyISE ? "Legacy (ISE-era) family: not supported by Vivado." : "Family: \(partInfo!.familyName ?? "unrecognized prefix — Vivado will validate")"))
                        .font(.caption).foregroundStyle(partInfo == nil || partInfo!.isLegacyISE ? .red : .secondary)
                    TextField("Top-level module", text: $top)
                    Picker("Synthesis backend", selection: $backend) {
                        ForEach(BackendRegistry.all, id: \.id) { Text($0.displayName).tag($0.id) }
                    }
                    Picker("Programming backend", selection: $programmer) { Text("openFPGALoader").tag("openfpgaloader"); Text("Vivado Hardware Manager (remote)").tag("vivado-hw") }
                }
            }
            HStack { Spacer(); Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(name.isEmpty || (fpga && (partInfo == nil || top.isEmpty))) }
        }
    }
    func create() {
        do {
            let root: URL
            if fpga {
                var c = FPGAProjectConfig(name: name, part: part.lowercased(), top: ProjectTemplates.identifier(top))
                c.language = language; c.backendID = backend; c.programmerID = programmer
                root = try ProjectTemplates.createFPGAProject(config: c, in: dir)
            } else { root = try ProjectTemplates.createSimulationProject(name: name, in: dir) }
            app.sheet = nil; app.addRoot(root)
            if let f = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("src"), includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "v" || $0.pathExtension == "sv" }) { app.openFile(f) }
        } catch { app.showError("Could not create project", error.localizedDescription) }
    }
}

struct TestbenchChooserSheet: View {
    @EnvironmentObject var app: AppState
    let candidates: [TestbenchCandidate]
    var body: some View {
        SheetFrame(title: "Choose a Testbench", subtitle: "Several testbenches were found. Only the selected one (and the modules it uses) is compiled.") {
            List(candidates) { c in
                VStack(alignment: .leading) {
                    HStack { Text(c.module.name).font(.headline); Spacer(); Text("score \(c.score)").font(.caption).foregroundStyle(.secondary) }
                    Text(relativePath(c.module.file, to: app.activeProjectRoot ?? c.module.file.deletingLastPathComponent()) + " — " + c.reasons.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).onTapGesture { app.sheet = nil; app.runSimulation(choice: c.module.name) }
            }.frame(height: 220)
            HStack { Spacer(); Button("Cancel") { app.sheet = nil } }
        }
    }
}

struct DumpMissingSheet: View {
    @EnvironmentObject var app: AppState
    let testbench: String
    var body: some View {
        SheetFrame(title: "No waveform dump in “\(testbench)”",
                   subtitle: "The testbench does not call both $dumpfile and $dumpvars, so GTKWave would have nothing to show. Your testbench file will not be modified.") {
            Text("Choose how to proceed:").font(.callout)
            HStack {
                Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run without waveform") { app.sheet = nil; app.runSimulation(choice: testbench, dumpPolicy: .skip) }
                Button("Generate dump wrapper & run") { app.sheet = nil; app.runSimulation(choice: testbench, dumpPolicy: .generateWrapper) }.keyboardShortcut(.defaultAction)
            }
            Text("The wrapper is a separate generated module that dumps the whole testbench hierarchy ($dumpvars(0, \(testbench))).").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NoTestbenchSheet: View {
    @EnvironmentObject var app: AppState
    @State private var modules: [VerilogModule] = []
    @State private var chosen = ""
    var body: some View {
        SheetFrame(title: "No testbench found", subtitle: "Create or select a Verilog testbench before running the simulation.") {
            if modules.isEmpty { Text("No design modules were found in this project either.").font(.callout) }
            else {
                Picker("Create a template testbench for", selection: $chosen) { ForEach(modules, id: \.name) { Text($0.name).tag($0.name) } }
            }
            HStack { Spacer(); Button("Close") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Create Testbench Template") { app.sheet = nil; app.createTestbenchTemplate(for: chosen) }.disabled(chosen.isEmpty).keyboardShortcut(.defaultAction) }
        }.task { modules = await app.designModules(); chosen = modules.first?.name ?? "" }
    }
}

struct ProgramConfirmSheet: View {
    @EnvironmentObject var app: AppState
    @State private var flash = false
    @State private var confirmFlash = false
    var body: some View {
        let cfg = app.fpgaConfig
        SheetFrame(title: "Program FPGA", subtitle: "This sends the generated bitstream to hardware.") {
            if let cfg {
                Grid(alignment: .leading, verticalSpacing: 4) {
                    GridRow { Text("Part").foregroundStyle(.secondary); Text(cfg.part) }
                    GridRow { Text("Programmer").foregroundStyle(.secondary); Text(cfg.programmerID == "vivado-hw" ? "Vivado Hardware Manager" : "openFPGALoader") }
                    GridRow { Text("Board / cable").foregroundStyle(.secondary); Text(cfg.board.isEmpty ? (cfg.cable.isEmpty ? "auto" : cfg.cable) : cfg.board) }
                    GridRow { Text("Bitstream").foregroundStyle(.secondary); Text("build/\(cfg.part)/bitstream/\(cfg.top).bit") }
                }.font(.callout)
                Text("The device is identified over JTAG first. Programming is refused if no device is detected or if it does not match the part.").font(.caption).foregroundStyle(.secondary)
                if cfg.programmerID == "openfpgaloader" {
                    Toggle("Write to flash (persistent) instead of SRAM", isOn: $flash)
                    if flash { Label("Flash programming overwrites the board's stored configuration.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
                }
            }
            HStack { Spacer(); Button("Cancel") { app.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(flash ? "Program Flash…" : "Program (SRAM)") { if flash { confirmFlash = true } else { app.sheet = nil; app.program(flash: false) } }.keyboardShortcut(.defaultAction) }
        }
        .confirmationDialog("Overwrite flash?", isPresented: $confirmFlash) {
            Button("Overwrite Flash", role: .destructive) { app.sheet = nil; app.program(flash: true) }
        } message: { Text("This replaces the configuration stored in the board's flash memory.") }
    }
}

struct FPGASettingsSheet: View {
    @EnvironmentObject var app: AppState
    @State private var cfg = FPGAProjectConfig(name: "", part: "", top: "")
    @State private var loaded = false
    var body: some View {
        SheetFrame(title: "FPGA Project Settings", subtitle: "Stored in .fpga/project.json") {
            if !loaded { ProgressView() } else {
                ScrollView { Form {
                    Section("Device") {
                        TextField("Part number", text: $cfg.part)
                        TextField("Top-level module", text: $cfg.top)
                        Picker("Backend", selection: $cfg.backendID) { ForEach(BackendRegistry.all, id: \.id) { Text($0.displayName).tag($0.id) } }
                        let rec = BackendRegistry.recommend(config: cfg, locator: ToolLocator.shared)
                        Text(rec.backendID == nil ? "No backend is currently usable:\n" + rec.explanation : "Usable: " + (BackendRegistry.backend(id: rec.backendID!)?.displayName ?? "")).font(.caption).foregroundStyle(.secondary)
                        Picker("Programmer", selection: $cfg.programmerID) { Text("openFPGALoader").tag("openfpgaloader"); Text("Vivado Hardware Manager").tag("vivado-hw") }
                        TextField("openFPGALoader board (-b)", text: $cfg.board); TextField("openFPGALoader cable (-c)", text: $cfg.cable)
                    }
                    Section("Remote build host (SSH key/agent auth; BatchMode)") {
                        TextField("Host", text: $cfg.remote.host); TextField("User", text: $cfg.remote.user)
                        TextField("Port", value: $cfg.remote.port, format: .number)
                        TextField("Identity file (optional)", text: $cfg.remote.identityFile)
                        TextField("Remote directory (no spaces)", text: $cfg.remote.remoteDir)
                        TextField("Tool setup script (e.g. …/settings64.sh)", text: $cfg.remote.toolSetupScript)
                        TextField("Vivado command", text: $cfg.remote.vivadoCommand)
                        Toggle("I approve uploading sources and constraints to this host", isOn: $cfg.remote.approvedSourceSync)
                    }
                    Section("Open-source flow (experimental, 7-series)") {
                        TextField("nextpnr-xilinx chipdb (.bin)", text: $cfg.openSource.chipdbPath)
                        TextField("Project X-Ray database root", text: $cfg.openSource.prjxrayDBRoot)
                        TextField("X-Ray architecture dir (e.g. artix7)", text: $cfg.openSource.xrayArch)
                        TextField("fasm2frames.py path", text: $cfg.openSource.fasm2framesPath)
                        TextField("xc7frames2bit path", text: $cfg.openSource.frames2bitPath)
                    }
                }.formStyle(.grouped) }.frame(height: 440)
            }
            HStack { Spacer(); Button("Cancel") { app.sheet = nil }
                Button("Save") { cfg.part = cfg.part.lowercased(); app.updateConfig(cfg); app.pinDB = app.activeProjectRoot.flatMap { PinDatabase.load(root: $0, part: cfg.part) }; app.sheet = nil }.keyboardShortcut(.defaultAction).disabled(!loaded) }
        }.onAppear { if let c = app.fpgaConfig { cfg = c; loaded = true } else { app.sheet = .newFPGAProject } }
    }
}

struct PinPlannerSheet: View {
    @EnvironmentObject var app: AppState
    @State private var cfg = FPGAProjectConfig(name: "", part: "", top: "")
    @State private var rows: [(target: String, port: VerilogPort)] = []
    @State private var loaded = false
    private let standards = ["LVCMOS33", "LVCMOS25", "LVCMOS18", "LVCMOS15", "LVCMOS12", "LVTTL", "LVDS", "SSTL15", "SSTL135"]

    func idx(_ t: String) -> Int? { cfg.pinAssignments.firstIndex { $0.port == t } }
    func pin(_ t: String) -> Binding<String> {
        Binding(get: { idx(t).map { cfg.pinAssignments[$0].pin } ?? "" },
                set: { v in let u = v.uppercased(); if let i = idx(t) { cfg.pinAssignments[i].pin = u } else { cfg.pinAssignments.append(PinAssignment(port: t, pin: u, ioStandard: "LVCMOS33")) } })
    }
    func std(_ t: String) -> Binding<String> {
        Binding(get: { idx(t).map { cfg.pinAssignments[$0].ioStandard } ?? "LVCMOS33" },
                set: { v in if let i = idx(t) { cfg.pinAssignments[i].ioStandard = v } else { cfg.pinAssignments.append(PinAssignment(port: t, pin: "", ioStandard: v)) } })
    }
    func period(_ port: String) -> Binding<Double> {
        Binding(get: { cfg.clocks.first { $0.port == port }?.periodNs ?? 0 },
                set: { v in cfg.clocks.removeAll { $0.port == port }; if v > 0 { cfg.clocks.append(ClockConstraint(port: port, periodNs: v, name: "\(port)_clk")) } })
    }
    var body: some View {
        SheetFrame(title: "Pin Planner", subtitle: "Pins are validated against verified data only: Vivado's package-pin export for \(app.fpgaConfig?.part ?? "the part") or the board vendor's XDC. Nothing is guessed.") {
            if !loaded { ProgressView() } else {
                HStack {
                    Text(app.pinDB.map { "Verified pins: \($0.pins.count) (\($0.sourceDescription))" } ?? "No verified pin list loaded").font(.caption).foregroundStyle(app.pinDB == nil ? .orange : .secondary)
                    Spacer()
                    Button("Fetch Package Pins from Vivado") { app.updateConfig(cfg); app.sheet = nil; app.fetchPackagePins() }.controlSize(.small)
                    Button("Import Board XDC…") { app.updateConfig(cfg); app.importBoardXDC(); if let c = app.fpgaConfig { cfg = c } }.controlSize(.small)
                }
                List {
                    ForEach(rows, id: \.target) { r in
                        HStack {
                            Image(systemName: r.port.direction == .input ? "arrow.right.circle" : r.port.direction == .output ? "arrow.left.circle" : "arrow.left.arrow.right.circle").foregroundStyle(.secondary)
                            Text(r.target).font(.system(.body, design: .monospaced)).frame(width: 110, alignment: .leading)
                            TextField("Pin", text: pin(r.target)).frame(width: 70).textFieldStyle(.roundedBorder)
                            let p = pin(r.target).wrappedValue
                            if !p.isEmpty { if let db = app.pinDB { Image(systemName: db.pins[p] != nil ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(db.pins[p] != nil ? .green : .red) } else { Image(systemName: "questionmark.circle").foregroundStyle(.secondary) } }
                            Picker("", selection: std(r.target)) { ForEach(standards, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 110)
                            if r.port.isClockLike && r.port.direction == .input {
                                TextField("ns", value: period(r.target), format: .number).frame(width: 60).textFieldStyle(.roundedBorder).help("Clock period in ns → create_clock")
                            }
                            if r.port.isResetLike { Text("reset").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(height: 300)
                if rows.isEmpty { Text("Top module '\(cfg.top)' has no parsed ports.").font(.caption) }
            }
            HStack { Spacer(); Button("Close") { app.sheet = nil }
                Button("Save") { app.updateConfig(cfg); app.sheet = nil }
                Button("Save & Export XDC") { app.updateConfig(cfg); app.sheet = nil; app.exportXDC() }.keyboardShortcut(.defaultAction) }
        }
        .frame(minWidth: 640)
        .task {
            guard let c = app.fpgaConfig, let root = app.activeProjectRoot else { app.sheet = nil; return }
            cfg = c
            let idxs = await Task.detached { SourceIndex.build(root: root) }.value
            rows = XDC.expandPorts(idxs.module(named: c.top)?.ports ?? []); loaded = true
        }
    }
}

struct ToolchainSheet: View {
    @EnvironmentObject var app: AppState
    @State private var hashFile: URL?
    @State private var expected = ""
    @State private var hashResult = ""
    var body: some View {
        SheetFrame(title: "Toolchain Manager", subtitle: "Tools are detected from Homebrew paths, your login shell PATH and common Vivado locations. Nothing is installed without confirmation.") {
            List(app.toolInfos) { t in
                HStack(alignment: .top) {
                    Image(systemName: t.status == .installed ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(t.status == .installed ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.tool.displayName).fontWeight(.medium)
                        Text(t.path ?? hint(t.status)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let v = t.version { Text(v).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(t.status.label).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    if case .available = t.status { Button("Install…") { app.installTool(t.tool) }.controlSize(.small) }
                    Button("Choose…") { let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false
                        if p.runModal() == .OK, let u = p.url { UserDefaults.standard.set(u.path, forKey: "path.\(t.tool.rawValue)"); app.refreshTools() } }.controlSize(.small)
                }
            }.frame(height: 340)
            GroupBox("Verify a downloaded toolchain archive (SHA-256)") {
                HStack {
                    Button("Choose File…") { let p = NSOpenPanel(); if p.runModal() == .OK { hashFile = p.url } }
                    Text(hashFile?.lastPathComponent ?? "no file").foregroundStyle(.secondary).lineLimit(1)
                    TextField("expected SHA-256", text: $expected).textFieldStyle(.roundedBorder)
                    Button("Verify") { if let f = hashFile { Task.detached {
                        let r = (try? IntegrityChecker.sha256(of: f)) ?? "read error"
                        await MainActor.run { hashResult = r.lowercased() == expected.trimmingCharacters(in: .whitespaces).lowercased() ? "✓ checksum matches" : "✗ MISMATCH — computed \(r)" } } } }
                }
                if !hashResult.isEmpty { Text(hashResult).font(.caption).foregroundStyle(hashResult.hasPrefix("✓") ? .green : .red) }
            }
            HStack { Button("Detect Tools") { app.detectTools() }; Button("Refresh") { app.refreshTools() }; Spacer(); Button("Done") { app.sheet = nil }.keyboardShortcut(.defaultAction) }
        }.frame(minWidth: 680).onAppear { app.refreshTools() }
    }
    func hint(_ s: ToolStatus) -> String {
        switch s { case .installed: return ""; case .available(let c), .unsupportedLocally(let c), .missing(let c): return c }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("defaultProjectDir") private var projectDir = ""
    @AppStorage("waveformDir") private var waveformDir = "simulation"
    @AppStorage("editorFontName") private var fontName = ""
    @AppStorage("editorFontSize") private var fontSize = 13.0
    @AppStorage("theme") private var theme = "system"
    @AppStorage("autoSaveBeforeRun") private var autoSave = true
    @AppStorage("autoLaunchGTKWave") private var autoGTK = true
    @AppStorage("compilerFlags") private var flags = ""
    @AppStorage("defaultTestbench") private var defaultTB = ""
    @AppStorage("simTimeout") private var timeout = 60.0
    @AppStorage("path.iverilog") private var iv = ""
    @AppStorage("path.vvp") private var vvp = ""
    @AppStorage("path.gtkwave") private var gtk = ""

    var body: some View {
        TabView {
            Form {
                Picker("Theme", selection: $theme) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                TextField("Default project directory", text: $projectDir)
                Toggle("Save all files before running a simulation", isOn: $autoSave)
                Toggle("Open GTKWave automatically after a successful simulation", isOn: $autoGTK)
            }.tabItem { Label("General", systemImage: "gearshape") }
            Form {
                TextField("Editor font (blank = SF Mono)", text: $fontName)
                Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...28)
            }.tabItem { Label("Editor", systemImage: "textformat") }
            Form {
                TextField("iverilog path", text: $iv); TextField("vvp path", text: $vvp); TextField("GTKWave path", text: $gtk)
                Button("Detect Tools") { app.detectTools() }
                Button("Open Toolchain Manager…") { app.sheet = .toolchain }
            }.tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            Form {
                TextField("Default compiler flags (e.g. -Wall -DDEBUG=1 -Iinclude)", text: $flags)
                TextField("Default top-level testbench module", text: $defaultTB)
                TextField("Waveform output directory", text: $waveformDir)
                Stepper("Simulation timeout: \(Int(timeout)) s", value: $timeout, in: 5...3600, step: 5)
            }.tabItem { Label("Simulation", systemImage: "play.rectangle") }
        }
        .padding(20).frame(width: 560, height: 280)
        .onChange(of: iv) { _, _ in app.applyToolSettings() }
        .onChange(of: vvp) { _, _ in app.applyToolSettings() }
        .onChange(of: gtk) { _, _ in app.applyToolSettings() }
    }
}
