import Foundation

/// Quote a string for display / for passing through a *remote* shell. Local processes never use shells.
public func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public func displayCommand(_ exe: String, _ args: [String]) -> String {
    ([exe] + args).map(shellQuote).joined(separator: " ")
}

/// Returns all regex matches as arrays of capture groups (index 0 = whole match). Missing groups are "".
public func regexMatches(_ pattern: String, in text: String,
                         options: NSRegularExpression.Options = [.anchorsMatchLines]) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

/// Path of `url` relative to `base` when it lives below it; otherwise the absolute path.
public func relativePath(_ url: URL, to base: URL) -> String {
    let u = url.standardizedFileURL.path, b = base.standardizedFileURL.path
    if u.hasPrefix(b + "/") { return String(u.dropFirst(b.count + 1)) }
    return u
}

public func readTextFile(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
}

/// Simple lock-protected box, used to share state with background callbacks.
public final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    public init(_ v: T) { value = v }
    public func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    public var get: T { with { $0 } }
}
