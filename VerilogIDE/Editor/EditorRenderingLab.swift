import SwiftUI
import AppKit
import VerilogIDECore

/// Minimal AppKit control used to distinguish an AppKit/TextKit rendering problem
/// from a problem in the production CodeEditor wrapper.
private struct PlainAppKitTextViewProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("AppKit did not create an NSTextView document view.")
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .controlAccentColor
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.string = """
        // Plain AppKit / TextKit rendering probe
        module mux2 (
            input  wire a,
            input  wire b,
            input  wire sel,
            output wire y
        );
            assign y = sel ? b : a;
        endmodule
        """
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

private struct ProductionEditorPreview: View {
    @State private var source = """
    // Production CodeEditor preview
    module mux2 (
        input  wire a,
        input  wire b,
        input  wire sel,
        output wire y
    );
        assign y = sel ? b : a;
    endmodule
    """

    var body: some View {
        CodeEditor(
            text: $source,
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            diagnostics: [],
            jump: nil,
            fileURL: URL(fileURLWithPath: "/tmp/mux2.v")
        )
        .frame(minWidth: 600, minHeight: 360)
    }
}

#Preview("AppKit TextKit — Minimal Probe") {
    PlainAppKitTextViewProbe()
        .frame(minWidth: 600, minHeight: 360)
}

#Preview("Production CodeEditor") {
    ProductionEditorPreview()
        .frame(minWidth: 600, minHeight: 360)
}
