import Foundation

public enum ReportStage: String, Sendable { case synthesis, implementation }

public struct ResourceEntry: Identifiable, Hashable, Sendable {
    public var id: String { "\(stage.rawValue)-\(name)" }
    public let name: String
    public let used: Int
    public let available: Int?
    public let percent: Double?
    public let stage: ReportStage
    /// Post-synthesis numbers are estimates; only post-route numbers are final.
    public var isEstimate: Bool { stage == .synthesis }
}

public struct ClockInfo: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let periodNs: Double
    public let frequencyMHz: Double
}

public struct CriticalPath: Sendable {
    public var slackNs: Double?
    public var met: Bool?
    public var source: String?
    public var destination: String?
    public var dataPathDelayNs: Double?
    public var rawText: String
}

public struct TimingSummary: Sendable {
    public var wns: Double?, tns: Double?, whs: Double?, ths: Double?
    public var failingSetupEndpoints: Int?, failingHoldEndpoints: Int?
    public var constraintsMet: Bool?
    public var clocks: [ClockInfo] = []
    public var criticalPath: CriticalPath?
    /// Derived: 1000 / (period − WNS) for a single clock. Not a tool-reported value.
    public var derivedFmaxMHz: Double? {
        guard clocks.count == 1, let w = wns else { return nil }
        let p = clocks[0].periodNs - w
        return p > 0 ? 1000 / p : nil
    }
}

public struct ReportBundle: Sendable {
    public var resources: [ResourceEntry] = []
    public var timing: TimingSummary?
    public var drcLines: [String] = []
    public var reportFiles: [URL] = []
}

public enum ReportParsers {
    /// Vivado `report_utilization` tables. Only top-level rows (not indented sub-rows) with numeric Used and Available.
    public static func vivadoUtilization(_ text: String, stage: ReportStage) -> [ResourceEntry] {
        var out: [ResourceEntry] = []
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            // cells: ["", name, used, fixed, (prohibited,) available, util%, ""]
            guard cells.count >= 6 else { continue }
            let rawName = cells[1]
            let lead = rawName.prefix { $0 == " " }.count
            let name = rawName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            guard lead <= 1, !name.isEmpty else { continue }
            let nums = cells[2..<(cells.count - 1)].map { $0.trimmingCharacters(in: .whitespaces) }
            guard let usedS = nums.first, let used = Int(usedS), nums.count >= 3 else { continue }
            let availS = nums[nums.count - 2]
            guard let avail = Int(availS) else { continue }
            let pct = Double(nums[nums.count - 1]) ?? (avail > 0 ? Double(used) / Double(avail) * 100 : nil)
            out.append(ResourceEntry(name: name, used: used, available: avail, percent: pct, stage: stage))
        }
        return out
    }

    /// nextpnr: `Info:   SLICE_LUTX:   10/ 32600    0%`
    public static func nextpnrUtilization(_ text: String) -> [ResourceEntry] {
        regexMatches(#"Info:\s+(\w+):\s+(\d+)/\s*(\d+)\s+(\d+)%"#, in: text).compactMap { m in
            guard let u = Int(m[2]), let a = Int(m[3]), let p = Double(m[4]) else { return nil }
            return ResourceEntry(name: m[1], used: u, available: a, percent: p, stage: .implementation)
        }
    }

    /// nextpnr: `Info: Max frequency for clock 'clk': 123.45 MHz (PASS at 100.00 MHz)`
    public static func nextpnrClocks(_ text: String) -> [(name: String, fmaxMHz: Double, targetMHz: Double?, pass: Bool)] {
        regexMatches(#"Max frequency for clock\s+'([^']+)':\s*([\d.]+)\s*MHz\s*\((PASS|FAIL) at ([\d.]+) MHz\)"#, in: text).compactMap { m in
            guard let f = Double(m[2]) else { return nil }
            return (m[1], f, Double(m[4]), m[3] == "PASS")
        }
    }

    /// Yosys `stat` output: "   123 LUT6" style lines. Counts only; Yosys does not report device capacity.
    public static func yosysStat(_ text: String) -> [ResourceEntry] {
        regexMatches(#"^\s+(\d+)\s+(\w+)\s*$"#, in: text).compactMap { m in
            guard let n = Int(m[1]) else { return nil }
            return ResourceEntry(name: m[2], used: n, available: nil, percent: nil, stage: .synthesis)
        }
    }

    public static func vivadoTimingSummary(_ text: String) -> TimingSummary {
        var t = TimingSummary()
        let lines = text.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { $0.contains("WNS(ns)") && $0.contains("TNS(ns)") }) {
            for l in lines[(idx + 1)...] {
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "-" || $0 == " " }) { continue }
                let v = trimmed.split(whereSeparator: \.isWhitespace).map { Double($0) }
                if v.count >= 8 {
                    t.wns = v[0]; t.tns = v[1]; t.failingSetupEndpoints = v[2].map { Int($0) }
                    t.whs = v[4]; t.ths = v[5]; t.failingHoldEndpoints = v[6].map { Int($0) }
                }
                break
            }
        }
        if text.contains("All user specified timing constraints are met") { t.constraintsMet = true }
        else if text.contains("Timing constraints are not met") { t.constraintsMet = false }
        return t
    }

    /// `report_clocks` rows: `clk   {0.000 5.000}   10.000   100.000`
    public static func vivadoClocks(_ text: String) -> [ClockInfo] {
        regexMatches(#"^\s*(\S+)\s+\{[-\d.]+\s+[-\d.]+\}\s+([\d.]+)\s+([\d.]+)\s*$"#, in: text).compactMap { m in
            guard let p = Double(m[2]), let f = Double(m[3]) else { return nil }
            return ClockInfo(name: m[1], periodNs: p, frequencyMHz: f)
        }
    }

    public static func vivadoCriticalPath(_ text: String) -> CriticalPath? {
        guard text.contains("Slack") else { return nil }
        func first(_ p: String) -> String? { regexMatches(p, in: text).first?[1] }
        let slack = regexMatches(#"Slack \((MET|VIOLATED)\):\s+(-?[\d.]+)ns"#, in: text).first
        return CriticalPath(slackNs: slack.flatMap { Double($0[2]) }, met: slack.map { $0[1] == "MET" },
                            source: first(#"^\s*Source:\s+(.+)$"#), destination: first(#"^\s*Destination:\s+(.+)$"#),
                            dataPathDelayNs: first(#"Data Path Delay:\s+([\d.]+)ns"#).flatMap(Double.init), rawText: text)
    }
}
