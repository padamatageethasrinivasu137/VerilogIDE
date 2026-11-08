import SwiftUI
import VerilogIDECore

enum BottomTab: String, CaseIterable, Identifiable {
    case terminal, problems, simulation, output, signals, synthesis, implementation, timing, hardware, history, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: return "Terminal"; case .problems: return "Problems"; case .simulation: return "Simulation"
        case .output: return "Output"; case .signals: return "Signals"; case .synthesis: return "Synthesis"
        case .implementation: return "Implementation"; case .timing: return "Timing"; case .hardware: return "Hardware"
        case .history: return "History"; case .search: return "Search"
        }
    }
    var icon: String {
        switch self {
        case .terminal: return "terminal"; case .problems: return "exclamationmark.triangle"; case .simulation: return "play.rectangle"
        case .output: return "text.alignleft"; case .signals: return "waveform"; case .synthesis: return "cpu"
        case .implementation: return "square.grid.3x3.topleft.filled"; case .timing: return "clock"; case .hardware: return "cable.connector"
        case .history: return "clock.arrow.circlepath"; case .search: return "magnifyingglass"
        }
    }
}

enum LogChannel: String { case sim, output, synthesis, implementation, bitstream, hardware }

struct JumpRequest: Equatable { let url: URL; let line: Int; let token = UUID() }

struct SearchHit: Identifiable { let id = UUID(); let url: URL; let line: Int; let text: String }

struct PromptRequest: Identifiable {
    let id = UUID()
    var title: String; var message: String = ""; var initial: String = ""; var confirmTitle = "OK"
    var handler: (String) -> Void
}

enum AppSheet: Identifiable {
    case newSimProject, newFPGAProject, fpgaSettings, pinPlanner, toolchain, noTestbench, programConfirm
    case testbenchChooser([TestbenchCandidate]), dumpMissing(String), prompt(PromptRequest)
    var id: String {
        switch self {
        case .newSimProject: return "newSim"; case .newFPGAProject: return "newFPGA"; case .fpgaSettings: return "fpgaSettings"
        case .pinPlanner: return "pins"; case .toolchain: return "tools"; case .noTestbench: return "noTB"; case .programConfirm: return "program"
        case .testbenchChooser: return "chooseTB"; case .dumpMissing(let n): return "dump-\(n)"; case .prompt(let p): return "prompt-\(p.id)"
        }
    }
}

struct AlertAction: Identifiable { let id = UUID(); var title: String; var role: ButtonRole? = nil; var handler: () -> Void = {} }
struct AppAlert: Identifiable { let id = UUID(); var title: String; var message: String; var actions: [AlertAction] = [] }

struct PaletteCommand: Identifiable { let id = UUID(); let title: String; let shortcut: String; let action: () -> Void }

final class EditorTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published var text: String { didSet { updateDirty() } }
    @Published var isDirty = false
    @Published var missingOnDisk = false
    var savedText: String
    let encoding: String.Encoding
    var diskDate: Date?
    init(url: URL, text: String, encoding: String.Encoding) {
        self.url = url; self.savedText = text; self.text = text; self.encoding = encoding
        diskDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
    func updateDirty() {
        let d = text.utf8.count != savedText.utf8.count || text != savedText
        if d != isDirty { isDirty = d }
    }
    var title: String { url.lastPathComponent }
}

final class FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }
    init(url: URL, isDirectory: Bool, children: [FileNode]?) { self.url = url; self.isDirectory = isDirectory; self.children = children }
    static func == (a: FileNode, b: FileNode) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }

    static func load(_ url: URL, depth: Int = 0) -> FileNode {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { return FileNode(url: url, isDirectory: false, children: nil) }
        guard depth < 8 else { return FileNode(url: url, isDirectory: true, children: []) }
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = items.map { load($0, depth: depth + 1) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return FileNode(url: url, isDirectory: true, children: nodes)
    }

    var icon: String {
        if isDirectory { return "folder" }
        let ext = url.pathExtension.lowercased()
        if TestbenchDetector.fileNameLooksLikeTestbench(name) && ["v", "sv"].contains(ext) { return "checkmark.seal" }
        switch ext {
        case "v": return "memorychip"; case "sv": return "memorychip.fill"; case "vh", "svh": return "doc.text"
        case "xdc", "sdc", "pcf", "lpf": return "pin"; case "vcd", "gtkw": return "waveform"
        case "md": return "doc.richtext"; case "bit", "bin": return "shippingbox"; case "json": return "curlybraces"
        default: return "doc"
        }
    }
}

extension UserDefaults {
    func str(_ k: String, _ d: String = "") -> String { string(forKey: k) ?? d }
    func flag(_ k: String, _ d: Bool) -> Bool { object(forKey: k) == nil ? d : bool(forKey: k) }
    func num(_ k: String, _ d: Double) -> Double { object(forKey: k) == nil ? d : double(forKey: k) }
}
