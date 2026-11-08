import Foundation

public enum Severity: String, Codable, Sendable { case error, warning, note }

public struct Diagnostic: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(file):\(line):\(severity.rawValue):\(message)" }
    public var file: String        // absolute path, or "" when the tool gave no location
    public var line: Int           // 1-based, 0 when unknown
    public var column: Int?
    public var severity: Severity
    public var message: String
    public var source: String      // "iverilog", "verilator", "vivado", ...
    public init(file: String, line: Int, column: Int? = nil, severity: Severity, message: String, source: String) {
        self.file = file; self.line = line; self.column = column; self.severity = severity; self.message = message; self.source = source
    }
    public var hasLocation: Bool { !file.isEmpty && line > 0 }
}

public enum DiagnosticParser {
    private static func resolve(_ path: String, base: URL) -> String {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        return base.appendingPathComponent(path).standardizedFileURL.path
    }

    /// Icarus Verilog formats (verified against iverilog 12.0):
    ///   file.v:9: syntax error
    ///   file.v:8: error: Syntax error in continuous assignment
    ///   file.v:3:      : It was declared here as a net.          (continuation note)
    ///   file.v:3: Include file nope.vh not found
    ///   file.v:5: warning: ...
    public static func parseIcarus(_ output: String, baseDir: URL) -> [Diagnostic] {
        var result: [Diagnostic] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let s = String(raw)
            guard let m = regexMatches(#"^(.+?):(\d+):\s*(.*)$"#, in: s).first, let line = Int(m[2]) else { continue }
            var rest = m[3]
            var sev: Severity = .error
            if rest.hasPrefix("warning:") { sev = .warning; rest = String(rest.dropFirst(8)) }
            else if rest.hasPrefix("error:") { rest = String(rest.dropFirst(6)) }
            else if rest.hasPrefix("sorry:") { rest = "Unsupported: " + rest.dropFirst(6) }
            else if rest.hasPrefix("note:") { sev = .note; rest = String(rest.dropFirst(5)) }
            else if rest.hasPrefix(":") { sev = .note; rest = String(rest.dropFirst(1)) }
            result.append(Diagnostic(file: resolve(m[1], base: baseDir), line: line, severity: sev,
                                     message: rest.trimmingCharacters(in: .whitespaces), source: "iverilog"))
        }
        return result
    }

    /// `%Error: file.v:3:5: message` / `%Warning-UNUSED: file.v:3:5: message`
    public static func parseVerilator(_ output: String, baseDir: URL) -> [Diagnostic] {
        regexMatches(#"^%(Error|Warning)(?:-\w+)?:\s*(.+?):(\d+):(?:(\d+):)?\s*(.*)$"#, in: output).compactMap { m in
            guard let line = Int(m[3]) else { return nil }
            return Diagnostic(file: resolve(m[2], base: baseDir), line: line, column: Int(m[4]),
                              severity: m[1] == "Error" ? .error : .warning, message: m[5], source: "verilator")
        }
    }

    /// `ERROR: [Synth 8-439] module 'x' not found [/path/file.v:12]`
    public static func parseVivado(_ output: String, baseDir: URL) -> [Diagnostic] {
        regexMatches(#"^(ERROR|CRITICAL WARNING|WARNING):\s*\[([^\]]+)\]\s*(.*?)(?:\s*\[([^\]\s]+):(\d+)\])?\s*$"#, in: output).map { m in
            let sev: Severity = m[1] == "ERROR" ? .error : .warning
            let file = m[4].isEmpty ? "" : resolve(m[4], base: baseDir)
            return Diagnostic(file: file, line: Int(m[5]) ?? 0, severity: sev, message: "[\(m[2])] \(m[3])", source: "vivado")
        }
    }
}
