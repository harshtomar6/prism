import SwiftUI
import AppKit

@main
struct PRismApp: App {
    @StateObject private var store = PRStore()

    init() {
        // Run as a menu-bar-only agent: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            // Icon + count badge in the menu bar. The label renders at launch,
            // so `.task` here is the single entry point for background polling.
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull")
                if store.totalCount > 0 {
                    Text("\(store.totalCount)")
                }
            }
            .task { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
