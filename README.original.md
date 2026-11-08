# Verilog IDE for macOS

A native SwiftUI/AppKit IDE for Verilog/SystemVerilog: edit → simulate with **Icarus Verilog** → view in **GTKWave**,
plus an AMD/Xilinx FPGA flow (**any part number**, Vivado through a remote Linux/Windows host, optional open-source flow),
a real PTY terminal, a pin planner and hardware programming through openFPGALoader.

## Build and run (macOS 14+, Xcode 15+)

```bash
brew install icarus-verilog            # required for simulation
# GTKWave: install via Homebrew or the official macOS build, then Settings ▸ Tools ▸ Detect Tools
open Package.swift                     # Xcode: choose the "VerilogIDE" scheme ▸ My Mac ▸ Run (⌘R)
# or, without Xcode UI:
Scripts/build_app.sh                   # produces build/Verilog IDE.app
swift test                             # core unit tests
Scripts/verify_samples.sh              # runs the sample projects through real iverilog/vvp
```
The app is not sandboxed (it must launch external tools and a shell). Tool paths are resolved from Homebrew
(`/opt/homebrew`, `/usr/local`), your login-shell PATH and common Vivado install dirs, never from the GUI PATH alone.

## Using it
1. **Open Folder** (⇧⌘O) or **New Project…**. Try `Samples/mux2_demo`.
2. **Run** (⌘R): saves files → finds the testbench (by content, not only name) → compiles only that testbench's
   dependency closure into a fresh `build/sim/<timestamp>/` → runs `vvp -n` in `simulation/` → validates the VCD
   (exists, non-empty, has signals and value changes, newer than the run) → opens GTKWave with a generated `*.ide.gtkw`
   save file listing the selected signals.
3. No testbench → error with a "create template" option. Several → chooser. Missing `$dumpfile/$dumpvars` → choose
   *generate wrapper* (a separate generated module; your testbench is never edited), *run without waveform* or cancel.
4. **FPGA** menu: Synthesize ⌥⌘1 · Implement ⌥⌘2 · Bitstream ⌥⌘3 · Program ⌥⌘4 · Pin Planner ⇧⌘K · Command Palette ⇧⌘P.


## Terminal keyboard shortcuts

The integrated terminal is a PTY-backed shell with a lightweight transcript renderer. When a terminal pane has focus:

| Shortcut | Action |
|---|---|
| `⌘T` | Open a new terminal |
| `⌘D` | Split the current terminal group |
| `⌘W` | Close the focused terminal pane (or the active editor tab when the terminal is not focused) |
| `⌘K` | Clear the focused terminal display and ask the shell to redraw its prompt |
| `⌘⇧C` | Copy all retained output from the terminal group; split panes are labelled separately |
| `⌘C` | Copy selected text; with no selection, send Ctrl-C to the foreground process |
| `⌘V` | Paste clipboard text into the shell |
| `⌘A` | Select all rendered terminal text |
| `⌘F` | Open the native Find bar |
| `⌃A/E/U/K/W/R/C/D/L/Z` | Send the corresponding shell control character (Readline / job-control shortcuts) |
| `⌥← / ⌥→` | Move by word in shells that use Readline-style `Esc-b` / `Esc-f` |
| Arrow keys, Home, End, Delete, Tab, Return, Escape | Forward terminal navigation/control sequences |

The Copy All button in the terminal toolbar copies the complete output currently retained by the terminal screen model. The screen model retains up to 10,000 lines per session.

## FPGA design (device-agnostic Xilinx)
* The part is a free-form string (`xc7a35tcpg236-1`, `xczu7ev-ffvc1156-2-e`, …). Only the family prefix is interpreted
  (for display and to reject ISE-era parts); Vivado is the authority on validity.
* **Backends** (capability registry; features are only offered when the backend supports them):
  `vivado-local` (if Vivado exists on the Mac), `vivado-remote` (SSH + rsync to a Linux/Windows host; **uploads need your
  explicit approval**), `yosys-nextpnr-xilinx` (experimental, 7-series, needs your chipdb and Project X-Ray data).
* Per-device build dirs: `build/<part>/…`, `reports/<part>/…`. A stage runs only if its predecessor's marker is newer
  than all inputs; any failure invalidates that stage and everything downstream (no stale bitstreams).
* Reports parsed: utilization (post-synthesis flagged *estimated*, post-route *final*), timing summary (WNS/TNS/WHS/THS),
  clocks, critical path, DRC. Nothing is displayed unless the tool reported it; Fmax is labelled *derived*.
* **Pin Planner** only accepts pins found in Vivado's package-pin export for the part or in a vendor board XDC you import.
  It exports XDC (`set_property -dict …`, `create_clock …`) and refuses duplicates/unknown pins/unknown ports.
* **Programming** (openFPGALoader or Vivado HW Manager): identifies the device over JTAG first (an `idcode` is required;
  a USB device alone is never treated as detection), compares with the configured part, asks for confirmation, and
  never writes flash unless you tick it and confirm a second time.

## Verification status — read this
| Area | Status |
|---|---|
| `iverilog`/`vvp` command lines, VCD generation, wrapper-based dumping, compile-error formats | **Run for real** (Icarus 12.0, `Scripts/verify_samples.sh`, 5/5 pass) |
| Swift sources (~4.6 k lines) | **Not compiled yet.** Written without a macOS toolchain; expect a few compile errors on first build. Please send me the Xcode error list and I will fix them. |
| Unit tests (`Tests/`) | Written against real tool output formats; not yet executed |
| SwiftUI/AppKit UI, PTY terminal, editor | Unverified until first launch |
| GTKWave `.gtkw` save file / launch | Unverified (format follows GTKWave conventions) |
| Vivado Tcl, remote rsync/ssh flow, report parsers for Vivado | Unverified against a real Vivado run |
| openFPGALoader detection/programming, nextpnr-xilinx flow | Unverified; **no hardware has been programmed** |

## Known limitations (deliberately not faked)
* **No code folding and no minimap.** Reliable folding needs a custom text layout; omitted rather than shipped broken.
* Autocomplete is on demand (Esc / F5): keywords, system tasks, common constructs, words from the file.
* The terminal is a real shell on a PTY with zsh/bash line-editing support, history, copy/paste, find, copy-all, clear,
  tabs and splits. It is **not a full VT emulator**: full-screen programs (vim, top, tmux, htop) and ANSI color rendering
  are not supported. Terminal output is retained in a bounded 10,000-line buffer per session.
* Compile/simulation output goes to the Simulation and Output panels (not echoed into the shell session).
* Undo history is per tab view and resets when you switch tabs.
* No part-catalog browser (`get_parts`) and no critical-path-to-source jumping: Vivado reports cell names, not RTL lines.
* Vivado has no native macOS version; use the remote backend. Efinity/Gowin/Lattice/Intel adapters are out of scope
  (the `FPGABackend` protocol is the extension point).
* Instantiation detection for dependency resolution only knows modules defined inside the project; an unknown module
  is reported by iverilog itself ("Unknown module type").

## Layout
```
Sources/VerilogIDECore   engine (no UI): tools, process runner, diagnostics, parser, testbench detection,
                         simulation, waveform, FPGA backends/reports/constraints/hardware, project templates
Sources/VerilogIDE       SwiftUI app: editor, sidebar, panels, terminal (PTY), sheets, settings, command palette
Tests/                   XCTest for the core        Samples/   five ready-made test projects
Scripts/                 build_app.sh, verify_samples.sh
```
