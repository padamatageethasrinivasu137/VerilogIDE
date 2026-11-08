import SwiftUI
import Charts
import AppKit
import VerilogIDECore

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var app: AppState
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { app.promptNewFile(.verilog) } label: { Label("New File", systemImage: "doc.badge.plus") }.help("New File (⌘N)")
            Button { app.openFolderPanel() } label: { Label("Open Folder", systemImage: "folder") }.help("Open Folder (⇧⌘O)")
            Button { app.saveActive() } label: { Label("Save", systemImage: "square.and.arrow.down") }.help("Save (⌘S)")
            Button { app.saveAll() } label: { Label("Save All", systemImage: "square.and.arrow.down.on.square") }.help("Save All (⇧⌘S)")
        }
        ToolbarItemGroup(placement: .principal) {
            Button { app.runSimulation() } label: { Label("Run", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).tint(.green).disabled(app.isBusy).help("Run Simulation (⌘R)")
            Button { app.stopProcess() } label: { Label("Stop", systemImage: "stop.fill") }.disabled(!app.isBusy).help("Stop (⌘.)")
            Button { app.openWaveform() } label: { Label("Waveform", systemImage: "waveform") }.help("Open Waveform (⇧⌘W)")
            Button { app.cleanProjectArtifacts() } label: { Label("Clean", systemImage: "sparkles") }
                .help("Remove generated simulation artifacts and .DS_Store files")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Synthesize") { app.runFPGA(.synthesis) }
                Button("Implement") { app.runFPGA(.implementation) }
                Button("Generate Bitstream") { app.runFPGA(.bitstream) }
                Button("Program FPGA…") { app.runFPGA(.program) }
                Divider()
                Button("Pin Planner…") { app.sheet = .pinPlanner }
                Button("FPGA Project Settings…") { app.sheet = .fpgaSettings }
            } label: { Label("FPGA", systemImage: "cpu") }.disabled(app.isBusy)
            Button { app.showBottomPanel.toggle() } label: { Label("Panel", systemImage: "rectangle.bottomthird.inset.filled") }.help("Toggle Panel (⌘J)")
            SettingsLink { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 8) {
            if app.isBusy { ProgressView().controlSize(.small) }
            Text(app.statusText).lineLimit(1)
            Spacer()
            if app.errorCount > 0 { Label("\(app.errorCount)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            if let c = app.fpgaConfig { Text(c.part).foregroundStyle(.secondary) }
        }
        .font(.caption).padding(.horizontal, 12).padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: Sidebar
struct SidebarView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Group {
            if app.rootNodes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("No folder open").font(.headline)
                    Button("Open Folder…") { app.openFolderPanel() }
                    Button("New Project…") { app.sheet = .newSimProject }.buttonStyle(.link)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $app.selection) {
                    ForEach(app.rootNodes) { root in
                        Section {
                            OutlineGroup(root.children ?? [], children: \.children) { node in FileRow(node: node) }
                                .id(app.treeRevision)
                        } header: {
                            HStack { Image(systemName: "shippingbox.fill").foregroundStyle(.tint); Text(root.name).fontWeight(.semibold)
                                Spacer()
                                Menu { Button("New Verilog File…") { app.promptNewFile(.verilog, in: root.url) }
                                       Button("New Folder…") { app.promptNewFolder(in: root.url) }
                                       Button("Reveal in Finder") { app.reveal(root.url) }
                                       Divider(); Button("Close Project") { app.closeProject(root.url) } } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).fixedSize()
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: app.selection) { _, new in
                    guard let new else { return }

                    // Defer AppState mutations until SwiftUI finishes
                    // processing the List selection update.
                    DispatchQueue.main.async {
                        app.selectionChanged(new)
                    }
                }
            }
        }
    }
}

struct FileRow: View {
    @EnvironmentObject var app: AppState
    let node: FileNode
    var body: some View {
        let row = Label(node.name, systemImage: node.icon).lineLimit(1)
            .contextMenu {
                let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
                Button("New Verilog File…") { app.promptNewFile(.verilog, in: dir) }
                Button("New SystemVerilog File…") { app.promptNewFile(.systemVerilog, in: dir) }
                Button("New Testbench…") { app.promptNewFile(.testbench, in: dir) }
                Button("New Folder…") { app.promptNewFolder(in: dir) }
                Divider()
                Button("Rename…") { app.promptRename(node.url) }
                Button("Duplicate") { app.duplicate(node.url) }
                Button("Move to Trash…", role: .destructive) { app.confirmDelete(node.url) }
                Divider()
                Button("Reveal in Finder") { app.reveal(node.url) }
                Button("Open Terminal Here") { app.showTerminal(new: true, at: dir) }
            }
            .draggable(node.url)
            .tag(node.url)
        if node.isDirectory {
            row.dropDestination(for: URL.self) { urls, _ in app.move(urls, into: node.url); return true }
        } else {
            row
                .contentShape(Rectangle())
        }
    }
}

// MARK: Editor area
struct EditorArea: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 0) {
            if app.tabs.isEmpty { WelcomeView() }
            else {
                TabBar(); Divider()
                if let t = app.activeTab { EditorPane(tab: t).id(t.id) }
            }
        }
    }
}

struct TabBar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) { ForEach(app.tabs) { TabItem(tab: $0) } }
        }.frame(height: 30).background(.bar)
    }
}

struct TabItem: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: EditorTab
    @State private var hover = false
    var body: some View {
        let active = app.activeTabID == tab.id
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
            Text(tab.title).font(.callout).strikethrough(tab.missingOnDisk)
            ZStack {
                if tab.isDirty && !hover { Circle().fill(.secondary).frame(width: 7, height: 7) }
                else { Button { app.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).opacity(hover || active ? 1 : 0) }
            }.frame(width: 14)
        }
        .padding(.horizontal, 10).frame(maxHeight: .infinity)
        .background(active ? Color(nsColor: .textBackgroundColor) : .clear)
        .overlay(alignment: .bottom) { if active { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .onHover { hover = $0 }
        .onTapGesture { app.activate(tab) }
        .help(tab.url.path)
    }
}


// MARK: Editor area — minimal native NSTextView diagnostic


struct EditorPane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: EditorTab

    @AppStorage("editorFontSize") private var fontSize = 13.0

    @State private var findPresented = false
    @State private var findMode: EditorFindReplaceMode = .find
    @State private var findQuery = ""
    @State private var replacement = ""

    @State private var nextRevision = 0
    @State private var previousRevision = 0
    @State private var replaceRevision = 0
    @State private var replaceAllRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            if findPresented {
                EditorFindReplaceBar(
                    isPresented: $findPresented,
                    mode: $findMode,
                    query: $findQuery,
                    replacement: $replacement,
                    nextRevision: $nextRevision,
                    previousRevision: $previousRevision,
                    replaceRevision: $replaceRevision,
                    replaceAllRevision: $replaceAllRevision
                )
            }

            PlainTextEditor(
                text: $tab.text,
                fontSize: $fontSize,
                findPresented: $findPresented,
                findQuery: $findQuery,
                replacement: $replacement,
                nextRevision: $nextRevision,
                previousRevision: $previousRevision,
                replaceRevision: $replaceRevision,
                replaceAllRevision: $replaceAllRevision,
                jumpRequest: app.diagnosticHighlight?.url.standardizedFileURL == tab.url.standardizedFileURL ? app.diagnosticHighlight : nil,
                font: NSFont.monospacedSystemFont(
                    ofSize: fontSize,
                    weight: .regular
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }
}
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var fontSize: Double

    @Binding var findPresented: Bool
    @Binding var findQuery: String
    @Binding var replacement: String
    @Binding var nextRevision: Int
    @Binding var previousRevision: Int
    @Binding var replaceRevision: Int
    @Binding var replaceAllRevision: Int
    var jumpRequest: JumpRequest?

    let font: NSFont

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()

        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        guard let tv = scroll.documentView as? NSTextView else {
            preconditionFailure("NSTextView creation failed")
        }

        tv.delegate = context.coordinator
        context.coordinator.installFontShortcuts(for: tv)
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true

        tv.font = font
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .controlAccentColor
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 12, height: 12)

        tv.string = text

        // Match the proven AppKit rendering configuration.
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)

        tv.minSize = NSSize(
            width: 0,
            height: scroll.contentSize.height
        )

        tv.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        tv.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        tv.textContainer?.widthTracksTextView = true

        DispatchQueue.main.async {
            context.coordinator.highlight(in: tv)
        }

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else {
            return
        }

        context.coordinator.parent = self

        if let request = jumpRequest, context.coordinator.lastJumpToken != request.token {
            let ns = tv.string as NSString
            let line = max(1, request.line)
            var location = 0
            if line > 1 {
                for _ in 1..<line {
                    let range = ns.range(of: "\\n", options: [], range: NSRange(location: location, length: max(0, ns.length - location)))
                    if range.location == NSNotFound { location = ns.length; break }
                    location = range.location + 1
                }
            }
            let lineEnd = ns.range(of: "\\n", options: [], range: NSRange(location: location, length: max(0, ns.length - location)))
            let end = lineEnd.location == NSNotFound ? ns.length : lineEnd.location
            let length = max(0, end - location)
            tv.setSelectedRange(NSRange(location: location, length: length))
            tv.scrollRangeToVisible(NSRange(location: location, length: max(1, length)))
            context.coordinator.lastJumpToken = request.token
        }

        if tv.string != text {
            let oldSelection = tv.selectedRange()
            tv.string = text

            let safeLocation = min(
                oldSelection.location,
                (text as NSString).length
            )

            tv.setSelectedRange(
                NSRange(location: safeLocation, length: 0)
            )
        }

        DispatchQueue.main.async {
            context.coordinator.highlight(in: tv)
        }

        if tv.font != font {
            tv.font = font
        }

        context.coordinator.scheduleFindUpdate(
            in: tv,
            isPresented: findPresented,
            query: findQuery,
            replacement: replacement,
            next: nextRevision,
            previous: previousRevision,
            replace: replaceRevision,
            replaceAll: replaceAllRevision
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        private var highlightWork: DispatchWorkItem?
        private var textChangeWork: DispatchWorkItem?
        private var findUpdateWork: DispatchWorkItem?
        var lastJumpToken: UUID?
        private var fontKeyMonitor: Any?
        let findEngine = EditorFindReplaceEngine()

        init(_ parent: PlainTextEditor) {
            self.parent = parent
        }

        func scheduleFindUpdate(
            in textView: NSTextView,
            isPresented: Bool,
            query: String,
            replacement: String,
            next: Int,
            previous: Int,
            replace: Int,
            replaceAll: Int
        ) {
            findUpdateWork?.cancel()

            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }

                self.findEngine.update(
                    textView: textView,
                    isPresented: isPresented,
                    query: query,
                    replacement: replacement,
                    next: next,
                    previous: previous,
                    replace: replace,
                    replaceAll: replaceAll
                )

                self.findUpdateWork = nil
            }

            findUpdateWork = work
            DispatchQueue.main.async(execute: work)
        }

        func installFontShortcuts(for textView: NSTextView) {
            guard fontKeyMonitor == nil else { return }

            fontKeyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self, weak textView] event in

                guard
                    let self,
                    let textView,
                    event.window === textView.window,
                    textView.window?.firstResponder === textView
                else {
                    return event
                }

                let flags = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)

                let command = flags.contains(.command)
                let option = flags.contains(.option)
                let shift = flags.contains(.shift)
                let control = flags.contains(.control)

                guard !control else { return event }

                // Option + Delete: delete backwards on this line only.
                if option && !command && event.keyCode == 51 {
                    self.deletePreviousWordOnCurrentLine(in: textView)
                    return nil
                }

                // Option + Up / Down: move selected line block.
                if option && !command && !shift {
                    if event.keyCode == 126 {
                        self.moveSelectedLines(in: textView, direction: -1)
                        return nil
                    }

                    if event.keyCode == 125 {
                        self.moveSelectedLines(in: textView, direction: 1)
                        return nil
                    }
                }

                // Tab / Shift + Tab.
                if event.keyCode == 48 && !command && !option {
                    self.changeIndentation(in: textView, outdent: shift)
                    return nil
                }

                // Cmd + /: toggle comments.
                if command && !option && event.keyCode == 44 {
                    self.toggleLineComments(in: textView)
                    return nil
                }

                // Cmd + Shift + D: duplicate selected lines.
                if command && shift && !option && event.keyCode == 2 {
                    self.duplicateSelectedLines(in: textView)
                    return nil
                }

                // Cmd + L: select current line.
                if command && !shift && !option && event.keyCode == 37 {
                    self.selectCurrentLine(in: textView)
                    return nil
                }

                // Font size shortcuts.
                if command && !option {
                    let current = self.parent.fontSize

                    switch event.keyCode {
                    case 24: // Cmd + =
                        self.parent.fontSize = min(current + 1, 32.0)
                        return nil
                    case 27: // Cmd + -
                        self.parent.fontSize = max(current - 1, 8.0)
                        return nil
                    case 29: // Cmd + 0
                        self.parent.fontSize = 13.0
                        return nil
                    default:
                        break
                    }
                }

                // Cmd+F opens the integrated Find bar.
                // Cmd+Option+F is deliberately not intercepted.
                if command && !option && !shift && event.keyCode == 3 {
                    DispatchQueue.main.async {
                        self.parent.findPresented = true
                    }
                    return nil
                }

                // Cmd+G / Cmd+Shift+G navigate search results.
                if command && !option && event.keyCode == 5 {
                    if shift {
                        DispatchQueue.main.async {
                            self.parent.previousRevision += 1
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.parent.nextRevision += 1
                        }
                    }
                    return nil
                }

                // Leave Cmd+A, Cmd+Z and Cmd+Shift+Z native.
                return event
            }
        }


        private func deletePreviousWordOnCurrentLine(
            in textView: NSTextView
        ) {
            let source = textView.string as NSString
            let selection = textView.selectedRange()

            // A selected range should be deleted normally.
            if selection.length > 0 {
                textView.insertText("", replacementRange: selection)
                return
            }

            let cursor = min(selection.location, source.length)
            guard cursor > 0 else { return }

            let line = source.lineRange(
                for: NSRange(location: cursor, length: 0)
            )
            let lineStart = line.location

            guard cursor > lineStart else { return }

            func isHorizontalWhitespace(_ c: unichar) -> Bool {
                c == 32 || c == 9
            }

            func isWordCharacter(_ c: unichar) -> Bool {
                (c >= 48 && c <= 57) ||
                (c >= 65 && c <= 90) ||
                (c >= 97 && c <= 122) ||
                c == 95 || c == 36
            }

            var start = cursor

            // Remove spaces/tabs before the cursor.
            while start > lineStart &&
                    isHorizontalWhitespace(source.character(at: start - 1)) {
                start -= 1
            }

            let afterWhitespace = start

            // Remove the preceding identifier or word.
            while start > lineStart &&
                    isWordCharacter(source.character(at: start - 1)) {
                start -= 1
            }

            // If immediately after punctuation, remove the preceding
            // non-whitespace token. Never cross the current line boundary.
            if start == afterWhitespace && start > lineStart {
                while start > lineStart &&
                        !isHorizontalWhitespace(source.character(at: start - 1)) {
                    start -= 1
                }
            }

            guard start < cursor else { return }

            textView.insertText(
                "",
                replacementRange: NSRange(
                    location: start,
                    length: cursor - start
                )
            )
        }

        private func selectCurrentLine(in textView: NSTextView) {
            let source = textView.string as NSString
            let cursor = min(textView.selectedRange().location, source.length)

            let range = source.lineRange(
                for: NSRange(location: cursor, length: 0)
            )

            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }

        private func duplicateSelectedLines(in textView: NSTextView) {
            let source = textView.string as NSString
            let block = selectedLineBlock(in: textView)

            guard block.length > 0 else { return }

            let blockText = source.substring(with: block)
            let needsLeadingNewline = !blockText.hasSuffix("\n")
            let insertion = needsLeadingNewline
                ? "\n" + blockText
                : blockText

            let insertionPoint = NSMaxRange(block)

            textView.insertText(
                insertion,
                replacementRange: NSRange(
                    location: insertionPoint,
                    length: 0
                )
            )

            let newBlockStart = insertionPoint + (needsLeadingNewline ? 1 : 0)
            let newLength = (blockText as NSString).length
            let totalLength = (textView.string as NSString).length
            let safeLength = min(newLength, totalLength - newBlockStart)

            textView.setSelectedRange(
                NSRange(location: newBlockStart, length: safeLength)
            )
            textView.scrollRangeToVisible(
                NSRange(location: newBlockStart, length: safeLength)
            )
        }

        private func moveSelectedLines(
            in textView: NSTextView,
            direction: Int
        ) {
            let source = textView.string as NSString
            let block = selectedLineBlock(in: textView)

            guard block.length > 0 else { return }

            let adjacent: NSRange

            if direction < 0 {
                guard block.location > 0 else { return }

                adjacent = source.lineRange(
                    for: NSRange(location: block.location - 1, length: 0)
                )
            } else {
                guard NSMaxRange(block) < source.length else { return }

                adjacent = source.lineRange(
                    for: NSRange(location: NSMaxRange(block), length: 0)
                )
            }

            let blockText = source.substring(with: block)
            let adjacentText = source.substring(with: adjacent)

            let replacement = direction < 0
                ? blockText + adjacentText
                : adjacentText + blockText

            let combined = NSRange(
                location: min(block.location, adjacent.location),
                length: block.length + adjacent.length
            )

            textView.insertText(
                replacement,
                replacementRange: combined
            )

            let newStart = direction < 0
                ? block.location - adjacent.length
                : block.location + adjacent.length

            let updatedLength = (textView.string as NSString).length
            let safeStart = max(0, min(newStart, updatedLength))
            let safeLength = min(block.length, updatedLength - safeStart)

            textView.setSelectedRange(
                NSRange(location: safeStart, length: safeLength)
            )
            textView.scrollRangeToVisible(
                NSRange(location: safeStart, length: safeLength)
            )
        }

        deinit {
            if let fontKeyMonitor {
                NSEvent.removeMonitor(fontKeyMonitor)
            }
        }


        private func selectedLineBlock(in textView: NSTextView) -> NSRange {
            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let start = min(selection.location, source.length)

            let first = source.lineRange(
                for: NSRange(location: start, length: 0)
            )

            let lastPosition = selection.length > 0
                ? min(NSMaxRange(selection) - 1, source.length)
                : start

            let last = source.lineRange(
                for: NSRange(location: lastPosition, length: 0)
            )

            return NSRange(
                location: first.location,
                length: NSMaxRange(last) - first.location
            )
        }

        private func replaceSelectedLines(
            in textView: NSTextView,
            transform: (String) -> String
        ) {
            let source = textView.string as NSString
            let block = selectedLineBlock(in: textView)
            let replacement = transform(source.substring(with: block))

            textView.insertText(
                replacement,
                replacementRange: block
            )

            textView.setSelectedRange(
                NSRange(
                    location: block.location,
                    length: (replacement as NSString).length
                )
            )
        }

        private func toggleLineComments(in textView: NSTextView) {
            replaceSelectedLines(in: textView) { block in
                var lines = block.components(separatedBy: "\n")

                let nonEmpty = lines.filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

                let uncomment = !nonEmpty.isEmpty && nonEmpty.allSatisfy { line in
                    let indent = line.prefix {
                        $0 == " " || $0 == "\t"
                    }
                    return line.dropFirst(indent.count).hasPrefix("//")
                }

                for index in lines.indices {
                    let line = lines[index]
                    let indent = String(line.prefix {
                        $0 == " " || $0 == "\t"
                    })
                    let content = String(line.dropFirst(indent.count))

                    guard !content.isEmpty else { continue }

                    if uncomment {
                        if content.hasPrefix("//") {
                            var remainder = String(content.dropFirst(2))
                            if remainder.hasPrefix(" ") {
                                remainder.removeFirst()
                            }
                            lines[index] = indent + remainder
                        }
                    } else {
                        lines[index] = indent + "// " + content
                    }
                }

                return lines.joined(separator: "\n")
            }
        }

        private func changeIndentation(
            in textView: NSTextView,
            outdent: Bool
        ) {
            let selection = textView.selectedRange()

            if selection.length == 0 {
                guard !outdent else { return }
                textView.insertText(
                    "    ",
                    replacementRange: selection
                )
                return
            }

            replaceSelectedLines(in: textView) { block in
                let lines = block.components(separatedBy: "\n")

                return lines.map { line in
                    if !outdent {
                        return "    " + line
                    }

                    if line.hasPrefix("    ") {
                        return String(line.dropFirst(4))
                    }

                    if line.hasPrefix("\t") {
                        return String(line.dropFirst())
                    }

                    let spaces = line.prefix { $0 == " " }.count
                    return String(line.dropFirst(min(4, spaces)))
                }
                .joined(separator: "\n")
            }
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
            else {
                return false
            }

            let source = textView.string as NSString
            let selection = textView.selectedRange()
            let location = min(selection.location, source.length)

            let lineRange = source.lineRange(
                for: NSRange(location: location, length: 0)
            )
            let currentLine = source.substring(with: lineRange)
            let trimmedLine = currentLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            var leadingWhitespace = ""
            for character in currentLine {
                if character == " " || character == "\t" {
                    leadingWhitespace.append(character)
                } else {
                    break
                }
            }

            // Find the latest module declaration before the cursor.
            let prefix = source.substring(to: location) as NSString
            let moduleRegex = try! NSRegularExpression(
                pattern: #"(?m)^\s*module\b"#
            )
            let moduleMatches = moduleRegex.matches(
                in: prefix as String,
                range: NSRange(location: 0, length: prefix.length)
            )

            var moduleIndent = ""
            var insideModulePorts = false

            if let lastModule = moduleMatches.last {
                let moduleLineRange = prefix.lineRange(
                    for: lastModule.range
                )
                let moduleLine = prefix.substring(
                    with: moduleLineRange
                )

                moduleIndent = String(
                    moduleLine.prefix {
                        $0 == " " || $0 == "\t"
                    }
                )

                let headerStart = moduleLineRange.location
                let header = prefix.substring(
                    from: headerStart
                )

                let openCount = header.filter { $0 == "(" }.count
                let closeCount = header.filter { $0 == ")" }.count

                insideModulePorts = openCount > closeCount
            }

            var nextIndent = leadingWhitespace

            // A closing ");" returns to the module declaration level.
            if trimmedLine.hasSuffix(");") {
                nextIndent = moduleIndent
            } else if insideModulePorts {
                // Port declarations are one level inside the module header.
                nextIndent = moduleIndent + "    "
            } else {
                let closingPattern =
                    #"^(endmodule|endcase|endfunction|endtask|endgenerate|end|join_any|join_none|join)\b"#

                let isClosingLine = trimmedLine.range(
                    of: closingPattern,
                    options: .regularExpression
                ) != nil

                if isClosingLine {
                    if nextIndent.hasSuffix("    ") {
                        nextIndent.removeLast(4)
                    } else if nextIndent.hasSuffix("\t") {
                        nextIndent.removeLast()
                    }
                } else {
                    let opensBlock =
                        trimmedLine.range(
                            of: #"\b(begin|generate|fork)\s*$"#,
                            options: .regularExpression
                        ) != nil
                        || trimmedLine.range(
                            of: #"\b(case|casex|casez)\b.*\)\s*$"#,
                            options: .regularExpression
                        ) != nil
                        || trimmedLine.range(
                            of: #"^(function|task)\b"#,
                            options: .regularExpression
                        ) != nil

                    if opensBlock {
                        nextIndent += "    "
                    }
                }
            }

            textView.insertText(
                "\n" + nextIndent,
                replacementRange: selection
            )

            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else {
                return
            }

            let newText = tv.string

            textChangeWork?.cancel()

            let work = DispatchWorkItem { [weak self, weak tv] in
                guard let self, let tv else { return }

                guard tv.string == newText else { return }

                if self.parent.text != newText {
                    self.parent.text = newText
                }

                self.textChangeWork = nil
            }

            textChangeWork = work
            DispatchQueue.main.async(execute: work)

            scheduleHighlight(in: tv)
        }

        private func scheduleHighlight(in tv: NSTextView) {
            highlightWork?.cancel()

            let work = DispatchWorkItem { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.highlight(in: tv)
            }

            highlightWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.08,
                execute: work
            )
        }

        func highlight(in tv: NSTextView) {
            guard let layoutManager = tv.layoutManager else {
                return
            }

            let source = tv.string
            let ns = source as NSString
            let fullRange = NSRange(location: 0, length: ns.length)

            guard fullRange.length > 0 else {
                return
            }

            layoutManager.removeTemporaryAttribute(
                .foregroundColor,
                forCharacterRange: fullRange
            )

            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor.textColor,
                forCharacterRange: fullRange
            )

            for token in VerilogSyntax.tokens(in: source)
            where NSIntersectionRange(token.range, fullRange).length > 0 {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: token.color,
                    forCharacterRange: token.range
                )
            }

            findEngine.render(in: tv)
            tv.needsDisplay = true
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 54, weight: .thin)).foregroundStyle(.tint)
            Text("Verilog IDE").font(.largeTitle.weight(.semibold))
            Text("Open a project, write the design and testbench, press ⌘R.").foregroundStyle(.secondary)
            HStack {
                Button("Open Folder…") { app.openFolderPanel() }.keyboardShortcut(.defaultAction)
                Button("New Project…") { app.sheet = .newSimProject }
                Button("New FPGA Project…") { app.sheet = .newFPGAProject }
            }.controlSize(.large)
            if !app.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(app.recentProjects.prefix(5), id: \.self) { u in Button(u.lastPathComponent) { app.addRoot(u) }.buttonStyle(.link) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: Bottom panel
struct BottomPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(BottomTab.allCases) { t in
                            Button { app.bottomTab = t } label: {
                                HStack(spacing: 4) { Image(systemName: t.icon); Text(t == .problems && !app.diagnostics.isEmpty ? "Problems (\(app.diagnostics.count))" : t.title) }
                                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(app.bottomTab == t ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Button { app.clearCurrentBottomTab() } label: { Image(systemName: "eraser") }
                    .buttonStyle(.borderless).help("Clear current tab: \(app.bottomTab.title)")
                Button { app.showBottomPanel = false } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("Collapse panel")
            }.padding(.horizontal, 8).padding(.vertical, 3)
            Divider()
            Group {
                switch app.bottomTab {
                case .terminal: TerminalPanel(manager: app.terminals)
                case .problems: ProblemsPanel()
                case .simulation: SimulationPanel()
                case .output: ClearableLogPanel(channel: .output, title: "Output")
                case .signals: SignalsPanel()
                case .synthesis: StagePanel(stage: .synthesis)
                case .implementation: StagePanel(stage: .implementation)
                case .timing: TimingPanel()
                case .hardware: HardwarePanel()
                case .history: HistoryPanel()
                case .search: SearchPanel()
                }
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

struct ClearableLogPanel: View {
    @EnvironmentObject var app: AppState
    let channel: LogChannel
    let title: String
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Button("Clear") { app.clearLog(channel) }.controlSize(.small).disabled((app.logs[channel] ?? []).isEmpty)
            }.padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            LogView(lines: app.logs[channel] ?? [])
        }
    }
}

struct LogView: View {
    let lines: [LogLine]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { l in
                        Text(l.text).font(.system(.caption, design: .monospaced)).foregroundStyle(color(l.kind)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).id(l.id)
                    }
                }.padding(8)
            }
            .onChange(of: lines.count) { _, _ in if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }
    func color(_ k: LogLine.Kind) -> Color {
        switch k { case .command: return .accentColor; case .error: return .red; case .info: return .orange; case .success: return .green; case .output: return .primary }
    }
}

struct ProblemsPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(app.diagnostics.count) issue(s)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { app.diagnostics.removeAll() }.disabled(app.diagnostics.isEmpty).controlSize(.small)
            }.padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            if app.diagnostics.isEmpty {
                ContentUnavailableView("No Problems", systemImage: "checkmark.circle", description: Text("Build and simulation diagnostics will appear here."))
            } else {
                List(app.diagnostics) { d in
                    HStack(alignment: .top) {
                        Image(systemName: d.severity == .error ? "xmark.octagon.fill" : d.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(d.severity == .error ? .red : d.severity == .warning ? .yellow : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.message).font(.callout)
                            Text(d.hasLocation ? "\(URL(fileURLWithPath: d.file).lastPathComponent):\(d.line)  ·  \(d.source)" : d.source).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if d.hasLocation { Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary) }
                    }.contentShape(Rectangle()).onTapGesture { app.navigate(to: d) }
                }.listStyle(.plain)
            }
        }
    }
}

struct SimulationPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: app.isBusy && app.busyLabel == "Simulating" ? "hourglass" : "checkmark.circle").foregroundStyle(.secondary)
                Text(app.statusText).font(.callout)
                Spacer()
                if let v = app.lastVCD { Text("\(v.url.lastPathComponent) · \(v.variables.count) signals · \(ByteCountFormatter.string(fromByteCount: Int64(v.bytes), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                    Button("Open in GTKWave") { app.openWaveform() }.controlSize(.small) }
                Button("Copy All") {
                    let content = (app.logs[.sim] ?? [])
                        .map(\.text)
                        .joined(separator: "\n")

                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                }
                .controlSize(.small)
                .disabled((app.logs[.sim] ?? []).isEmpty)
                .help("Copy all simulation output")

                Button("Clear") {
                    app.clearLog(.sim)
                }
                .controlSize(.small)
                .disabled((app.logs[.sim] ?? []).isEmpty)
            }.padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            LogView(lines: app.logs[.sim] ?? [])
        }
    }
}

struct SignalsPanel: View {
    @EnvironmentObject var app: AppState
    @State private var editingOrder = false
    private var ordered: [VCDVariable] {
        guard let v = app.lastVCD else { return [] }

        // A VCD can declare the same logical net in the testbench and DUT.
        // Keep one row per name, preferring the shallowest (testbench) scope.
        // Filtering the original array preserves the established signal order.
        let parsed = v.orderedVariables
        var preferredByName: [String: VCDVariable] = [:]
        for signal in parsed {
            if let current = preferredByName[signal.name] {
                if signal.scopePath.count < current.scopePath.count {
                    preferredByName[signal.name] = signal
                }
            } else {
                preferredByName[signal.name] = signal
            }
        }
        let base = parsed.filter { preferredByName[$0.name]?.id == $0.id }

        guard !app.signalOrder.isEmpty else { return base }
        let byID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        return app.signalOrder.compactMap { byID[$0] } + base.filter { !app.signalOrder.contains($0.id) }
    }
    var body: some View {
        if app.lastVCD != nil {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Signal order").font(.callout.weight(.semibold))
                    Text("Clock → Reset → Control → Inputs → Outputs").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(editingOrder ? "Done" : "Reorder") { editingOrder.toggle() }.controlSize(.small)
                    Button("All") { app.selectedSignals = Set(ordered.map(\.id)) }.controlSize(.small)
                    Button("None") { app.selectedSignals = [] }.controlSize(.small)
                    Button("Clear") { app.selectedSignals = []; app.lastVCD = nil; app.signalOrder = [] }.controlSize(.small)
                    Button("Open") { app.openWaveform() }.controlSize(.small).buttonStyle(.borderedProminent)
                }.padding(8)
                Text("Only selected signals are written to GTKWave. Drag rows while Reorder is active to customize their order.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 5).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                List {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, signal in
                        HStack(spacing: 8) {
                            Toggle(isOn: Binding(get: { app.selectedSignals.contains(signal.id) }, set: { on in
                                if on { app.selectedSignals.insert(signal.id) } else { app.selectedSignals.remove(signal.id) }
                            })) {
                                HStack(spacing: 8) {
                                    Text(signal.name).font(.system(.callout, design: .monospaced))
                                    Text(signal.width > 1 ? "[\(signal.width - 1):0]" : "").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(signal.kind.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                                    Text(signal.scopePath.joined(separator: ".")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }.toggleStyle(.checkbox)

                            if editingOrder {
                                Button { app.moveSignal(from: IndexSet(integer: index), to: max(0, index - 1), in: ordered) } label: {
                                    Image(systemName: "arrow.up").frame(width: 20)
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                Button { app.moveSignal(from: IndexSet(integer: index), to: min(ordered.count, index + 2), in: ordered) } label: {
                                    Image(systemName: "arrow.down").frame(width: 20)
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == ordered.count - 1)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        } else {
            ContentUnavailableView("No Waveform Signals", systemImage: "waveform", description: Text("Run a simulation to inspect the testbench signals."))
        }
    }
}

struct StagePanel: View {
    @EnvironmentObject var app: AppState
    let stage: FPGAStage
    var body: some View {
        let rs: ReportStage = stage == .synthesis ? .synthesis : .implementation
        let entries = app.resources.filter { $0.stage == rs }
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Resource utilization").font(.headline)
                    Text(rs == .synthesis ? "ESTIMATED (post-synthesis)" : "FINAL (post-route)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(rs == .synthesis ? Color.orange.opacity(0.25) : Color.green.opacity(0.25), in: Capsule()) }
                if entries.isEmpty { Text("No \(stage.title.lowercased()) report yet. Values appear only when the tool reports them.").font(.callout).foregroundStyle(.secondary) }
                else {
                    let withCap = entries.filter { $0.percent != nil }
                    if !withCap.isEmpty {
                        Chart(withCap.prefix(10)) { e in BarMark(x: .value("Used %", e.percent ?? 0), y: .value("Resource", e.name)).foregroundStyle(by: .value("r", e.name)) }
                            .chartXScale(domain: 0...100).chartLegend(.hidden).frame(height: min(220, CGFloat(withCap.prefix(10).count) * 24 + 30))
                    }
                    List(entries) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(e.name).font(.callout); Spacer()
                                Text(e.available.map { "\(e.used) / \($0)" } ?? "\(e.used)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                            if let p = e.percent { ProgressView(value: min(100, p), total: 100).tint(p > 85 ? .red : p > 60 ? .orange : .accentColor) }
                        }
                    }.listStyle(.plain)
                }
            }.padding(10).frame(minWidth: 320)
            VStack(spacing: 0) {
                HStack {
                    Text("Tool output").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Clear") { app.clearLog(stage == .synthesis ? .synthesis : .implementation) }.controlSize(.small)
                }.padding(.horizontal, 10).padding(.vertical, 5)
                Divider()
                LogView(lines: app.logs[stage == .synthesis ? .synthesis : .implementation] ?? [])
            }
        }
    }
}

struct TimingPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let t = app.timing {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(t.constraintsMet == true ? "Timing constraints met" : t.constraintsMet == false ? "Timing constraints NOT met" : "Timing status not reported",
                          systemImage: t.constraintsMet == true ? "checkmark.seal.fill" : t.constraintsMet == false ? "xmark.seal.fill" : "questionmark.circle")
                        .foregroundStyle(t.constraintsMet == true ? .green : t.constraintsMet == false ? .red : .secondary).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                        row("Worst setup slack (WNS)", t.wns, "ns"); row("Total setup slack (TNS)", t.tns, "ns")
                        row("Worst hold slack (WHS)", t.whs, "ns"); row("Total hold slack (THS)", t.ths, "ns")
                        GridRow { Text("Failing setup / hold endpoints"); Text("\(t.failingSetupEndpoints.map(String.init) ?? "—") / \(t.failingHoldEndpoints.map(String.init) ?? "—")") }
                        if let f = t.derivedFmaxMHz { GridRow { Text("Fmax (derived from period − WNS)"); Text(String(format: "%.1f MHz", f)) } }
                    }.font(.callout)
                    if !t.clocks.isEmpty {
                        Text("Clocks").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 20) {
                            GridRow { Text("Name").bold(); Text("Period").bold(); Text("Frequency").bold() }
                            ForEach(t.clocks) { c in GridRow { Text(c.name); Text(String(format: "%.3f ns", c.periodNs)); Text(String(format: "%.2f MHz", c.frequencyMHz)) } }
                        }.font(.callout)
                    }
                    if let p = t.criticalPath {
                        Text("Critical path").font(.headline)
                        if let s = p.slackNs { Text("Slack: \(String(format: "%.3f", s)) ns (\(p.met == true ? "MET" : "VIOLATED"))").font(.callout) }
                        if let s = p.source { Text("From: \(s)").font(.caption).textSelection(.enabled) }
                        if let d = p.destination { Text("To: \(d)").font(.caption).textSelection(.enabled) }
                        Text("Vivado reports cell names, not source lines, so jumping to source is not available.").font(.caption2).foregroundStyle(.secondary)
                        DisclosureGroup("Full path report") { Text(p.rawText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                    }
                    if !app.drcLines.isEmpty { DisclosureGroup("DRC messages (\(app.drcLines.count))") { ForEach(app.drcLines, id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)) } } }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else { Text("No timing report yet. Run Implement.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    @ViewBuilder func row(_ n: String, _ v: Double?, _ u: String) -> some View {
        GridRow { Text(n); Text(v.map { String(format: "%.3f %@", $0, u) } ?? "—").foregroundStyle((v ?? 0) < 0 ? .red : .primary) }
    }
}

struct HardwarePanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Button("Detect Hardware") { app.detectHardware() }.buttonStyle(.borderedProminent).disabled(app.isBusy)
                    Button("Program FPGA…") { app.runFPGA(.program) }.disabled(app.isBusy) }
                Text("JTAG devices").font(.headline)
                if app.detected.isEmpty { Text("None identified. A USB device alone is not proof of a reachable FPGA.").font(.caption).foregroundStyle(.secondary) }
                ForEach(app.detected) { d in Label("\(d.model ?? "unknown model") — idcode \(d.idcode) \(d.family.map { "(\($0))" } ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
                Text("USB devices").font(.headline)
                List(app.usbDevices) { u in HStack { Text(u.name).font(.callout); Spacer(); if u.maybeJTAG { Text("FTDI · possible JTAG").font(.caption2).foregroundStyle(.orange) }
                    Text("\(u.vendorID) \(u.productID)").font(.caption2).foregroundStyle(.secondary) } }.listStyle(.plain)
            }.padding(10).frame(minWidth: 340)
            VStack(spacing: 0) {
                HStack {
                    Text("Hardware output").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Clear") { app.clearLog(.hardware) }.controlSize(.small)
                }.padding(.horizontal, 10).padding(.vertical, 5)
                Divider()
                LogView(lines: app.logs[.hardware] ?? [])
            }
        }
    }
}

struct HistoryPanel: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Build & simulation history").font(.callout.weight(.semibold))
                Spacer()
                Button("Clear") { app.clearHistory() }.controlSize(.small).disabled(app.history.isEmpty)
            }.padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            if app.history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath", description: Text("Build and simulation runs will be recorded here."))
            } else {
                List(app.history) { r in
                    HStack { Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.success ? .green : .red)
                        Text(r.stage).fontWeight(.medium); Text(r.summary).foregroundStyle(.secondary).lineLimit(1); Spacer()
                        Text(String(format: "%.1f s", r.duration)).font(.caption).foregroundStyle(.secondary)
                        Text(r.started.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                }.listStyle(.plain)
            }
        }
    }
}

struct SearchPanel: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            TextField("Find in files", text: $query).textFieldStyle(.roundedBorder).padding(8).onSubmit { app.searchProject(query) }
            Divider()
            List(app.searchResults) { h in
                VStack(alignment: .leading) { Text(h.text).font(.system(.callout, design: .monospaced)).lineLimit(1)
                    Text("\(h.url.lastPathComponent):\(h.line)").font(.caption).foregroundStyle(.secondary) }
                    .contentShape(Rectangle()).onTapGesture { app.openFile(h.url, line: h.line) }
            }.listStyle(.plain)
        }
    }
}

struct CommandPalette: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @FocusState private var focused: Bool
    var filtered: [PaletteCommand] { query.isEmpty ? app.paletteCommands : app.paletteCommands.filter { $0.title.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command", text: $query).textFieldStyle(.plain).font(.title3).padding(12).focused($focused)
                .onSubmit { if let c = filtered.first { app.showPalette = false; c.action() } }
                .onExitCommand { app.showPalette = false }
            Divider()
            ScrollView { VStack(spacing: 0) {
                ForEach(filtered) { c in
                    HStack { Text(c.title); Spacer(); Text(c.shortcut).foregroundStyle(.secondary).font(.caption) }
                        .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle()).onTapGesture { app.showPalette = false; c.action() }
                }
            } }.frame(maxHeight: 280)
        }
        .frame(width: 520).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator)).shadow(radius: 24)
        .onAppear { focused = true; query = "" }
    }
}
