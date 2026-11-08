
import SwiftUI
import AppKit

enum EditorFindReplaceMode: String {
    case find = "Find"
    case replace = "Replace"
}

struct EditorFindReplaceBar: View {
    @Binding var isPresented: Bool
    @Binding var mode: EditorFindReplaceMode
    @Binding var query: String
    @Binding var replacement: String
    @Binding var nextRevision: Int
    @Binding var previousRevision: Int
    @Binding var replaceRevision: Int
    @Binding var replaceAllRevision: Int

    @FocusState private var findFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Find") { mode = .find }
                Button("Replace") { mode = .replace }
            } label: {
                HStack(spacing: 5) {
                    Text(mode.rawValue)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
                .frame(width: 75, alignment: .leading)
            }
            .menuStyle(.borderlessButton)

            TextField("Find", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 210, maxWidth: 260)
                .focused($findFocused)
                .onSubmit { nextRevision += 1 }

            Button {
                previousRevision += 1
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("Previous match")
            .disabled(query.isEmpty)

            Button {
                nextRevision += 1
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Next match")
            .disabled(query.isEmpty)

            if mode == .replace {
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, idealWidth: 170, maxWidth: 210)
                    .onSubmit { replaceRevision += 1 }

                Button("Replace") {
                    replaceRevision += 1
                }
                .disabled(query.isEmpty)

                Button("Replace All") {
                    replaceAllRevision += 1
                }
                .disabled(query.isEmpty)
            }

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close Find")

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { findFocused = true }
        .onExitCommand { isPresented = false }
    }
}

final class EditorFindReplaceEngine {
    private var matches: [NSRange] = []
    private var activeIndex: Int?

    private var previousQuery: String?
    private var previousText: String?

    private var nextRevision = 0
    private var previousRevision = 0
    private var replaceRevision = 0
    private var replaceAllRevision = 0

    private weak var flashTextView: NSTextView?
    private var flashRange: NSRange?
    private var flashAlpha: CGFloat = 0
    private var flashGeneration = 0

    func update(
        textView: NSTextView,
        isPresented: Bool,
        query: String,
        replacement: String,
        next: Int,
        previous: Int,
        replace: Int,
        replaceAll: Int
    ) {
        guard isPresented else {
            clear(in: textView)
            return
        }

        let text = textView.string
        let queryChanged = previousQuery != query
        let textChanged = previousText != text

        if queryChanged || textChanged {
            previousQuery = query
            previousText = text
            rebuildMatches(in: textView, query: query)

            if !matches.isEmpty {
                navigate(to: 0, in: textView)
            } else {
                activeIndex = nil
            }
        }

        if next != nextRevision {
            nextRevision = next
            navigateNext(in: textView)
        }

        if previous != previousRevision {
            previousRevision = previous
            navigatePrevious(in: textView)
        }

        if replace != replaceRevision {
            replaceRevision = replace
            replaceCurrent(in: textView, replacement: replacement)
        }

        if replaceAll != replaceAllRevision {
            replaceAllRevision = replaceAll
            replaceEverything(in: textView, replacement: replacement)
        }

        render(in: textView)
    }

    private func rebuildMatches(in textView: NSTextView, query: String) {
        matches.removeAll()
        activeIndex = nil

        guard !query.isEmpty else { return }

        let source = textView.string as NSString
        var position = 0

        while position < source.length {
            let searchRange = NSRange(
                location: position,
                length: source.length - position
            )

            let found = source.range(
                of: query,
                options: [.caseInsensitive],
                range: searchRange
            )

            guard found.location != NSNotFound, found.length > 0 else {
                break
            }

            matches.append(found)
            position = NSMaxRange(found)
        }
    }

    private func navigateNext(in textView: NSTextView) {
        guard !matches.isEmpty else { return }
        let index = activeIndex.map { ($0 + 1) % matches.count } ?? 0
        navigate(to: index, in: textView)
    }

    private func navigatePrevious(in textView: NSTextView) {
        guard !matches.isEmpty else { return }
        let index = activeIndex.map {
            ($0 - 1 + matches.count) % matches.count
        } ?? (matches.count - 1)

        navigate(to: index, in: textView)
    }

    private func navigate(to index: Int, in textView: NSTextView) {
        guard matches.indices.contains(index) else { return }

        activeIndex = index
        let range = matches[index]

        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)

        startLineFlash(for: range, in: textView)
        render(in: textView)
    }

    private func replaceCurrent(
        in textView: NSTextView,
        replacement: String
    ) {
        guard
            let index = activeIndex,
            matches.indices.contains(index)
        else {
            navigateNext(in: textView)
            return
        }

        textView.insertText(
            replacement,
            replacementRange: matches[index]
        )

        previousText = nil
    }

    private func replaceEverything(
        in textView: NSTextView,
        replacement: String
    ) {
        guard !matches.isEmpty else { return }

        let source = textView.string as NSString
        let updated = NSMutableString(string: source)

        for range in matches.reversed() {
            updated.replaceCharacters(in: range, with: replacement)
        }

        textView.insertText(
            updated as String,
            replacementRange: NSRange(location: 0, length: source.length)
        )

        previousText = nil
    }

    private func startLineFlash(
        for match: NSRange,
        in textView: NSTextView
    ) {
        flashTextView = textView

        let source = textView.string as NSString
        flashRange = source.lineRange(for: match)
        flashAlpha = 0.24
        flashGeneration += 1

        let generation = flashGeneration
        let alphaSteps: [CGFloat] = [0.18, 0.12, 0.06, 0]

        for (index, alpha) in alphaSteps.enumerated() {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(index + 1) * 0.18
            ) { [weak self, weak textView] in
                guard
                    let self,
                    let textView,
                    self.flashGeneration == generation
                else { return }

                self.flashAlpha = alpha

                if alpha == 0 {
                    self.flashRange = nil
                }

                self.render(in: textView)
            }
        }
    }

    func render(in textView: NSTextView) {
        guard
            let layoutManager = textView.layoutManager,
            textView.layoutManager != nil
        else { return }

        let source = textView.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        guard fullRange.length > 0 else { return }

        layoutManager.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: fullRange
        )

        if let flashRange,
           flashAlpha > 0,
           NSMaxRange(flashRange) <= source.length {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(flashAlpha),
                forCharacterRange: flashRange
            )
        }

        for (index, match) in matches.enumerated()
        where NSMaxRange(match) <= source.length {
            let color = index == activeIndex
                ? NSColor.controlAccentColor.withAlphaComponent(0.42)
                : NSColor.systemYellow.withAlphaComponent(0.28)

            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: color,
                forCharacterRange: match
            )
        }

        textView.needsDisplay = true
    }

    private func clear(in textView: NSTextView) {
        let source = textView.string as NSString
        let range = NSRange(location: 0, length: source.length)

        if range.length > 0 {
            textView.layoutManager?.removeTemporaryAttribute(
                .backgroundColor,
                forCharacterRange: range
            )
        }

        matches.removeAll()
        activeIndex = nil
        previousQuery = nil
        previousText = nil

        flashGeneration += 1
        flashRange = nil
        flashAlpha = 0

        textView.needsDisplay = true
    }
}
