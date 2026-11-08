import Foundation

public enum PortDirection: String, Codable, Sendable { case input, output, inOut = "inout" }

public struct VerilogPort: Hashable, Codable, Sendable {
    public var name: String
    public var direction: PortDirection
    public var range: String?        // e.g. "[7:0]" exactly as written
    public var width: Int?           // nil when the range is not a plain numeric range
    public var isClockLike: Bool { let n = name.lowercased(); return n.contains("clk") || n.contains("clock") }
    public var isResetLike: Bool { let n = name.lowercased(); return n.contains("rst") || n.contains("reset") }
    public var isActiveLowReset: Bool {
        let n = name.lowercased()
        return isResetLike && (n.hasSuffix("n") || n.hasSuffix("_b") || n.hasPrefix("n") || n.contains("_n"))
    }
    public init(name: String, direction: PortDirection, range: String?, width: Int?) {
        self.name = name; self.direction = direction; self.range = range; self.width = width
    }
}

public struct VerilogModule: Hashable, Sendable {
    public var name: String
    public var file: URL
    public var line: Int
    public var ports: [VerilogPort]
    public var body: String                 // comment-stripped text after the header
    public var hasInitial: Bool
    public var hasDumpfile: Bool
    public var hasDumpvars: Bool
    public var hasFinish: Bool
    public var dumpfileName: String?
    public var packageRefs: Set<String>
    public var instantiated: [String] = []  // project modules this module instantiates (filled by SourceIndex)
}

public struct ParsedFile: Sendable {
    public var url: URL
    public var modules: [VerilogModule]
    public var packages: [String]
    public var includes: [String]
}

public enum VerilogParser {
    /// Removes `//` and `/* */` comments while keeping newlines (so line numbers survive) and string literals.
    public static func stripComments(_ s: String) -> String {
        let b = Array(s.utf8); let n = b.count
        var out = [UInt8](); out.reserveCapacity(n)
        var i = 0
        while i < n {
            let c = b[i]
            if c == 0x22 { // string literal
                out.append(c); i += 1
                while i < n {
                    let d = b[i]; out.append(d); i += 1
                    if d == 0x5C, i < n { out.append(b[i]); i += 1 }
                    else if d == 0x22 || d == 0x0A { break }
                }
            } else if c == 0x2F, i + 1 < n, b[i + 1] == 0x2F {
                while i < n, b[i] != 0x0A { i += 1 }
            } else if c == 0x2F, i + 1 < n, b[i + 1] == 0x2A {
                i += 2
                while i < n {
                    if b[i] == 0x2A, i + 1 < n, b[i + 1] == 0x2F { i += 2; break }
                    if b[i] == 0x0A { out.append(0x0A) }
                    i += 1
                }
            } else { out.append(c); i += 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func skipBalanced(_ c: [Character], _ start: Int) -> Int {
        var depth = 0, i = start
        while i < c.count {
            if c[i] == "(" { depth += 1 } else if c[i] == ")" { depth -= 1; if depth == 0 { return i + 1 } }
            i += 1
        }
        return c.count
    }

    static func portListText(header: String) -> String? {
        let c = Array(header); var i = 0
        while i < c.count, c[i].isWhitespace { i += 1 }
        if i < c.count, c[i] == "#" {
            i += 1
            while i < c.count, c[i] != "(" { i += 1 }
            i = skipBalanced(c, i)
        }
        while i < c.count, c[i] != "(" { i += 1 }
        guard i < c.count else { return nil }
        let end = skipBalanced(c, i)
        guard end - 1 > i + 1 else { return "" }
        return String(c[(i + 1)..<(end - 1)])
    }

    static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = [], cur = "", depth = 0
        for ch in s {
            if "([{".contains(ch) { depth += 1 } else if ")]}".contains(ch) { depth -= 1 }
            if ch == "," && depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(cur) }
        return parts
    }

    static func width(of range: String?) -> Int? {
        guard let range, let m = regexMatches(#"\[\s*(-?\d+)\s*:\s*(-?\d+)\s*\]"#, in: range, options: []).first,
              let a = Int(m[1]), let b = Int(m[2]) else { return nil }
        return abs(a - b) + 1
    }

    static func parsePorts(header: String, body: String) -> [VerilogPort] {
        guard let list = portListText(header: header) else { return [] }
        let items = splitTopLevel(list).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let itemRe = #"^(?:(input|output|inout)\b\s*)?(?:(?:wire|reg|logic|var|tri|signed|unsigned)\b\s*)*(\[[^\]]*\])?\s*(?:(?:signed|unsigned)\s+)?([A-Za-z_][A-Za-z0-9_$]*)\s*(?:\[[^\]]*\])?\s*(?:=.*)?$"#
        var ports: [VerilogPort] = []
        var lastDir: PortDirection?, lastRange: String?
        var plainNames: [String] = []
        for item in items {
            guard let m = regexMatches(itemRe, in: item, options: []).first else { continue }
            if !m[1].isEmpty {
                lastDir = PortDirection(rawValue: m[1]); lastRange = m[2].isEmpty ? nil : m[2]
                ports.append(VerilogPort(name: m[3], direction: lastDir!, range: lastRange, width: width(of: lastRange)))
            } else if let d = lastDir {
                let r = m[2].isEmpty ? lastRange : m[2]
                ports.append(VerilogPort(name: m[3], direction: d, range: r, width: width(of: r)))
            } else { plainNames.append(m[3]) }
        }
        // Non-ANSI style: directions are declared in the body.
        if ports.isEmpty && !plainNames.isEmpty {
            let declRe = #"\b(input|output|inout)\b\s*(?:(?:wire|reg|logic|signed|unsigned|tri)\b\s*)*(\[[^\]]*\])?\s*((?:[A-Za-z_][A-Za-z0-9_$]*\s*,?\s*)+);"#
            var found: [String: VerilogPort] = [:]
            for m in regexMatches(declRe, in: body, options: []) {
                let dir = PortDirection(rawValue: m[1]) ?? .input
                for name in m[3].split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) where plainNames.contains(name) {
                    found[name] = VerilogPort(name: name, direction: dir, range: m[2].isEmpty ? nil : m[2], width: width(of: m[2].isEmpty ? nil : m[2]))
                }
            }
            ports = plainNames.compactMap { found[$0] }
        }
        return ports
    }

    public static func parse(text: String, url: URL) -> ParsedFile {
        let clean = stripComments(text)
        let ns = clean as NSString
        let full = NSRange(location: 0, length: ns.length)
        var modules: [VerilogModule] = []
        if let headRe = try? NSRegularExpression(pattern: #"\b(?:macromodule|module)\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)"#),
           let endRe = try? NSRegularExpression(pattern: #"\bendmodule\b"#) {
            let heads = headRe.matches(in: clean, range: full)
            let ends = endRe.matches(in: clean, range: full)
            for h in heads {
                guard let e = ends.first(where: { $0.range.location > h.range.location }) else { continue }
                let nameRange = h.range(at: 1)
                let innerStart = NSMaxRange(nameRange)
                let inner = ns.substring(with: NSRange(location: innerStart, length: e.range.location - innerStart))
                let chars = Array(inner)
                var depth = 0, headerEnd = chars.count
                for (i, ch) in chars.enumerated() {
                    if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
                    else if ch == ";" && depth == 0 { headerEnd = i; break }
                }
                let header = String(chars[0..<headerEnd])
                let body = headerEnd + 1 <= chars.count ? String(chars[min(headerEnd + 1, chars.count)...]) : ""
                let line = ns.substring(to: h.range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                let dump = regexMatches(#"\$dumpfile\s*\(\s*"([^"]*)""#, in: body, options: []).first?[1]
                let pkgs = Set(regexMatches(#"\b([A-Za-z_]\w*)::"#, in: body, options: []).map { $0[1] })
                modules.append(VerilogModule(
                    name: ns.substring(with: nameRange), file: url, line: line,
                    ports: parsePorts(header: header, body: body), body: body,
                    hasInitial: body.range(of: #"\binitial\b"#, options: .regularExpression) != nil,
                    hasDumpfile: body.contains("$dumpfile"), hasDumpvars: body.contains("$dumpvars"),
                    hasFinish: body.contains("$finish"), dumpfileName: dump, packageRefs: pkgs))
            }
        }
        let packages = regexMatches(#"\bpackage\s+([A-Za-z_]\w*)\s*;"#, in: clean, options: []).map { $0[1] }
        let includes = regexMatches(#"`include\s+"([^"]+)""#, in: clean, options: []).map { $0[1] }
        return ParsedFile(url: url, modules: modules, packages: packages, includes: includes)
    }
}

public struct DependencyResult: Sendable {
    public var files: [URL]          // compile order: packages first
    public var includeDirs: [URL]
    public var warnings: [String]
}

/// Parsed view of every HDL file in a project folder.
public struct SourceIndex: Sendable {
    public static let hdlExtensions: Set<String> = ["v", "sv", "vh", "svh"]
    public static let compileExtensions: Set<String> = ["v", "sv"]
    public var root: URL
    public var files: [URL: ParsedFile] = [:]
    public var modules: [String: [VerilogModule]] = [:]
    public var packageFiles: [String: URL] = [:]

    public init(root: URL) { self.root = root }

    public static func build(root: URL) -> SourceIndex {
        var idx = SourceIndex(root: root)
        let skip: Set<String> = ["build", "simulation", ".fpga", ".git", "node_modules", "reports", ".build", "DerivedData"]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return idx }
        for case let url as URL in en {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { if skip.contains(url.lastPathComponent) { en.skipDescendants() }; continue }
            guard hdlExtensions.contains(url.pathExtension.lowercased()), let text = readTextFile(url) else { continue }
            let std = url.standardizedFileURL
            idx.files[std] = VerilogParser.parse(text: text, url: std)
        }
        idx.finalize()
        return idx
    }

    /// Rebuilds name tables and instantiation edges.
    public mutating func finalize() {
        modules = [:]; packageFiles = [:]
        for (_, f) in files {
            for m in f.modules { modules[m.name, default: []].append(m) }
            for p in f.packages { packageFiles[p] = f.url }
        }
        for key in modules.keys { modules[key]?.sort { $0.file.path < $1.file.path } }
        let names = Array(modules.keys)
        for (url, f) in files {
            var updated = f
            for i in updated.modules.indices {
                let body = updated.modules[i].body
                updated.modules[i].instantiated = names.filter { n in
                    n != updated.modules[i].name && body.contains(n) &&
                    body.range(of: "(?<![\\w$.`])\(NSRegularExpression.escapedPattern(for: n))\\s*(?:#\\s*\\([^;]*?\\))?\\s*[A-Za-z_]\\w*\\s*(?:\\[[^\\]]*\\])?\\s*\\(",
                               options: .regularExpression) != nil
                }.sorted()
            }
            files[url] = updated
        }
        // refresh table with instantiation edges
        modules = [:]
        for (_, f) in files { for m in f.modules { modules[m.name, default: []].append(m) } }
        for key in modules.keys { modules[key]?.sort { $0.file.path < $1.file.path } }
    }

    public func module(named n: String) -> VerilogModule? { modules[n]?.first }
    public var allModuleNames: [String] { modules.keys.sorted() }

    public func dependencies(of top: String) -> DependencyResult? {
        guard modules[top]?.first != nil else { return nil }
        var visited = Set<String>(), queue = [top]
        var fileSet = Set<URL>(), warnings: [String] = []
        while let name = queue.popLast() {
            guard visited.insert(name).inserted, let defs = modules[name], let m = defs.first else { continue }
            if defs.count > 1 {
                warnings.append("Module '\(name)' is defined in \(defs.count) files; using \(relativePath(m.file, to: root)).")
            }
            fileSet.insert(m.file)
            queue += m.instantiated
            for p in m.packageRefs { if let pf = packageFiles[p] { fileSet.insert(pf) } }
        }
        let pkgFiles = fileSet.filter { !(files[$0]?.packages.isEmpty ?? true) }.sorted { $0.path < $1.path }
        let others = fileSet.subtracting(pkgFiles).sorted { $0.path < $1.path }
        let ordered = pkgFiles + others
        var dirs: [URL] = []
        func addDir(_ u: URL) { let d = u.standardizedFileURL; if !dirs.contains(d) { dirs.append(d) } }
        let headers = files.keys.filter { ["vh", "svh"].contains($0.pathExtension.lowercased()) }
        for f in ordered {
            addDir(f.deletingLastPathComponent())
            for inc in files[f]?.includes ?? [] {
                if let h = headers.first(where: { $0.lastPathComponent == (inc as NSString).lastPathComponent }) { addDir(h.deletingLastPathComponent()) }
            }
        }
        return DependencyResult(files: ordered, includeDirs: dirs, warnings: warnings)
    }
}
