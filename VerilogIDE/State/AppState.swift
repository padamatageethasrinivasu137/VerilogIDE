import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VerilogIDECore

@MainActor
final class AppState: ObservableObject {
    // Workspace
    @Published var roots: [URL] = []
    @Published var rootNodes: [FileNode] = []
    @Published var treeRevision = UUID()
    @Published var selection: URL?
    @Published var tabs: [EditorTab] = []
    @Published var activeTabID: UUID?
    @Published var recentProjects: [URL] = []
    @Published var columnVisibility: NavigationSplitViewVisibility = .automatic
    // UI
    @Published var showBottomPanel = false
    @Published var bottomTab: BottomTab = .terminal
    @Published var sheet: AppSheet?
    @Published var alert: AppAlert?
    @Published var showPalette = false
    @Published var jump: JumpRequest?
    // Run state
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var statusText = "Ready"
    @Published var diagnostics: [Diagnostic] = []
    @Published var logs: [LogChannel: [LogLine]] = [:]
    @Published var lastVCD: VCDInfo?
    @Published var selectedSignals: Set<String> = []
    @Published var signalOrder: [String] = []
    @Published var diagnosticHighlight: JumpRequest?
    // FPGA
    @Published var fpgaConfig: FPGAProjectConfig?
    @Published var resources: [ResourceEntry] = []
    @Published var timing: TimingSummary?
    @Published var drcLines: [String] = []
    @Published var detected: [DetectedDevice] = []
    @Published var usbDevices: [USBDevice] = []
    @Published var history: [BuildRecord] = []
    @Published var pinDB: PinDatabase?
    @Published var toolInfos: [ToolInfo] = []
    @Published var searchResults: [SearchHit] = []

    let terminals = TerminalManager()
    let simulation = SimulationManager()
    let waveform = WaveformManager()
    let locator = ToolLocator.shared
    var fpgaHandle: ProcessHandle?
    var cancelRequested = false
    private var observers: [NSObjectProtocol] = []

    init() {
        UserDefaults.standard.register(defaults: ["autoSaveBeforeRun": true, "autoLaunchGTKWave": true, "simTimeout": 60.0,
                                                  "waveformDir": "simulation", "editorFontSize": 13.0, "theme": "system"])
        applyToolSettings(); applyTheme()
        recentProjects = (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
        let saved = (UserDefaults.standard.stringArray(forKey: "workspaces") ?? []).map { URL(fileURLWithPath: $0) }
        for u in saved where FileManager.default.fileExists(atPath: u.path) { roots.append(u) }   // restore previous workspace
        refreshTrees(); refreshProject()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDiskChanges(); self?.refreshTrees() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        })
    }

    // MARK: Derived
    var activeTab: EditorTab? { tabs.first { $0.id == activeTabID } }
    var activeProjectRoot: URL? {
        let ref = (activeTab?.url ?? selection)?.standardizedFileURL.path
        if let ref, let r = roots.first(where: { ref == $0.standardizedFileURL.path || ref.hasPrefix($0.standardizedFileURL.path + "/") }) { return r }
        return roots.first ?? activeTab?.url.deletingLastPathComponent()
    }
    var windowTitle: String { activeProjectRoot?.lastPathComponent ?? "Verilog IDE" }
    var dirtyCount: Int { tabs.filter { $0.isDirty }.count }
    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }

    // MARK: Settings
    func applyTheme() {
        switch UserDefaults.standard.str("theme", "system") {
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        default: NSApp?.appearance = nil
        }
    }
    func applyToolSettings() {
        for t in Tool.allCases { locator.setOverride(UserDefaults.standard.string(forKey: "path.\(t.rawValue)"), for: t) }
    }
    func refreshTools() { Task { applyToolSettings(); locator.resetCache(); toolInfos = await locator.allInfo() } }
    func detectTools() {
        Task {
            locator.resetCache()
            for t in Tool.allCases {
                UserDefaults.standard.removeObject(forKey: "path.\(t.rawValue)"); locator.setOverride(nil, for: t)
                if let p = locator.locate(t) { UserDefaults.standard.set(p, forKey: "path.\(t.rawValue)") }
            }
            applyToolSettings()
            toolInfos = await locator.allInfo()
        }
    }

    // MARK: Workspace
    func showError(_ title: String, _ message: String) { alert = AppAlert(title: title, message: message) }

    func refreshTrees() {
        rootNodes = roots.map { FileNode.load($0) }
        treeRevision = UUID()
    }

    func refreshProject() {
        guard let root = activeProjectRoot else { fpgaConfig = nil; history = []; pinDB = nil; return }
        fpgaConfig = FPGAProjectConfig.load(from: root)
        history = BuildHistory.load(root)
        pinDB = fpgaConfig.flatMap { PinDatabase.load(root: root, part: $0.part) }
        if let cfg = fpgaConfig { reloadReports(root: root, cfg: cfg) } else { resources = []; timing = nil; drcLines = [] }
    }

    private func persistRoots() { UserDefaults.standard.set(roots.map { $0.path }, forKey: "workspaces") }

    func addRoot(_ url: URL) {
        let u = url.standardizedFileURL
        if !roots.contains(u) { roots.append(u) }
        recentProjects.removeAll { $0 == u }; recentProjects.insert(u, at: 0); recentProjects = Array(recentProjects.prefix(10))
        UserDefaults.standard.set(recentProjects.map { $0.path }, forKey: "recentProjects")
        persistRoots(); refreshTrees(); refreshProject()
    }

    func closeProject(_ root: URL) {
        for t in tabs where t.url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") { close(t, force: true) }
        roots.removeAll { $0 == root }
        persistRoots(); refreshTrees(); refreshProject()
    }

    func openFolderPanel() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.prompt = "Open Folder"; p.message = "Choose a project folder (existing structures are kept as they are)."
        if p.runModal() == .OK { p.urls.forEach(addRoot) }
    }
    func openFilePanel() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        p.allowedContentTypes = ["v", "sv", "vh", "svh", "xdc", "sdc", "md", "txt", "vcd"].compactMap { .init(filenameExtension: $0) }
        if p.runModal() == .OK { p.urls.forEach { openFile($0) } }
    }

    // MARK: Tabs
    func openFile(_ url: URL, line: Int? = nil) {
        let u = url.standardizedFileURL
        if let t = tabs.first(where: { $0.url.standardizedFileURL == u }) { activate(t) }
        else {
            guard let data = try? Data(contentsOf: u) else { showError("Cannot open file", "\(u.lastPathComponent) could not be read."); return }
            let enc: String.Encoding = String(data: data, encoding: .utf8) != nil ? .utf8 : .isoLatin1
            let text = String(data: data, encoding: enc) ?? ""
            let t = EditorTab(url: u, text: text, encoding: enc)
            tabs.append(t); activate(t)
        }
        if let line { jump = JumpRequest(url: u, line: line) }
    }

    func activate(_ t: EditorTab) {
        let before = activeProjectRoot
        activeTabID = t.id
        if activeProjectRoot != before { refreshProject() }
    }

    func save(_ t: EditorTab) {
        guard let data = t.text.data(using: t.encoding) else { showError("Save failed", "Text cannot be encoded as \(t.encoding)."); return }
        do {
            try data.write(to: t.url, options: .atomic)   // contents are written exactly as edited; nothing is reformatted
            t.savedText = t.text; t.updateDirty(); t.missingOnDisk = false
            t.diskDate = (try? FileManager.default.attributesOfItem(atPath: t.url.path))?[.modificationDate] as? Date
        } catch { showError("Save failed", error.localizedDescription) }
    }
    func saveActive() { if let t = activeTab { save(t) } }
    func saveAll() { tabs.filter { $0.isDirty }.forEach(save) }

    func close(_ t: EditorTab, force: Bool = false) {
        func finish() {
            guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
            tabs.remove(at: i)
            if activeTabID == t.id { activeTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
        }
        if t.isDirty && !force {
            alert = AppAlert(title: "Save changes to \(t.title)?", message: "Your changes will be lost if you don't save them.", actions: [
                AlertAction(title: "Save") { self.save(t); finish() },
                AlertAction(title: "Don't Save", role: .destructive) { finish() },
                AlertAction(title: "Cancel", role: .cancel)])
        } else { finish() }
    }
    func closeActive() { if let t = activeTab { close(t) } }

    func checkDiskChanges() {
        for t in tabs {
            guard let d = (try? FileManager.default.attributesOfItem(atPath: t.url.path))?[.modificationDate] as? Date else { t.missingOnDisk = true; continue }
            t.missingOnDisk = false
            if let old = t.diskDate, d > old, !t.isDirty, let data = try? Data(contentsOf: t.url), let s = String(data: data, encoding: t.encoding) {
                t.savedText = s; t.text = s; t.diskDate = d
            }
        }
    }

    func selectionChanged(_ url: URL) {
        var isDir: ObjCBool = false

        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDir
        ), !isDir.boolValue else {
            return
        }

        openFile(url)

        // Open Terminal in the directory containing the selected file.
        showTerminal(at: url.deletingLastPathComponent())
    }

    func navigate(to d: Diagnostic) {
        guard d.hasLocation else { return }
        let url = URL(fileURLWithPath: d.file).standardizedFileURL
        bottomTab = .problems
        showBottomPanel = true
        openFile(url, line: d.line)
        diagnosticHighlight = JumpRequest(url: url, line: d.line)
    }

    /// Removes generated simulation artifacts without touching source or project files.
    func cleanProjectArtifacts() {
        guard let root = activeProjectRoot?.standardizedFileURL else {
            statusText = "Clean failed: no active project folder"
            return
        }

        let fm = FileManager.default
        let buildSim = root.appendingPathComponent("build/sim", isDirectory: true)
        let waveformFolderName = UserDefaults.standard.str("waveformDir", "simulation")
        let waveformFolder = root.appendingPathComponent(waveformFolderName, isDirectory: true).standardizedFileURL
        let protectedNames: Set<String> = [".git", "Backups", "DerivedData", ".build", "node_modules"]
        var removed = 0
        var failures: [String] = []

        func removeItem(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            do {
                try fm.removeItem(at: url)
                removed += 1
                print("[Clean] Removed: \(url.path)")
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                print("[Clean] Failed: \(url.path): \(error)")
            }
        }

        print("[Clean] Project root: \(root.path)")

        // Icarus Verilog places compiled simulation output in build/sim/<run-id>/.
        // Remove this generated directory as a unit, including all .vvp files and run folders.
        removeItem(buildSim)

        // Remove waveform outputs from the configured waveform directory only.
        // Keep any unrelated files and all source/testbench files intact.
        if fm.fileExists(atPath: waveformFolder.path),
           let enumerator = fm.enumerator(
                at: waveformFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
           ) {
            var generated: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let name = url.lastPathComponent.lowercased()
                if ["vcd", "gtkw", "vvp"].contains(ext) || name.hasSuffix("_sim") {
                    generated.append(url)
                }
            }
            generated.forEach(removeItem)
        } else {
            print("[Clean] Waveform directory not found: \(waveformFolder.path)")
        }

        // Remove project-wide Finder metadata and root-level Icarus default output.
        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            var metadata: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true, protectedNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if name == ".DS_Store" {
                    metadata.append(url)
                }
            }
            metadata.forEach(removeItem)
        }

        removeItem(root.appendingPathComponent("a.out"))

        refreshTrees()
        if failures.isEmpty {
            statusText = "Cleaned \(removed) generated item(s) in \(root.lastPathComponent)"
        } else {
            statusText = "Cleaned \(removed); \(failures.count) item(s) could not be removed"
            showError("Clean incomplete", failures.joined(separator: "\n"))
        }
    }

    func moveSignal(from source: IndexSet, to destination: Int, in ordered: [VCDVariable]) {
        var ids = ordered.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        signalOrder = ids
        UserDefaults.standard.set(ids, forKey: "verilogIDE.signalOrder")
    }

    func clearHistory() {
        guard let root = activeProjectRoot else { history = []; return }
        BuildHistory.clear(root)
        history = []
    }

    // MARK: File operations
    func targetDirectory(for url: URL?) -> URL? {
        guard let url else { return activeProjectRoot }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue ? url : url.deletingLastPathComponent()
    }

    enum NewFileKind { case verilog, systemVerilog, testbench }
    func promptNewFile(_ kind: NewFileKind, in dir: URL? = nil) {
        guard let d = dir ?? targetDirectory(for: selection) else { showError("No folder", "Open a folder first."); return }
        let initial: String
        switch kind { case .verilog: initial = "module_name.v"; case .systemVerilog: initial = "module_name.sv"; case .testbench: initial = "module_name_tb.v" }
        sheet = .prompt(PromptRequest(title: "New \(kind == .testbench ? "Testbench" : kind == .systemVerilog ? "SystemVerilog File" : "Verilog File")",
                                      message: "Created in \(d.lastPathComponent)", initial: initial, confirmTitle: "Create") { name in
            let url = d.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { self.showError("Already exists", "\(name) already exists."); return }
            let base = ProjectTemplates.identifier((name as NSString).deletingPathExtension)
            let sv = url.pathExtension.lowercased() == "sv"
            var body: String
            switch kind {
            case .testbench:
                body = "`timescale 1ns/1ps\n\nmodule \(base);\n    initial begin\n        $dumpfile(\"waveform.vcd\");\n        $dumpvars(0, \(base));\n        // stimulus here\n        #100 $finish;\n    end\nendmodule\n"
            default: body = ProjectTemplates.moduleSkeleton(base, systemVerilog: sv)
            }
            do { try body.write(to: url, atomically: true, encoding: .utf8); self.refreshTrees(); self.openFile(url) }
            catch { self.showError("Could not create file", error.localizedDescription) }
        })
    }

    func promptNewFolder(in dir: URL? = nil) {
        guard let d = dir ?? targetDirectory(for: selection) else { return }
        sheet = .prompt(PromptRequest(title: "New Folder", message: "Created in \(d.lastPathComponent)", initial: "folder", confirmTitle: "Create") { name in
            do { try FileManager.default.createDirectory(at: d.appendingPathComponent(name), withIntermediateDirectories: false); self.refreshTrees() }
            catch { self.showError("Could not create folder", error.localizedDescription) }
        })
    }

    func promptRename(_ url: URL) {
        sheet = .prompt(PromptRequest(title: "Rename", initial: url.lastPathComponent, confirmTitle: "Rename") { name in
            let dest = url.deletingLastPathComponent().appendingPathComponent(name)
            self.relocate(url, to: dest)
        })
    }

    func relocate(_ src: URL, to dest: URL) {
        do {
            try FileManager.default.moveItem(at: src, to: dest)
            for t in tabs {
                let p = t.url.standardizedFileURL.path, s = src.standardizedFileURL.path
                if p == s { t.url = dest.standardizedFileURL }
                else if p.hasPrefix(s + "/") { t.url = URL(fileURLWithPath: dest.standardizedFileURL.path + p.dropFirst(s.count)) }
            }
            refreshTrees()
        } catch { showError("Could not move \(src.lastPathComponent)", error.localizedDescription) }
    }

    func move(_ urls: [URL], into dir: URL) {
        for u in urls where u.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL && u.standardizedFileURL != dir.standardizedFileURL {
            if dir.standardizedFileURL.path.hasPrefix(u.standardizedFileURL.path + "/") { continue }   // not into itself
            relocate(u, to: dir.appendingPathComponent(u.lastPathComponent))
        }
    }

    func duplicate(_ url: URL) {
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        var n = 1; var dest: URL
        repeat { dest = url.deletingLastPathComponent().appendingPathComponent("\(base) copy\(n > 1 ? " \(n)" : "")" + (ext.isEmpty ? "" : ".\(ext)")); n += 1 }
        while FileManager.default.fileExists(atPath: dest.path)
        do { try FileManager.default.copyItem(at: url, to: dest); refreshTrees() } catch { showError("Duplicate failed", error.localizedDescription) }
    }

    func confirmDelete(_ url: URL) {
        alert = AppAlert(title: "Move “\(url.lastPathComponent)” to the Trash?", message: "You can restore it from the Trash.", actions: [
            AlertAction(title: "Move to Trash", role: .destructive) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    for t in self.tabs where t.url.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path) { self.close(t, force: true) }
                    self.refreshTrees()
                } catch { self.showError("Delete failed", error.localizedDescription) }
            }, AlertAction(title: "Cancel", role: .cancel)])
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Search
    func searchProject(_ q: String) {
        guard !q.isEmpty, let root = activeProjectRoot else { searchResults = []; return }
        Task {
            let hits: [SearchHit] = await Task.detached {
                var out: [SearchHit] = []
                guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return out }
                while let u = en.nextObject() as? URL {
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    if v?.isDirectory == true { if ["build", "node_modules", ".build"].contains(u.lastPathComponent) { en.skipDescendants() }; continue }
                    guard (v?.fileSize ?? 0) < 2_000_000, let text = readTextFile(u) else { continue }
                    for (i, l) in text.components(separatedBy: "\n").enumerated() where l.localizedCaseInsensitiveContains(q) {
                        out.append(SearchHit(url: u, line: i + 1, text: l.trimmingCharacters(in: .whitespaces)))
                        if out.count >= 500 { return out }
                    }
                }
                return out
            }.value
            searchResults = hits
        }
    }

    // MARK: Command palette
    var paletteCommands: [PaletteCommand] {
        [PaletteCommand(title: "Run Simulation", shortcut: "⌘R") { self.runSimulation() },
         PaletteCommand(title: "Stop Process", shortcut: "⌘.") { self.stopProcess() },
         PaletteCommand(title: "Open Waveform", shortcut: "⇧⌘W") { self.openWaveform() },
         PaletteCommand(title: "Synthesize", shortcut: "⌥⌘1") { self.runFPGA(.synthesis) },
         PaletteCommand(title: "Implement", shortcut: "⌥⌘2") { self.runFPGA(.implementation) },
         PaletteCommand(title: "Generate Bitstream", shortcut: "⌥⌘3") { self.runFPGA(.bitstream) },
         PaletteCommand(title: "Program FPGA…", shortcut: "⌥⌘4") { self.runFPGA(.program) },
         PaletteCommand(title: "Clean Build", shortcut: "") { self.cleanBuild() },
         PaletteCommand(title: "Rebuild Project", shortcut: "") { self.rebuild() },
         PaletteCommand(title: "New Verilog File…", shortcut: "⌘N") { self.promptNewFile(.verilog) },
         PaletteCommand(title: "New Testbench…", shortcut: "") { self.promptNewFile(.testbench) },
         PaletteCommand(title: "Open Folder…", shortcut: "⇧⌘O") { self.openFolderPanel() },
         PaletteCommand(title: "New Project…", shortcut: "") { self.sheet = .newSimProject },
         PaletteCommand(title: "New FPGA Project…", shortcut: "") { self.sheet = .newFPGAProject },
         PaletteCommand(title: "FPGA Project Settings…", shortcut: "") { self.sheet = .fpgaSettings },
         PaletteCommand(title: "Pin Planner…", shortcut: "⇧⌘K") { self.sheet = .pinPlanner },
         PaletteCommand(title: "Toolchain Manager…", shortcut: "") { self.sheet = .toolchain },
         PaletteCommand(title: "Detect Hardware", shortcut: "") { self.detectHardware() },
         PaletteCommand(title: "New Terminal", shortcut: "⌃⇧`") { self.showTerminal(new: true) },
         PaletteCommand(title: "Toggle Bottom Panel", shortcut: "⌘J") { self.showBottomPanel.toggle() }]
    }

    func showTerminal(new: Bool = false, at dir: URL? = nil) {
        bottomTab = .terminal
        showBottomPanel = true
        guard new || terminals.groups.isEmpty else { return }

        let requested = (dir ?? activeProjectRoot ?? URL(fileURLWithPath: NSHomeDirectory())).standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory)
        let workingDirectory = exists && !isDirectory.boolValue
            ? requested.deletingLastPathComponent()
            : requested
        terminals.newTerminal(cwd: workingDirectory)
    }
}
