# Migration notes

This is a structural migration from the uploaded Swift Package executable into a
native Xcode application project plus a local `VerilogIDECore` Swift package.

## Preserved
- Existing application source files and core source files were copied without
  functional rewrites.
- Core tests were moved into the local package test target.
- Samples and sample verification script were retained.
- Terminal, simulation, FPGA and process implementations were retained.

## Intentional changes
- `RootView` is now named `ContentView`.
- The application source tree is divided by responsibility.
- The editor host receives an explicit expanding SwiftUI frame.
- Two independent editor Canvas probes were added to isolate AppKit rendering
  from the production `CodeEditor` representable.
- Build script now invokes `xcodebuild` on the native Xcode project.

## Editor diagnosis
The previous screenshots prove that the editor remains blank, but they do not
prove the precise cause. Do not treat the structural migration as a rendering
fix. Use the two previews in `EditorRenderingLab.swift` to isolate the failing
layer before changing the TextKit implementation again.

## First build on macOS
Open `VerilogIDE.xcodeproj`, select the `VerilogIDE` scheme, choose `My Mac`,
then Product > Build. Run the core tests with:

    swift test --package-path Packages/VerilogIDECore

Run sample toolchain verification with:

    Scripts/verify_samples.sh
