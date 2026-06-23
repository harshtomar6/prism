import SwiftUI
import AppKit

@main
struct PRismApp: App {
    @StateObject private var store = PRStore()
    @StateObject private var settings = AppSettings()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Menu-bar agent normally (no Dock icon); a regular app in preview mode
        // so the showcase window is visible and capturable.
        NSApplication.shared.setActivationPolicy(AppDelegate.isPreview ? .regular : .accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, settings: settings)
        } label: {
            // Icon + count badge in the menu bar. The label renders at launch,
            // so `.task` here is the single entry point for background polling.
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull")
                if store.totalCount > 0 {
                    Text("\(store.totalCount)")
                }
            }
            .task {
                // Skip live polling in preview mode — the showcase uses seeded data.
                if !AppDelegate.isPreview {
                    store.attach(settings)
                    store.start()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opens a framed showcase window when running in preview/screenshot mode.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PRISM_PREVIEW"] == "1"
            || ProcessInfo.processInfo.environment["PRISM_SHOT"] != nil
        #else
        return false
        #endif
    }

    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Render-to-PNG mode: rasterize the showcase via ImageRenderer (no screen
        // capture, no permissions needed), write the file, then quit.
        if let path = ProcessInfo.processInfo.environment["PRISM_SHOT"] {
            renderShowcase(to: path)
            NSApp.terminate(nil)
            return
        }

        guard Self.isPreview else { return }

        let store = PRStore()
        store.seedPreviewData()

        let host = NSHostingView(rootView: PreviewShowcase(store: store))
        let frame = NSRect(x: 0, y: 0, width: 440, height: 540)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        #endif
    }

    #if DEBUG
    @MainActor
    private func renderShowcase(to path: String) {
        let content: AnyView
        if ProcessInfo.processInfo.environment["PRISM_SHOT_MODE"] == "settings" {
            content = AnyView(SettingsShowcase())
        } else {
            let store = PRStore()
            store.seedPreviewData()
            content = AnyView(PreviewShowcase(store: store))
        }

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard
            let cgImage = renderer.cgImage
        else {
            FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
            return
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write("wrote \(path)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
        }
    }
    #endif
}

#if DEBUG
/// A framed presentation of the dropdown for README screenshots. Renders the
/// real `MenuContent` with seeded sample data on a neutral backdrop.
private struct PreviewShowcase: View {
    @ObservedObject var store: PRStore
    @StateObject private var settings = AppSettings()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.09, green: 0.10, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                // Faux menu bar item, to convey where the app lives.
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.pull")
                    Text("\(store.totalCount)")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                MenuContent(store: store, settings: settings, scrollable: false, clearsUnreadOnAppear: false)
                    .environment(\.colorScheme, .light)
                    .background(Color(red: 0.97, green: 0.97, blue: 0.98))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            }
            .padding(28)
        }
        .frame(width: 440, height: 660)
    }
}

/// Framed presentation of the settings/filters panel for README screenshots.
private struct SettingsShowcase: View {
    @StateObject private var settings = AppSettings.previewSeeded()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.17, blue: 0.22), Color(red: 0.09, green: 0.10, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Filters").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.left").foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                SettingsPanel(settings: settings, scrollable: false, interactive: false)
            }
            .frame(width: 380)
            .environment(\.colorScheme, .light)
            .background(Color(red: 0.97, green: 0.97, blue: 0.98))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            .padding(28)
        }
        .frame(width: 440, height: 540)
    }
}
#endif
