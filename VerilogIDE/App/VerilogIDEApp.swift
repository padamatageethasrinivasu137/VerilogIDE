import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct VerilogIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(app).frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Verilog File…") { app.promptNewFile(.verilog) }.keyboardShortcut("n")
                Button("New SystemVerilog File…") { app.promptNewFile(.systemVerilog) }
                Button("New Testbench…") { app.promptNewFile(.testbench) }
                Button("New Folder…") { app.promptNewFolder() }
                Divider()
                Button("New Project…") { app.sheet = .newSimProject }
                Button("New FPGA Project…") { app.sheet = .newFPGAProject }
                Divider()
                Button("Open File…") { app.openFilePanel() }.keyboardShortcut("o")
                Button("Open Folder…") { app.openFolderPanel() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Open Recent") {
                    ForEach(app.recentProjects, id: \.self) { u in Button(u.lastPathComponent) { app.addRoot(u) } }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { app.saveActive() }.keyboardShortcut("s")
                Button("Save All") { app.saveAll() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Close Tab / Terminal Pane") {
                    if app.terminals.hasFocusedSession { app.terminals.closeFocusedSession() }
                    else { app.closeActive() }
                }.keyboardShortcut("w")
                Button("Close Project") { if let r = app.activeProjectRoot { app.closeProject(r) } }
            }
            CommandMenu("Build") {
                Button("Run Simulation") { app.runSimulation() }.keyboardShortcut("r")
                Button("Stop Process") { app.stopProcess() }.keyboardShortcut(".")
                Button("Open Waveform") { app.openWaveform() }.keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Synthesize") { app.runFPGA(.synthesis) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Implement") { app.runFPGA(.implementation) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Generate Bitstream") { app.runFPGA(.bitstream) }.keyboardShortcut("3", modifiers: [.command, .option])
                Button("Program FPGA…") { app.runFPGA(.program) }.keyboardShortcut("4", modifiers: [.command, .option])
                Divider()
                Button("Clean Build") { app.cleanBuild() }
                Button("Rebuild Project") { app.rebuild() }
                Divider()
                Button("Pin Planner…") { app.sheet = .pinPlanner }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("FPGA Project Settings…") { app.sheet = .fpgaSettings }
                Button("Toolchain Manager…") { app.sheet = .toolchain }
            }
            CommandMenu("Terminal") {
                Button("New Terminal") {
                    app.showTerminal(new: true)
                }.keyboardShortcut("t")

                Button("Split Terminal") {
                    app.showTerminal()
                    app.terminals.split(cwd: app.activeProjectRoot ?? URL(fileURLWithPath: NSHomeDirectory()))
                }.keyboardShortcut("d").disabled(!app.terminals.hasFocusedSession)

                Button("Clear Terminal") {
                    if let groupID = app.terminals.focusedGroupID { app.terminals.clear(in: groupID) }
                }.keyboardShortcut("k").disabled(!app.terminals.hasFocusedSession)

                Button("Copy All Terminal Output") {
                    if let groupID = app.terminals.focusedGroupID { app.terminals.copyAll(in: groupID) }
                }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!app.terminals.hasFocusedSession)
            }
            CommandMenu("Go") {
                Button("Command Palette…") { app.showPalette = true }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Find in Files") { app.bottomTab = .search; app.showBottomPanel = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Toggle Bottom Panel") { app.showBottomPanel.toggle() }.keyboardShortcut("j")
                Button("New Terminal") { app.showTerminal(new: true) }.keyboardShortcut("`", modifiers: [.control, .shift])
            }
        }
        Settings { SettingsView().environmentObject(app) }
    }
}
