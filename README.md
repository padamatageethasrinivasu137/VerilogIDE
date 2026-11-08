# VerilogIDE — Native macOS Xcode Project

VerilogIDE is a SwiftUI/AppKit macOS IDE for Verilog/SystemVerilog. The application
is a native Xcode project; its UI-independent engineering functionality is a
local Swift package.

## Requirements

- macOS 14 or later
- Xcode 15.3 or later (recommended: current stable Xcode)
- Icarus Verilog (`iverilog` and `vvp`) for simulation
- GTKWave for external waveform viewing (optional)
- Vivado / open-source FPGA tools only for the relevant FPGA workflows

## Open in Xcode

1. Open `VerilogIDE.xcodeproj`.
2. Select the `VerilogIDE` scheme and `My Mac` destination.
3. Build and run with **Product > Run** (`⌘R`).
4. Select a SwiftUI view source file and choose **Editor > Canvas** / **Show Canvas**.
5. Build the core package tests separately with `Scripts/test_all.sh`.

The project references `Packages/VerilogIDECore` as a local Swift package.
Do not move that directory independently of the Xcode project.

## Project layout

- `VerilogIDE/App`: app entry point and root content view
- `VerilogIDE/State`: application state and run workflows
- `VerilogIDE/Models`: app-facing UI models
- `VerilogIDE/Editor`: AppKit/TextKit editor and rendering diagnostics
- `VerilogIDE/Terminal`: integrated terminal UI/session integration
- `VerilogIDE/Views`: workspace and sheet views
- `VerilogIDE/PreviewSupport`: preview guidance and fixtures
- `Packages/VerilogIDECore`: UI-independent engine and unit tests
- `Samples`: Verilog sample projects
- `Scripts`: build and verification scripts

## Editor rendering investigation

Open `VerilogIDE/Editor/EditorRenderingLab.swift` in Xcode and show Canvas.
Compare **AppKit TextKit — Minimal Probe** with **Production CodeEditor**:

- If the minimal probe displays text but Production CodeEditor is blank, the
  problem is in the production wrapper/coordinator/ruler/state lifecycle.
- If both are blank, investigate AppKit/TextKit host setup and appearance.
- If both display, but the app's editor is blank, inspect `EditorPane` sizing,
  selected tab identity, and app state updates.

This diagnostic is intentionally separate from the production editor so it
doesn't conceal the root cause with another speculative rewrite.

## Build

```bash
Scripts/build_app.sh
```

## Tests

```bash
swift test --package-path Packages/VerilogIDECore
Scripts/verify_samples.sh
```

The application is intentionally not App Sandbox restricted because it launches
external toolchains and a user-selected shell. Review signing and distribution
settings before distributing outside local development.
