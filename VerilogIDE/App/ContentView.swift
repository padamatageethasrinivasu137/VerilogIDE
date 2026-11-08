import SwiftUI
import Charts
import AppKit
import VerilogIDECore

struct ContentView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        NavigationSplitView(columnVisibility: $app.columnVisibility) {
            SidebarView().navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 420)
        } detail: {
            VSplitView {
                EditorArea().frame(minHeight: 220)
                if app.showBottomPanel { BottomPanel().frame(minHeight: 140, idealHeight: 300) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
        }
        .navigationTitle(app.windowTitle)
        .toolbar { MainToolbar() }
        .sheet(item: $app.sheet) { SheetRouter(sheet: $0) }
        .alert(app.alert?.title ?? "", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }), presenting: app.alert) { a in
            if a.actions.isEmpty { Button("OK") {} }
            ForEach(a.actions) { act in Button(act.title, role: act.role) { act.handler() } }
        } message: { Text($0.message) }
        .overlay(alignment: .top) { if app.showPalette { CommandPalette().padding(.top, 60) } }
    }
}

#Preview("VerilogIDE Main Window") {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 1280, height: 820)
}
