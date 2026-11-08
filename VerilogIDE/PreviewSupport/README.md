# Preview support

SwiftUI previews use Apple's `#Preview` macro. The main window preview creates an
in-memory `AppState`; the editor rendering lab provides two isolated previews:

- **AppKit TextKit — Minimal Probe**: a plain `NSTextView` in an `NSScrollView`.
- **Production CodeEditor**: the actual `CodeEditor` representable.

Compare these previews in Xcode Canvas. If the minimal probe renders but the
production editor does not, the fault is in the production editor wrapper,
ruler, coordinator, or its state binding. If both are blank, investigate the
AppKit/TextKit host and appearance/environment first.

Previews must not invoke Icarus, Vivado, GTKWave, shell commands, or hardware.
