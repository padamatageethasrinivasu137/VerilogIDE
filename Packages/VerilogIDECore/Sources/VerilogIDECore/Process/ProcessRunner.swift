import Foundation

public enum OutputStream: String, Sendable { case stdout, stderr }

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let duration: TimeInterval
    public let timedOut: Bool
    public let cancelled: Bool
    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }
}

/// Lets callers terminate a running child (SIGTERM, then SIGKILL after 2 s).
public final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    func attach(_ p: Process) {
        lock.lock(); process = p; let c = cancelled; lock.unlock()
        if c { terminate() }
    }
    public var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func terminate() {
        lock.lock(); cancelled = true; lock.unlock()
        killProcess()
    }
    /// For internal timeouts: terminate without marking the handle as user-cancelled.
    func terminateForTimeout() { killProcess() }
    private func killProcess() {
        lock.lock(); let p = process; lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
    }
}

private final class Accumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func append(_ d: Data, _ s: OutputStream) { lock.lock(); if s == .stdout { out.append(d) } else { err.append(d) }; lock.unlock() }
    var texts: (String, String) { lock.lock(); defer { lock.unlock() }; return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
}

/// Safe process execution: argument arrays only, never a shell.
public enum ProcessRunner {
    public static func run(executable: String,
                           arguments: [String],
                           cwd: URL? = nil,
                           environment: [String: String]? = nil,
                           timeout: TimeInterval? = nil,
                           handle: ProcessHandle? = nil,
                           onOutput: (@Sendable (OutputStream, String) -> Void)? = nil) async -> ProcessResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ToolLocator.shared.enrichedPath(base: env["PATH"])
            environment?.forEach { env[$0.key] = $0.value }
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe; process.standardError = errPipe

            let acc = Accumulator()
            let timedOut = Locked(false)
            let start = Date()
            let h = handle ?? ProcessHandle()

            func wire(_ pipe: Pipe, _ stream: OutputStream) {
                pipe.fileHandleForReading.readabilityHandler = { fh in
                    let d = fh.availableData
                    if d.isEmpty { fh.readabilityHandler = nil; return }
                    acc.append(d, stream)
                    onOutput?(stream, String(decoding: d, as: UTF8.self))
                }
            }
            wire(outPipe, .stdout); wire(errPipe, .stderr)

            process.terminationHandler = { p in
                for (pipe, stream) in [(outPipe, OutputStream.stdout), (errPipe, OutputStream.stderr)] {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !rest.isEmpty { acc.append(rest, stream); onOutput?(stream, String(decoding: rest, as: UTF8.self)) }
                }
                let (o, e) = acc.texts
                let to = timedOut.get
                cont.resume(returning: ProcessResult(exitCode: p.terminationStatus, stdout: o, stderr: e,
                                                     duration: Date().timeIntervalSince(start),
                                                     timedOut: to, cancelled: h.wasCancelled && !to))
            }
            h.attach(process)
            do { try process.run() } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: ProcessResult(exitCode: -1, stdout: "",
                                                     stderr: "Failed to launch \(executable): \(error.localizedDescription)",
                                                     duration: 0, timedOut: false, cancelled: false))
                return
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { timedOut.with { $0 = true }; h.terminateForTimeout() }
                }
            }
        }
    }
}
