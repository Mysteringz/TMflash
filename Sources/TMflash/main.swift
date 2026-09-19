import AppKit
import SwiftUI
import TMflashCore

struct TMflashApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("TMflash", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 900, height: 800)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// `TMflash --snapshot out.png [--dark] [--scene NAME]` renders one screen
// with sample data (or, for --scene live, real hardware) and exits: how the UI is checked without clicking.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let args = CommandLine.arguments
    let scene = args.firstIndex(of: "--scene").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "single"
    MainActor.assumeIsolated { Snapshot.render(scene: scene, dark: args.contains("--dark"), to: args[i + 1]) }
    exit(0)
}
// `TMflash --icon out.png` renders the app icon (used by scripts/build-app.sh).
if let i = CommandLine.arguments.firstIndex(of: "--icon"), i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: AppMark().frame(width: 824, height: 824).padding(100))
        r.scale = 1
        if let cg = r.cgImage {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }
    exit(0)
}
TMflashApp.main()
