import Foundation

/// Describes an AMD/Xilinx part number such as `xc7a35tcpg236-1`. Only the family prefix is interpreted;
/// authoritative validation always comes from Vivado (`get_parts`) or the package-pin export.
public struct XilinxPart: Equatable, Sendable {
    public let raw: String
    public let familyPrefix: String?
    public let familyName: String?
    public let isLegacyISE: Bool

    private static let families: [(String, String)] = [
        ("xc7a", "Artix-7"), ("xc7k", "Kintex-7"), ("xc7v", "Virtex-7"), ("xc7s", "Spartan-7"), ("xc7z", "Zynq-7000"),
        ("xcau", "Artix UltraScale+"), ("xcku", "Kintex UltraScale / UltraScale+"), ("xcvu", "Virtex UltraScale / UltraScale+"),
        ("xczu", "Zynq UltraScale+ MPSoC / RFSoC"), ("xcsu", "Spartan UltraScale+"),
        ("xcvc", "Versal AI Core"), ("xcve", "Versal AI Edge"), ("xcvm", "Versal Prime"), ("xcvp", "Versal Premium"), ("xcvh", "Versal HBM"),
    ]
    private static let legacyPrefixes = ["xc2", "xc3", "xc4", "xc5", "xc6", "xc9"]

    public static func parse(_ s: String) -> XilinxPart? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.range(of: #"^(xc|xa|xq|xqr)[0-9a-z]{3,}(-[0-9a-z]+)*$"#, options: .regularExpression) != nil else { return nil }
        var norm = t
        if norm.hasPrefix("xa") || norm.hasPrefix("xq") { norm = "xc" + norm.dropFirst(2) }
        let fam = families.first { norm.hasPrefix($0.0) }
        let legacy = legacyPrefixes.contains { norm.hasPrefix($0) }
        return XilinxPart(raw: t, familyPrefix: fam?.0, familyName: fam?.1, isLegacyISE: legacy)
    }
}
