import SwiftUI
import AppKit
import VerilogIDECore

enum VerilogSyntax {
    static let keywords = """
    module endmodule input output inout wire reg integer real time parameter localparam assign always initial begin end if else case casex casez endcase default
    for while repeat forever posedge negedge or and not nand nor xor xnor buf function endfunction task endtask generate endgenerate genvar fork join
    signed unsigned supply0 supply1 tri wand wor defparam specify endspecify primitive endprimitive table endtable disable wait force release deassign
    logic bit byte int shortint longint string enum struct union typedef packed always_ff always_comb always_latch interface endinterface modport
    package endpackage import export class endclass program endprogram unique priority return break continue void automatic static virtual extends new null
    assert assume cover property sequence endproperty endsequence clocking endclocking rand randc constraint solve before inside dist matches tagged
    """
    .split(whereSeparator: \.isWhitespace)
    .map(String.init)

    static let constructs = [
        "always @(posedge clk) begin",
        "always @(*) begin",
        "initial begin",
        "case (",
        "for (i = 0; i < N; i = i + 1) begin",
        "$display(",
        "$monitor(",
        "$finish;",
        "$dumpfile(\"waveform.vcd\");",
        "$dumpvars(0, tb);",
        "`timescale 1ns/1ps",
        "`include \"",
        "`define "
    ]

    static let tasks = [
        "$display", "$monitor", "$strobe", "$write", "$finish", "$stop",
        "$time", "$random", "$dumpfile", "$dumpvars", "$readmemh",
        "$readmemb", "$fatal", "$error", "$warning", "$signed",
        "$unsigned", "$clog2", "$urandom"
    ]

    struct Token {
        let range: NSRange
        let color: NSColor
    }

    private static let keywordSet = Set(keywords)
    private static let dataTypeSet: Set<String> = [
        "wire", "reg", "logic", "bit", "byte", "int", "shortint",
        "longint", "integer", "real", "time", "string"
    ]

    private static let declarationKeywords: Set<String> = [
        "module", "interface", "package", "function", "task",
        "class", "primitive", "program"
    ]

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"(?s)//[^\n]*|/\*.*?(?:\*/|$)|"(?:\\.|[^"\\])*"?|`[A-Za-z_]\w*|\$[A-Za-z_]\w*|\d+'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_?]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?|[A-Za-z_][A-Za-z0-9_$]*|===|!==|==|!=|<=|>=|&&|\|\||<<|>>>|>>|\*\*|[+\-*/%&|^~!<>=?:]"#
    )

    static func tokens(in source: String) -> [Token] {
        let ns = source as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var result: [Token] = []
        var expectsDeclarationName = false

        tokenRegex.enumerateMatches(
            in: source,
            range: fullRange
        ) { match, _, _ in
            guard let match else { return }

            let range = match.range
            let value = ns.substring(with: range)
            let lower = value.lowercased()

            let color: NSColor?

            if value.hasPrefix("//") || value.hasPrefix("/*") {
                color = .systemGreen
            } else if value.hasPrefix("\"") {
                color = .systemRed
            } else if value.hasPrefix("`") {
                color = .systemOrange
            } else if value.hasPrefix("$") {
                color = .systemTeal
            } else if value.first?.isNumber == true {
                color = .systemBlue
            } else if dataTypeSet.contains(lower) {
                color = .systemPurple
            } else if keywordSet.contains(lower) {
                color = .systemPink
            } else if value.range(
                of: #"^[A-Za-z_][A-Za-z0-9_$]*$"#,
                options: .regularExpression
            ) != nil {
                color = expectsDeclarationName ? .systemTeal : nil
            } else {
                color = .systemIndigo
            }

            if let color {
                result.append(Token(range: range, color: color))
            }

            if declarationKeywords.contains(lower) {
                expectsDeclarationName = true
            } else if value.range(
                of: #"^[A-Za-z_][A-Za-z0-9_$]*$"#,
                options: .regularExpression
            ) != nil {
                expectsDeclarationName = false
            } else if value == ";" {
                expectsDeclarationName = false
            }
        }

        return result
    }
}

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var diagnostics: [Diagnostic]
    var jump: JumpRequest?
    var fileURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Use AppKit's supported scrolling-text-view factory so the scroll view,
        // clip view, text view, and TextKit objects are connected by AppKit.
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        guard let tv = scroll.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() did not provide an NSTextView document view")
        }

        let viewportSize = scroll.contentSize

        // Configure the standard TextKit stack using the viewport's real width.
        // Do not set an infinite container width while widthTracksTextView is on.
        tv.frame = NSRect(origin: .zero, size: viewportSize)
        tv.minSize = NSSize(width: 0, height: viewportSize.height)
        tv.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(
            width: viewportSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.textContainer?.widthTracksTextView = true

        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textColor = .textColor
        tv.insertionPointColor = .controlAccentColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.font = font
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        tv.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )

        let ruler = LineNumberRuler(scrollView: scroll, textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.attach(tv, ruler, scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView,
              let storage = tv.textStorage else { return }

        let coordinator = context.coordinator
        coordinator.parent = self

        // Let NSScrollView/NSTextView manage their own frames. SwiftUI owns the
        // outer scroll-view frame; manually calling tile()/setFrameSize() here
        // fights AppKit's text-view resizing and can leave text outside the clip view.
        tv.isEditable = true
        tv.isSelectable = true
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.typingAttributes[.font] = font
        tv.typingAttributes[.foregroundColor] = NSColor.textColor

        if tv.string != text {
            let selection = tv.selectedRange()
            let safeLocation = min(selection.location, (text as NSString).length)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.textColor
            ]
            storage.setAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            tv.setSelectedRange(NSRange(location: safeLocation, length: 0))
            coordinator.ruler?.invalidateLines()
            coordinator.scheduleHighlight(immediate: true)
        }

        if tv.font != font {
            tv.font = font
            let fullRange = NSRange(location: 0, length: storage.length)
            if fullRange.length > 0 {
                storage.addAttribute(.font, value: font, range: fullRange)
            }
            coordinator.ruler?.needsDisplay = true
            coordinator.scheduleHighlight(immediate: true)
        }

        let diagnosticKey = diagnostics.map { "\($0.line)\($0.severity.rawValue)" }.joined(separator: ",")
        if diagnosticKey != coordinator.lastDiagKey {
            coordinator.lastDiagKey = diagnosticKey
            coordinator.applyDecorations()
        }
        if let request = jump,
           request.token != coordinator.lastJump,
           request.url.standardizedFileURL == fileURL.standardizedFileURL {
            coordinator.lastJump = request.token
            coordinator.goto(line: request.line)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var tv: NSTextView?; weak var ruler: LineNumberRuler?; weak var scroll: NSScrollView?
        var lastJump: UUID?; var lastDiagKey = ""
        var bracketRanges: [NSRange] = []
        private var work: DispatchWorkItem?
        init(_ p: CodeEditor) { parent = p }

        func attach(_ tv: NSTextView, _ r: LineNumberRuler, _ s: NSScrollView) {
            self.tv = tv; ruler = r; scroll = s
            s.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: s.contentView)
            scheduleHighlight(immediate: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, let tv = self.tv, let lm = tv.layoutManager,
                      let tc = tv.textContainer else { return }
                lm.ensureLayout(for: tc)
                tv.needsDisplay = true
                self.ruler?.needsDisplay = true
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func scrolled() { scheduleHighlight(); ruler?.needsDisplay = true }

        func scheduleHighlight(immediate: Bool = false) {
            work?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.highlight(); self?.applyDecorations() }
            work = w
            if immediate { DispatchQueue.main.async(execute: w) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: w) }
        }

        // Highlights only the visible region (plus margin) so very large files stay responsive.
        // Uses temporary attributes: the text storage and the file contents are never modified.
        func highlight() {
            guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let ns = tv.string as NSString
            guard ns.length > 0 else { return }
            let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
            var range = ns.lineRange(for: lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            let start = max(0, range.location - 3000), end = min(ns.length, NSMaxRange(range) + 3000)
            range = NSRange(location: start, length: end - start)
            // include an unterminated block comment that begins above the region
            if range.location > 0 {
                let before = NSRange(location: 0, length: range.location)
                let open = ns.range(of: "/*", options: .backwards, range: before), close = ns.range(of: "*/", options: .backwards, range: before)
                if open.location != NSNotFound && (close.location == NSNotFound || open.location > close.location) {
                    range = NSRange(location: open.location, length: NSMaxRange(range) - open.location)
                }
            }
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            // Make the default foreground explicit in TextKit as well as on the view.
            // Syntax rules below override this for Verilog tokens.
            lm.addTemporaryAttribute(.foregroundColor, value: NSColor.labelColor, forCharacterRange: range)
            let str = ns as String
            for token in VerilogSyntax.tokens(in: str)
            where NSIntersectionRange(token.range, range).length > 0 {
                lm.addTemporaryAttribute(
                    .foregroundColor,
                    value: token.color,
                    forCharacterRange: token.range
                )
            }
        }

        func lineRange(_ n: Int, in ns: NSString) -> NSRange? {
            guard n >= 1 else { return nil }
            var line = 1, loc = 0
            while line < n { let r = ns.lineRange(for: NSRange(location: loc, length: 0)); loc = NSMaxRange(r); line += 1; if loc >= ns.length { return nil } }
            return ns.lineRange(for: NSRange(location: loc, length: 0))
        }

        func applyDecorations() {
            guard let tv, let lm = tv.layoutManager else { return }
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            for d in parent.diagnostics where d.severity != .note {
                guard let r = lineRange(d.line, in: ns) else { continue }
                let c: NSColor = d.severity == .error ? .systemRed : .systemYellow
                lm.addTemporaryAttribute(.backgroundColor, value: c.withAlphaComponent(0.14), forCharacterRange: r)
                lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, forCharacterRange: r)
                lm.addTemporaryAttribute(.underlineColor, value: c, forCharacterRange: r)
            }
            for r in bracketRanges where NSMaxRange(r) <= ns.length { lm.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55), forCharacterRange: r) }
        }

        func goto(line: Int) {
            guard let tv else { return }
            let ns = tv.string as NSString
            guard let r = lineRange(line, in: ns) else { return }
            let sel = NSRange(location: r.location, length: max(0, r.length - (ns.substring(with: r).hasSuffix("\n") ? 1 : 0)))
            tv.setSelectedRange(sel); tv.scrollRangeToVisible(sel); tv.showFindIndicator(for: sel)
            tv.window?.makeFirstResponder(tv)
        }

        // MARK: Delegate
        func textDidChange(_ n: Notification) {
            guard let tv else { return }
            parent.text = tv.string
            ruler?.invalidateLines(); scheduleHighlight()
        }

        func textViewDidChangeSelection(_ n: Notification) {
            guard let tv else { return }
            let ns = tv.string as NSString
            let sel = tv.selectedRange()
            bracketRanges = []
            if sel.length == 0, ns.length > 0 {
                let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
                let rev = Dictionary(uniqueKeysWithValues: pairs.map { ($0.value, $0.key) })
                for idx in [sel.location - 1, sel.location] where idx >= 0 && idx < ns.length {
                    guard let ch = Character(UnicodeScalar(ns.character(at: idx)) ?? " ") as Character? else { continue }
                    if let close = pairs[ch] {
                        if let m = scan(ns, from: idx, open: ch, close: close, forward: true) { bracketRanges = [NSRange(location: idx, length: 1), NSRange(location: m, length: 1)]; break }
                    } else if let open = rev[ch] {
                        if let m = scan(ns, from: idx, open: ch, close: open, forward: false) { bracketRanges = [NSRange(location: idx, length: 1), NSRange(location: m, length: 1)]; break }
                    }
                }
            }
            applyDecorations()
        }

        private func scan(_ ns: NSString, from: Int, open: Character, close: Character, forward: Bool) -> Int? {
            var depth = 0, i = from, steps = 0
            while i >= 0 && i < ns.length && steps < 20000 {
                let c = Character(UnicodeScalar(ns.character(at: i)) ?? " ")
                if c == open { depth += 1 } else if c == close { depth -= 1; if depth == 0 { return i } }
                i += forward ? 1 : -1; steps += 1
            }
            return nil
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
            let ns = textView.string as NSString
            let loc = textView.selectedRange().location
            let lr = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
            let before = ns.substring(with: NSRange(location: lr.location, length: max(0, loc - lr.location)))
            var indent = String(before.prefix { $0 == " " || $0 == "\t" })
            let t = before.trimmingCharacters(in: .whitespaces)
            let opens = t.range(of: #"\bbegin\b(\s*:\s*\w+)?$"#, options: .regularExpression) != nil ||
                        (t.range(of: #"^(module|function|task|generate|fork|case|casez|casex)\b"#, options: .regularExpression) != nil && !t.contains("end"))
            if opens { indent += "    " }
            textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
            return true
        }

        // Autocomplete on demand (Esc / ⌃Space / F5): keywords, system tasks, common constructs, document words.
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            let pool = VerilogSyntax.constructs + VerilogSyntax.keywords + VerilogSyntax.tasks + words
            var seen = Set<String>()
            return pool.filter { $0.hasPrefix(prefix) && $0 != prefix && seen.insert($0).inserted }
        }
    }
}

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var dirty = true

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView; ruleThickness = 48
    }
    required init(coder: NSCoder) { fatalError("not used") }

    func invalidateLines() { dirty = true; needsDisplay = true }

    private func rebuild() {
        dirty = false
        var starts = [0]; var i = 0
        for u in (textView?.string ?? "").utf16 { i += 1; if u == 10 { starts.append(i) } }
        lineStarts = starts
    }
    private func lineNumber(at loc: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if lineStarts[mid] <= loc { lo = mid } else { hi = mid - 1 } }
        return lo + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let sv = scrollView else { return }
        if dirty { rebuild() }
        NSColor.controlBackgroundColor.setFill(); rect.fill()
        NSColor.separatorColor.setFill(); NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let visible = sv.contentView.bounds, origin = tv.textContainerOrigin
        func draw(_ n: Int, _ frag: NSRect) {
            let s = "\(n)" as NSString, size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: frag.minY + origin.y - visible.minY + (frag.height - size.height) / 2), withAttributes: attrs)
        }
        if (tv.string as NSString).length == 0 { draw(1, NSRect(x: 0, y: 0, width: 0, height: (tv.font?.boundingRectForFont.height ?? 14))); return }
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        var g = glyphRange.location
        while g < NSMaxRange(glyphRange) {
            var lineRange = NSRange()
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &lineRange)
            let ci = lm.characterIndexForGlyph(at: lineRange.location)
            let n = lineNumber(at: ci)
            if lineStarts[n - 1] == ci { draw(n, frag) }
            g = NSMaxRange(lineRange)
        }
        let extra = lm.extraLineFragmentRect
        if extra.height > 0 { draw(lineStarts.count, extra) }
    }
}
