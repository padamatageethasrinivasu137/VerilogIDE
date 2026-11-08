import SwiftUI
import AppKit
import Darwin
import VerilogIDECore

/// Minimal terminal screen model: line editing sequences used by zsh/bash (CR, BS, CSI K/C/D/G/P/@/X/J) are honoured.
/// Full-screen programs (vim, top) are not supported — see README.
final class TerminalScreen {
    private(set) var lines: [[Character]] = [[]]
    private(set) var row = 0, col = 0
    private enum State { case normal, esc, csi, osc, oscEsc, charset }
    private var state = State.normal
    private var params = ""
    private var pending = Data()
    private(set) var bracketedPasteEnabled = false
    private var savedCursor = (row: 0, col: 0)
    // Keep a substantial bounded scrollback so long-running shell sessions stay responsive.
    let maxLines = 10_000

    var plainText: String { lines.map { String($0) }.joined(separator: "\n") }

    func clear() {
        lines = [[]]
        row = 0
        col = 0
        savedCursor = (0, 0)
        state = .normal
        params = ""
        pending.removeAll(keepingCapacity: true)
        bracketedPasteEnabled = false
    }

    func feed(_ data: Data) {
        pending.append(data)
        var cut = pending.count
        // keep an incomplete UTF-8 tail for the next chunk
        var back = 0
        while back < min(3, pending.count) {
            let b = pending[pending.count - 1 - back]
            if b & 0xC0 == 0x80 { back += 1; continue }
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if need > back + 1 { cut = pending.count - 1 - back }
            break
        }
        let chunk = pending.prefix(cut); pending = Data(pending.dropFirst(cut))
        for s in String(decoding: chunk, as: UTF8.self).unicodeScalars { handle(s) }
        if lines.count > maxLines { let d = lines.count - maxLines; lines.removeFirst(d); row = max(0, row - d) }
    }

    private func put(_ c: Character) {
        while lines[row].count < col { lines[row].append(" ") }
        if col < lines[row].count { lines[row][col] = c } else { lines[row].append(c) }
        col += 1
    }

    private func handle(_ s: Unicode.Scalar) {
        let v = s.value
        switch state {
        case .normal:
            switch v {
            case 0x1B: state = .esc
            case 0x0A: row += 1; if row >= lines.count { lines.append([]) }
            case 0x0C: clear()
            case 0x0D: col = 0
            case 0x08: col = max(0, col - 1)
            case 0x09: let n = (col / 8 + 1) * 8; while col < n { put(" ") }
            case 0x07, 0x00...0x06, 0x0B, 0x0E...0x1A, 0x1C...0x1F: break
            default: put(Character(s))
            }
        case .esc:
            switch s { case "[": state = .csi; params = ""
                       case "]": state = .osc
                       case "(", ")": state = .charset
                       default: state = .normal }
        case .charset: state = .normal
        case .osc: if v == 0x07 { state = .normal } else if v == 0x1B { state = .oscEsc }
        case .oscEsc: state = .normal
        case .csi:
            if (0x40...0x7E).contains(v) { csi(Character(s)); state = .normal } else { params.unicodeScalars.append(s) }
        }
    }

    private func csi(_ f: Character) {
        // Track DEC private mode 2004, which shells enable to receive pasted
        // text as one protected buffer rather than as individual Return keys.
        if params.hasPrefix("?") {
            let modes = params.dropFirst().split(separator: ";").compactMap { Int($0) }
            if modes.contains(2004) {
                if f == "h" { bracketedPasteEnabled = true }
                if f == "l" { bracketedPasteEnabled = false }
            }
            return
        }
        if params.hasPrefix(">") { return }
        let p = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        let n = max(1, p.first.flatMap { $0 } ?? 1)
        switch f {
        case "A": row = max(0, row - n)
        case "B": row = min(lines.count - 1, row + n)
        case "C": col += n
        case "D": col = max(0, col - n)
        case "G": col = max(0, n - 1)
        case "H", "f":
            row = max(0, min(lines.count - 1, (p.first.flatMap { $0 } ?? 1) - 1))
            col = max(0, (p.count > 1 ? (p[1] ?? 1) : 1) - 1)
        case "d": row = max(0, min(lines.count - 1, n - 1))
        case "s": savedCursor = (row, col)
        case "u": row = min(lines.count - 1, savedCursor.row); col = savedCursor.col
        case "K":
            let m = p.first.flatMap { $0 } ?? 0
            if m == 0 { if col < lines[row].count { lines[row].removeSubrange(col...) } }
            else if m == 1 { for i in 0..<min(col + 1, lines[row].count) { lines[row][i] = " " } }
            else { lines[row] = [] }
        case "J":
            let m = p.first.flatMap { $0 } ?? 0
            if m >= 2 { lines = [[]]; row = 0; col = 0 }
            else if m == 0 { if col < lines[row].count { lines[row].removeSubrange(col...) }; if row + 1 < lines.count { lines.removeSubrange((row + 1)...) } }
        case "P": if col < lines[row].count { lines[row].removeSubrange(col..<min(lines[row].count, col + n)) }
        case "@": while lines[row].count < col { lines[row].append(" ") }; lines[row].insert(contentsOf: Array(repeating: " ", count: n), at: col)
        case "X": let hi = min(lines[row].count, col + n); if col < hi { for i in col..<hi { lines[row][i] = " " } }
        default: break
        }
    }

    func attributed(font: NSFont) -> NSAttributedString {
        var text = ""; var cursor = 0
        for (i, l) in lines.enumerated() {
            if i == row { cursor = text.utf16.count + min(col, 100_000) }
            var line = String(l)
            if i == row && col > l.count { line += String(repeating: " ", count: col - l.count) }
            text += line; if i < lines.count - 1 { text += "\n" }
        }
        let out = NSMutableAttributedString(string: text + " ", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if cursor < out.length { out.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.6), range: NSRange(location: cursor, length: 1)) }
        return out
    }
}

/// A real shell on a pseudo-terminal (forkpty). Nothing is simulated.
final class PTYSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var version = 0
    @Published var exited = false
    let screen = TerminalScreen()
    let cwd: URL
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var source: DispatchSourceRead?
    private var publishPending = false

    init(cwd: URL) { self.cwd = cwd; start() }

    private func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["TERM_PROGRAM"] = "VerilogIDE"; env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = ToolLocator.shared.enrichedPath(base: env["PATH"])
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-l"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cwdC = strdup(cwd.path)
        var ws = winsize(ws_row: 24, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        var m: Int32 = 0
        let child = forkpty(&m, nil, nil, &ws)
        if child == 0 {            // child: only async-signal-safe calls from here
            chdir(cwdC); execve(shell, argv, envp); _exit(127)
        }
        argv.forEach { free($0) }; envp.forEach { free($0) }; free(cwdC)
        guard child > 0 else { exited = true; return }
        master = m; pid = child
        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: .global(qos: .userInteractive))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(self.master, &buf, buf.count)
            if n <= 0 { self.source?.cancel(); DispatchQueue.main.async { self.exited = true; self.version += 1 }; return }
            let d = Data(buf[0..<n])
            DispatchQueue.main.async { self.screen.feed(d); self.schedulePublish() }
        }
        src.resume(); source = src
    }

    private func schedulePublish() {
        guard !publishPending else { return }
        publishPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.publishPending = false; self.version += 1 }
    }

    func write(_ data: Data) { guard master >= 0, !exited else { return }; data.withUnsafeBytes { _ = Darwin.write(master, $0.baseAddress, data.count) } }
    func write(_ s: String) { write(Data(s.utf8)) }

    func paste(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if screen.bracketedPasteEnabled {
            write("\u{1B}[200~" + normalized + "\u{1B}[201~")
        } else {
            write(normalized)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard master >= 0, cols > 0, rows > 0 else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, 0x80087467 /* TIOCSWINSZ on Darwin */, &ws)
    }

    func terminate() {
        source?.cancel()
        if pid > 0 { kill(pid, SIGHUP); DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [pid] in kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, WNOHANG) } }
        if master >= 0 { close(master); master = -1 }
    }
    deinit { terminate() }
}

struct TerminalGroup: Identifiable { let id = UUID(); var sessions: [PTYSession]; var title: String }

@MainActor
final class TerminalManager: ObservableObject {
    @Published var groups: [TerminalGroup] = []
    @Published var activeGroup: UUID?
    @Published private(set) var focusedGroupID: UUID?
    @Published private(set) var focusedSessionID: UUID?

    var hasFocusedSession: Bool {
        guard let groupID = focusedGroupID, let sessionID = focusedSessionID else { return false }
        return groups.first(where: { $0.id == groupID })?.sessions.contains(where: { $0.id == sessionID }) == true
    }

    func newTerminal(cwd: URL) {
        let session = PTYSession(cwd: cwd)
        let group = TerminalGroup(
            sessions: [session],
            title: cwd.lastPathComponent.isEmpty ? "zsh" : cwd.lastPathComponent
        )
        groups.append(group)
        activeGroup = group.id
        focus(session.id, in: group.id)
    }

    func split(cwd: URL) {
        guard let groupID = activeGroup,
              let index = groups.firstIndex(where: { $0.id == groupID }),
              groups[index].sessions.count < 4 else {
            newTerminal(cwd: cwd)
            return
        }
        let session = PTYSession(cwd: cwd)
        groups[index].sessions.append(session)
        focus(session.id, in: groupID)
    }

    func focus(_ sessionID: UUID, in groupID: UUID) {
        guard groups.first(where: { $0.id == groupID })?.sessions.contains(where: { $0.id == sessionID }) == true else { return }
        activeGroup = groupID
        focusedGroupID = groupID
        focusedSessionID = sessionID
    }

    func blur(_ sessionID: UUID) {
        guard focusedSessionID == sessionID else { return }
        focusedGroupID = nil
        focusedSessionID = nil
    }

    func activateGroup(_ id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        activeGroup = id
        if let last = group.sessions.last { focus(last.id, in: id) }
    }

    func close(_ id: UUID) {
        groups.first { $0.id == id }?.sessions.forEach { $0.terminate() }
        groups.removeAll { $0.id == id }
        if focusedGroupID == id {
            focusedGroupID = nil
            focusedSessionID = nil
        }
        if activeGroup == id {
            activeGroup = groups.last?.id
            if let group = groups.last, let session = group.sessions.last { focus(session.id, in: group.id) }
        }
    }

    func closeFocusedSession() {
        guard let groupID = focusedGroupID, let sessionID = focusedSessionID,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].sessions.first(where: { $0.id == sessionID })?.terminate()
        groups[index].sessions.removeAll { $0.id == sessionID }
        if groups[index].sessions.isEmpty {
            close(groupID)
        } else if let next = groups[index].sessions.last {
            focus(next.id, in: groupID)
        }
    }

    func clear(in groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let targets: [PTYSession]
        if focusedGroupID == groupID, let focusedSessionID,
           let focused = group.sessions.first(where: { $0.id == focusedSessionID }) {
            targets = [focused]
        } else {
            targets = group.sessions
        }
        for session in targets {
            session.screen.clear()
            session.version += 1
            session.write(Data([0x0C])) // Ctrl-L asks the shell to repaint its prompt.
        }
    }

    func copyAll(in groupID: UUID) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let text: String
        if group.sessions.count == 1 {
            text = group.sessions[0].screen.plainText
        } else {
            text = group.sessions.enumerated().map { index, session in
                "===== Terminal pane \(index + 1) =====\n\(session.screen.plainText)"
            }.joined(separator: "\n\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


final class TerminalTextView: NSTextView {
    var onInput: ((Data) -> Void)?
    var onClear: (() -> Void)?
    var onCopyAll: (() -> Void)?
    var onPaste: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            DispatchQueue.main.async { [weak self] in self?.onFocus?() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            DispatchQueue.main.async { [weak self] in self?.onBlur?() }
        }
        return resigned
    }

    override func copy(_ sender: Any?) {
        // Cmd-C copies selected terminal text. Interrupts are sent only by Ctrl-C.
        guard selectedRange().length > 0 else { return }
        super.copy(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        // Handle Ctrl-C before AppKit routes it to a menu/window key equivalent.
        // ETX (0x03) is the standard terminal interrupt character.
        if flags.contains(.control), key == "c" {
            onInput?(Data([0x03]))
            return true
        }

        // Command-C copies selected text; Command-Shift-C copies all output.
        if flags.contains(.command) {
            if key == "c" {
                if flags.contains(.shift) { onCopyAll?() }
                else if selectedRange().length > 0 { super.copy(nil) }
                return true
            }
            if key == "v" { paste(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        // NSTextView must not insert text into the read-only terminal transcript.
        // All keyboard input is translated to the PTY in keyDown(with:).
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        if flags.contains(.command) {
            // Terminal.app-style cursor and scrollback navigation.
            if event.keyCode == 123 { onInput?(Data([0x01])); return } // Cmd-Left: beginning of line
            if event.keyCode == 124 { onInput?(Data([0x05])); return } // Cmd-Right: end of line
            if event.keyCode == 126 { scrollToBeginningOfDocument(nil); return } // Cmd-Up
            if event.keyCode == 125 { scrollToEndOfDocument(nil); return } // Cmd-Down
            if flags.contains(.shift), key == "c" {
                onCopyAll?()
                return
            }
            switch key {
            case "k":
                onClear?()
                return
            case "c":
                if selectedRange().length > 0 { super.copy(nil) }
                return
            case "v":
                paste(nil)
                return
            case "a":
                selectAll(nil)
                return
            case "f":
                super.keyDown(with: event) // Native Find bar.
                return
            default:
                super.keyDown(with: event)
                return
            }
        }

        if flags.contains(.control) {
            let controls: [String: UInt8] = [
                " ": 0x00, "@": 0x00,
                "a": 0x01, "b": 0x02, "c": 0x03, "d": 0x04,
                "e": 0x05, "f": 0x06, "g": 0x07, "h": 0x08,
                "i": 0x09, "j": 0x0A, "k": 0x0B, "l": 0x0C,
                "m": 0x0D, "n": 0x0E, "o": 0x0F, "p": 0x10,
                "q": 0x11, "r": 0x12, "s": 0x13, "t": 0x14,
                "u": 0x15, "v": 0x16, "w": 0x17, "x": 0x18,
                "y": 0x19, "z": 0x1A, "[": 0x1B, "\\": 0x1C,
                "]": 0x1D, "^": 0x1E, "_": 0x1F
            ]
            if let byte = controls[key] {
                onInput?(Data([byte]))
                return
            }
        }

        // Option+Left/Right are the conventional readline word-navigation keys.
        if flags.contains(.option) {
            if event.keyCode == 123 { onInput?(Data([0x1B, 0x62])); return } // Esc-b
            if event.keyCode == 124 { onInput?(Data([0x1B, 0x66])); return } // Esc-f
            if let chars = event.characters, !chars.isEmpty {
                onInput?(Data(([UInt8(0x1B)] + Array(chars.utf8))))
                return
            }
        }

        let sequence: String?
        switch event.keyCode {
        case 126: sequence = "\u{1B}[A" // Up
        case 125: sequence = "\u{1B}[B" // Down
        case 124: sequence = "\u{1B}[C" // Right
        case 123: sequence = "\u{1B}[D" // Left
        case 36, 76: sequence = "\r" // Return / keypad Enter
        case 51: sequence = "\u{7F}" // Backspace
        case 48: sequence = "\t" // Tab
        case 53: sequence = "\u{1B}" // Escape
        case 117: sequence = "\u{1B}[3~" // Forward delete
        case 115: sequence = "\u{1B}[H" // Home
        case 119: sequence = "\u{1B}[F" // End
        default: sequence = event.characters
        }
        if let sequence, !sequence.isEmpty { onInput?(Data(sequence.utf8)) }
    }

    override func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        onPaste?(string)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: PTYSession
    var onFocus: () -> Void = {}
    var onBlur: () -> Void = {}
    var onCopyAll: () -> Void = {}
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var token: NSObjectProtocol?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: .zero)
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let tv = TerminalTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textColor = .labelColor
        tv.font = font
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.onInput = { [weak session] in session?.write($0) }
        tv.onClear = { [weak session] in
            guard let session else { return }
            session.screen.clear()
            session.version += 1
            session.write(Data([0x0C])) // Ask zsh/bash to redraw its prompt after clearing.
        }
        tv.onFocus = onFocus
        tv.onBlur = onBlur
        tv.onCopyAll = onCopyAll
        tv.onPaste = { [weak session] text in session?.paste(text) }

        scroll.documentView = tv
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.token = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak session, weak scroll] _ in
            guard let session, let scroll else { return }
            let terminalFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let charWidth = ("M" as NSString).size(withAttributes: [.font: terminalFont]).width
            let lineHeight = terminalFont.boundingRectForFont.height
            let cols = max(20, Int((scroll.contentSize.width - 16) / max(charWidth, 1)))
            let rows = max(4, Int((scroll.contentSize.height - 12) / max(lineHeight, 1)))
            session.resize(cols: cols, rows: rows)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        _ = session.version
        let selection = tv.selectedRange()
        let wasAtBottom = tv.visibleRect.maxY >= tv.bounds.maxY - 24
        tv.textStorage?.setAttributedString(session.screen.attributed(font: font))
        let safeRange = NSRange(
            location: min(selection.location, tv.string.utf16.count),
            length: min(selection.length, max(0, tv.string.utf16.count - min(selection.location, tv.string.utf16.count)))
        )
        if safeRange.length > 0 { tv.setSelectedRange(safeRange) }
        if wasAtBottom { tv.scrollToEndOfDocument(nil) }
    }
}

struct TerminalPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var manager: TerminalManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(manager.groups) { group in
                    HStack(spacing: 4) {
                        Image(systemName: "terminal").font(.caption)
                        Text(group.title).font(.caption)
                        Button { manager.close(group.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Close terminal group")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(manager.activeGroup == group.id ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())
                    .onTapGesture { manager.activateGroup(group.id) }
                }
                Spacer()
                if let group = manager.groups.first(where: { $0.id == manager.activeGroup }) {
                    Button {
                        manager.copyAll(in: group.id)
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .help("Copy the complete terminal scrollback (⌘⇧C)")

                    Button {
                        manager.clear(in: group.id)
                    } label: {
                        Label("Clear", systemImage: "eraser")
                    }
                    .help("Clear terminal screen and redraw prompt (⌘K)")
                }
                Button { app.showTerminal(new: true) } label: { Image(systemName: "plus") }.help("New Terminal (⌘T)")
                Button {
                    manager.split(cwd: app.activeProjectRoot ?? URL(fileURLWithPath: NSHomeDirectory()))
                } label: { Image(systemName: "rectangle.split.2x1") }.help("Split Terminal (⌘D)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            if let group = manager.groups.first(where: { $0.id == manager.activeGroup }) {
                HStack(spacing: 1) {
                    ForEach(group.sessions) { session in
                        TerminalSurface(
                            session: session,
                            onFocus: { manager.focus(session.id, in: group.id) },
                            onBlur: { manager.blur(session.id) },
                            onCopyAll: { manager.copyAll(in: group.id) }
                        )
                        .id(session.id)
                    }
                }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if manager.groups.isEmpty, let root = app.activeProjectRoot {
                app.showTerminal(new: true, at: root)
            }
        }
        .onChange(of: app.activeProjectRoot) { _, newRoot in
            guard manager.groups.isEmpty, let root = newRoot else { return }
            app.showTerminal(new: true, at: root)
        }
    }
}
