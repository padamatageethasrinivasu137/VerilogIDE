import Foundation

public struct TestbenchCandidate: Identifiable, Hashable, Sendable {
    public var id: String { "\(module.file.path)#\(module.name)" }
    public let module: VerilogModule
    public let score: Int
    public let reasons: [String]
}

public enum TestbenchDetector {
    public static func fileNameLooksLikeTestbench(_ fileName: String) -> Bool {
        let n = ((fileName as NSString).deletingPathExtension).lowercased()
        return n.hasSuffix("_tb") || n.hasSuffix("_test") || n.hasPrefix("tb_") || n.hasPrefix("test_") || n.hasSuffix("_testbench") || n == "tb"
    }

    /// Scores modules by content, not only by name: a module is a candidate if it is port-less, has `initial`
    /// blocks and instantiates project modules, or if its file name follows testbench conventions and it has `initial`.
    public static func candidates(in index: SourceIndex) -> [TestbenchCandidate] {
        var out: [TestbenchCandidate] = []
        for (_, f) in index.files where SourceIndex.compileExtensions.contains(f.url.pathExtension.lowercased()) {
            for m in f.modules {
                var score = 0; var reasons: [String] = []
                let nameMatch = fileNameLooksLikeTestbench(f.url.lastPathComponent) || fileNameLooksLikeTestbench(m.name + ".v")
                if nameMatch { score += 3; reasons.append("name follows testbench convention") }
                if m.hasInitial { score += 1; reasons.append("has initial block") }
                if m.ports.isEmpty { score += 1; reasons.append("no ports") }
                if !m.instantiated.isEmpty { score += 2; reasons.append("instantiates \(m.instantiated.joined(separator: ", "))") }
                if m.hasDumpfile { score += 1; reasons.append("calls $dumpfile") }
                if m.hasDumpvars { score += 1; reasons.append("calls $dumpvars") }
                if m.hasFinish { score += 1; reasons.append("calls $finish") }
                let contentMatch = m.hasInitial && !m.instantiated.isEmpty && m.ports.isEmpty
                let nameBased = nameMatch && m.hasInitial
                if contentMatch || nameBased { out.append(TestbenchCandidate(module: m, score: score, reasons: reasons)) }
            }
        }
        return out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.module.name < $1.module.name }
    }
}

public enum TestbenchTemplate {
    /// Generates a starter testbench for `module`. Clock/reset ports are driven, other inputs get random stimulus.
    public static func generate(for module: VerilogModule, dumpFile: String = "waveform.vcd") -> String {
        let tb = module.name + "_tb"
        func decl(_ p: VerilogPort, _ kind: String) -> String { "    \(kind) \(p.range.map { $0 + " " } ?? "")\(p.name);" }
        var s = "`timescale 1ns/1ps\n\nmodule \(tb);\n"
        for p in module.ports { s += decl(p, p.direction == .input ? "reg " : "wire") + "\n" }
        s += "    integer i;\n\n"
        s += "    \(module.name) dut (\n"
        s += module.ports.map { "        .\($0.name)(\($0.name))" }.joined(separator: ",\n") + "\n    );\n\n"
        let inputs = module.ports.filter { $0.direction == .input }
        let clocks = inputs.filter { $0.isClockLike }
        let resets = inputs.filter { $0.isResetLike && !$0.isClockLike }
        let data = inputs.filter { !$0.isClockLike && !$0.isResetLike }
        for c in clocks { s += "    initial \(c.name) = 0;\n    always #5 \(c.name) = ~\(c.name);   // 100 MHz at 1 ns timescale\n" }
        if !clocks.isEmpty { s += "\n" }
        s += "    initial begin\n        $dumpfile(\"\(dumpFile)\");\n        $dumpvars(0, \(tb));\n"
        for r in resets { s += "        \(r.name) = \(r.isActiveLowReset ? 0 : 1);\n" }
        for d in data { s += "        \(d.name) = 0;\n" }
        for r in resets { s += "        #20 \(r.name) = \(r.isActiveLowReset ? 1 : 0);\n" }
        s += "        for (i = 0; i < 32; i = i + 1) begin\n            #10;\n"
        for d in data { s += "            \(d.name) = $random;\n" }
        if data.isEmpty { s += "            // no data inputs: add stimulus here\n" }
        s += "        end\n        #20 $finish;\n    end\nendmodule\n"
        return s
    }
}
