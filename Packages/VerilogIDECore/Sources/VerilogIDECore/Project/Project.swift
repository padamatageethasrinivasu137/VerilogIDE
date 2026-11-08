import Foundation

public struct BuildRecord: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var stage: String
    public var started: Date
    public var duration: TimeInterval
    public var success: Bool
    public var summary: String
    public init(stage: String, started: Date, duration: TimeInterval, success: Bool, summary: String) {
        self.stage = stage; self.started = started; self.duration = duration; self.success = success; self.summary = summary
    }
}

public enum BuildHistory {
    static func url(_ root: URL) -> URL { root.appendingPathComponent(".fpga/history.json") }
    public static func load(_ root: URL) -> [BuildRecord] {
        guard let d = try? Data(contentsOf: url(root)) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([BuildRecord].self, from: d)) ?? []
    }
    public static func append(_ r: BuildRecord, to root: URL) {
        var all = load(root); all.insert(r, at: 0); all = Array(all.prefix(200))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(".fpga"), withIntermediateDirectories: true)
        try? enc.encode(all).write(to: url(root), options: .atomic)
    }
    public static func clear(_ root: URL) {
        try? Data("[]".utf8).write(to: url(root), options: .atomic)
    }
}

public enum ProjectTemplates {
    public static func identifier(_ s: String) -> String {
        var o = s.map { $0.isLetter || $0.isNumber || $0 == "_" ? String($0) : "_" }.joined()
        if o.isEmpty || o.first!.isNumber { o = "m_" + o }
        return o
    }

    private static func write(_ s: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func moduleSkeleton(_ name: String, systemVerilog: Bool = false) -> String {
        let t = systemVerilog ? "logic" : "wire"
        return "module \(name) (\n    input  \(t) a,\n    input  \(t) b,\n    output \(t) y\n);\n    assign y = a & b;\nendmodule\n"
    }

    public static func testbench(forSource text: String, url: URL) -> String? {
        VerilogParser.parse(text: text, url: url).modules.first.map { TestbenchTemplate.generate(for: $0) }
    }

    /// Creates `name/{src,testbench,simulation}` plus README. Existing folders are never forced into this layout.
    @discardableResult
    public static func createSimulationProject(name: String, in parent: URL) throws -> URL {
        let id = identifier(name)
        let root = parent.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "A folder named '\(name)' already exists."])
        }
        let src = moduleSkeleton(id)
        try write(src, root.appendingPathComponent("src/\(id).v"))
        try write(testbench(forSource: src, url: root.appendingPathComponent("src/\(id).v")) ?? "", root.appendingPathComponent("testbench/\(id)_tb.v"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("simulation"), withIntermediateDirectories: true)
        try write("# \(name)\n\nOpen this folder in Verilog IDE and press ⌘R to simulate.\n", root.appendingPathComponent("README.md"))
        return root
    }

    @discardableResult
    public static func createFPGAProject(config: FPGAProjectConfig, in parent: URL) throws -> URL {
        let root = parent.appendingPathComponent(config.name)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "A folder named '\(config.name)' already exists."])
        }
        let ext = config.language == "SystemVerilog" ? "sv" : "v"
        let top = """
        // Top-level module. Port names are placeholders; assign real pins in the Pin Planner.
        module \(config.top) (
            input  wire clk,
            input  wire rst_n,
            output wire [3:0] led
        );
            reg [25:0] counter;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) counter <= 26'd0;
                else        counter <= counter + 26'd1;
            end
            assign led = counter[25:22];
        endmodule

        """
        let topURL = root.appendingPathComponent("src/\(config.top).\(ext)")
        try write(top, topURL)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/modules"), withIntermediateDirectories: true)
        try write(testbench(forSource: top, url: topURL) ?? "", root.appendingPathComponent("testbench/\(config.top)_tb.\(ext)"))
        for d in ["simulation", "build", "reports", "constraints"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        try write("## Pin assignments are generated by the Pin Planner (⌘⇧K). Nothing here is a guess.\n", root.appendingPathComponent("constraints/pins.xdc"))
        try write("# \(config.name)\n\nTarget part: `\(config.part)`  \nTop module: `\(config.top)`\n", root.appendingPathComponent("README.md"))
        try config.save(to: root)
        return root
    }
}
