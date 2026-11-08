import XCTest
@testable import VerilogIDECore

final class CoreTests: XCTestCase {
    let base = URL(fileURLWithPath: "/proj")

    func testIcarusDiagnostics() {
        let out = """
        src/mux2.v:9: syntax error
        src/mux2.v:8: error: Syntax error in continuous assignment
        testbench/mux2_tb.v:4: error: 'a' has already been declared in this scope.
        src/mux2.v:3:      : It was declared here as a net.
        /tmp/w.v:3: Include file nope.vh not found
        /tmp/u.v:5: warning: something odd
        """
        let d = DiagnosticParser.parseIcarus(out, baseDir: base)
        XCTAssertEqual(d.count, 6)
        XCTAssertEqual(d[0].file, "/proj/src/mux2.v"); XCTAssertEqual(d[0].line, 9); XCTAssertEqual(d[0].severity, .error)
        XCTAssertEqual(d[3].severity, .note)
        XCTAssertEqual(d[5].severity, .warning)
    }

    func testVivadoDiagnostics() {
        let d = DiagnosticParser.parseVivado("ERROR: [Synth 8-439] module 'x' not found [/p/src/a.v:12]\nWARNING: [Synth 8-3331] unused", baseDir: base)
        XCTAssertEqual(d.count, 2); XCTAssertEqual(d[0].line, 12); XCTAssertFalse(d[1].hasLocation)
    }

    func testParserAndTestbenchDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "module mux2(input wire a, input wire b, input wire sel, output wire y); assign y = sel ? b : a; endmodule"
            .write(to: dir.appendingPathComponent("src/mux2.v"), atomically: true, encoding: .utf8)
        try "module mux2_tb; reg a,b,sel; wire y; mux2 dut(.a(a),.b(b),.sel(sel),.y(y)); initial begin $dumpfile(\"w.vcd\"); $dumpvars(0, mux2_tb); #10 $finish; end endmodule"
            .write(to: dir.appendingPathComponent("src/mux2_tb.v"), atomically: true, encoding: .utf8)
        let idx = SourceIndex.build(root: dir)
        XCTAssertEqual(idx.module(named: "mux2")?.ports.map(\.name), ["a", "b", "sel", "y"])
        let c = TestbenchDetector.candidates(in: idx)
        XCTAssertEqual(c.map { $0.module.name }, ["mux2_tb"])
        XCTAssertEqual(idx.module(named: "mux2_tb")?.dumpfileName, "w.vcd")
        XCTAssertEqual(idx.dependencies(of: "mux2_tb")?.files.count, 2)
    }

    func testPartParsing() {
        XCTAssertEqual(XilinxPart.parse("XC7A35TCPG236-1")?.familyName, "Artix-7")
        XCTAssertEqual(XilinxPart.parse("xczu7ev-ffvc1156-2-e")?.familyName, "Zynq UltraScale+ MPSoC / RFSoC")
        XCTAssertTrue(XilinxPart.parse("xc6slx9-2csg324")?.isLegacyISE ?? false)
        XCTAssertNil(XilinxPart.parse("ti60f225"))
    }

    func testVivadoUtilization() {
        let rpt = """
        | Site Type             | Used | Fixed | Prohibited | Available | Util% |
        | Slice LUTs*           |   43 |     0 |          0 |     20800 |  0.21 |
        |   LUT as Logic        |   43 |     0 |          0 |     20800 |  0.21 |
        | Slice Registers       |   26 |     0 |          0 |     41600 |  0.06 |
        """
        let r = ReportParsers.vivadoUtilization(rpt, stage: .synthesis)
        XCTAssertEqual(r.map(\.name), ["Slice LUTs", "Slice Registers"]); XCTAssertEqual(r[0].used, 43); XCTAssertEqual(r[0].available, 20800)
    }

    func testTimingSummary() {
        let t = """
            WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints
            -------      -------  ---------------------  -------------------      -------      -------  ---------------------  -------------------
              7.512        0.000                      0                   26        0.151        0.000                      0                   26
        All user specified timing constraints are met.
        """
        let s = ReportParsers.vivadoTimingSummary(t)
        XCTAssertEqual(s.wns, 7.512); XCTAssertEqual(s.failingSetupEndpoints, 0); XCTAssertEqual(s.constraintsMet, true)
    }

    func testXDCRoundTripAndValidation() {
        let a = [PinAssignment(port: "led[0]", pin: "H17", ioStandard: "LVCMOS33")]
        let text = XDC.render(part: "xc7a35tcpg236-1", assignments: a, clocks: [ClockConstraint(port: "clk", periodNs: 10, name: "sys_clk")])
        XCTAssertEqual(XDC.parseAssignments(text, includeCommented: false), a)
        let ports = [VerilogPort(name: "led", direction: .output, range: "[3:0]", width: 4)]
        var cfg = FPGAProjectConfig(name: "p", part: "xc7a35tcpg236-1", top: "top"); cfg.pinAssignments = a + [PinAssignment(port: "led[1]", pin: "H17", ioStandard: "LVCMOS33")]
        let d = ConstraintCheck.validate(config: cfg, topPorts: ports, db: nil, constraintsURL: URL(fileURLWithPath: "/p.xdc"))
        XCTAssertTrue(d.contains { $0.message.contains("assigned to both") })
    }

    func testHardwareDetectNeedsIDCode() {
        let out = "index 0:\n\tidcode 0x362d093\n\tmanufacturer xilinx\n\tmodel  xc7a35\n"
        let devs = HardwareManager.parseDetect(out)
        XCTAssertEqual(devs.count, 1)
        XCTAssertEqual(HardwareManager.verify(part: XilinxPart.parse("xc7a35tcpg236-1")!, devices: devs), .match("xc7a35 (idcode 0x362d093)"))
        XCTAssertTrue(HardwareManager.parseDetect("Jtag frequency : requested 6.00MHz").isEmpty)
    }

    func testTestbenchTemplate() {
        let m = VerilogParser.parse(text: "module c(input clk, input rst_n, input [3:0] d, output reg [3:0] q); endmodule", url: base).modules[0]
        let t = TestbenchTemplate.generate(for: m)
        XCTAssertTrue(t.contains("$dumpvars(0, c_tb)")); XCTAssertTrue(t.contains("always #5 clk"))
    }
}
