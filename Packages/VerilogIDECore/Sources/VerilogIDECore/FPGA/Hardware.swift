import Foundation
import CryptoKit

public struct DetectedDevice: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public let index: Int
    public var idcode = ""
    public var manufacturer: String?
    public var family: String?
    public var model: String?
}

public struct USBDevice: Identifiable, Hashable, Sendable {
    public var id: String { "\(vendorID):\(productID):\(serial ?? name)" }
    public let name: String, vendorID: String, productID: String
    public let serial: String?
    /// FTDI (0x0403) is common on JTAG adapters, but a USB device alone proves nothing about an FPGA.
    public var maybeJTAG: Bool { vendorID.lowercased().contains("0x0403") }
}

public enum PartVerification: Equatable, Sendable { case match(String), mismatch(String), unknown(String) }

public enum HardwareManager {
    /// Parses `openFPGALoader --detect` output (`index 0:` / `idcode 0x…` / `model xc7a35` …).
    public static func parseDetect(_ text: String) -> [DetectedDevice] {
        var devices: [DetectedDevice] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let l = String(raw)
            if let m = regexMatches(#"^\s*index\s+(\d+):"#, in: l).first, let i = Int(m[1]) { devices.append(DetectedDevice(index: i)); continue }
            guard !devices.isEmpty, let m = regexMatches(#"^\s*(idcode|manufacturer|family|model)\s+(.+?)\s*$"#, in: l).first else { continue }
            switch m[1] {
            case "idcode": devices[devices.count - 1].idcode = m[2]
            case "manufacturer": devices[devices.count - 1].manufacturer = m[2]
            case "family": devices[devices.count - 1].family = m[2]
            default: devices[devices.count - 1].model = m[2]
            }
        }
        return devices.filter { !$0.idcode.isEmpty }   // no idcode ⇒ not a verified JTAG detection
    }

    public static func verify(part: XilinxPart, devices: [DetectedDevice]) -> PartVerification {
        guard !devices.isEmpty else { return .unknown("No JTAG device was identified.") }
        for d in devices {
            if let m = d.model?.lowercased(), !m.isEmpty, part.raw.hasPrefix(m) { return .match("\(m) (idcode \(d.idcode))") }
        }
        let seen = devices.map { ($0.model ?? "unknown model") + " idcode " + $0.idcode }.joined(separator: ", ")
        if devices.allSatisfy({ $0.model == nil }) { return .unknown("Detected \(seen); the loader did not report a model to compare with \(part.raw).") }
        return .mismatch("Detected \(seen), which does not match \(part.raw).")
    }

    public static func detectArguments(board: String, cable: String) -> [String] {
        var a: [String] = []
        if !board.isEmpty { a += ["-b", board] } else if !cable.isEmpty { a += ["-c", cable] }
        return a + ["--detect"]
    }

    /// `-m` writes SRAM (volatile); `-f` writes flash (persistent, never used implicitly).
    public static func programArguments(board: String, cable: String, bitstream: URL, flash: Bool) -> [String] {
        var a: [String] = []
        if !board.isEmpty { a += ["-b", board] } else if !cable.isEmpty { a += ["-c", cable] }
        a.append(flash ? "-f" : "-m")
        return a + [bitstream.path]
    }

    public static func scanUSB() async -> [USBDevice] {
        let r = await ProcessRunner.run(executable: "/usr/sbin/system_profiler", arguments: ["SPUSBDataType", "-json"], timeout: 20)
        guard let data = r.stdout.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var out: [USBDevice] = []
        func walk(_ items: [[String: Any]]) {
            for i in items {
                if let n = i["_name"] as? String, let v = i["vendor_id"] as? String {
                    out.append(USBDevice(name: n, vendorID: v, productID: (i["product_id"] as? String) ?? "", serial: i["serial_num"] as? String))
                }
                if let sub = i["_items"] as? [[String: Any]] { walk(sub) }
            }
        }
        walk((root["SPUSBDataType"] as? [[String: Any]]) ?? [])
        return out
    }

    public static func parseList(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { l in
            let s = l.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("-") || s.lowercased().hasPrefix("board name") || s.lowercased().hasPrefix("cable name") { return nil }
            return s.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
    }
}

public enum BitstreamValidator {
    /// Checks existence, non-emptiness, freshness, and the Xilinx .bit header / sync word.
    public static func validate(_ url: URL, notOlderThan: Date?) -> [String] {
        var problems: [String] = []
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return ["Bitstream not found: \(url.path)"] }
        if ((attrs[.size] as? Int) ?? 0) == 0 { return ["Bitstream is empty."] }
        if let nb = notOlderThan, let m = attrs[.modificationDate] as? Date, m < nb { problems.append("Bitstream is older than the last successful implementation (stale).") }
        if url.pathExtension.lowercased() == "bit", let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            let head = (try? fh.read(upToCount: 8192)) ?? Data()
            let magic: [UInt8] = [0x00, 0x09, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x00, 0x00, 0x01]
            if Array(head.prefix(13)) != magic { problems.append("File does not start with a Xilinx .bit header.") }
            if head.range(of: Data([0xAA, 0x99, 0x55, 0x66])) == nil { problems.append("Configuration sync word not found in the first 8 KB.") }
        }
        return problems
    }
}

public enum IntegrityChecker {
    public static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url); defer { try? fh.close() }
        var h = SHA256()
        while let d = try fh.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
