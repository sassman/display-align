import AppKit
import SwiftUI

struct AboutView: View {
    private let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "DisplayAlign"
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    private let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    private let repoURL = URL(string: "https://github.com/sassman/display-align")!

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 128, height: 128)
            }

            Text(appName)
                .font(.system(size: 28, weight: .semibold))

            Text("Version \(appVersion)")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            Link("github.com/sassman/display-align", destination: repoURL)
                .font(.system(size: 15))

            Text(copyright)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(width: 360, height: 420)
    }
}

@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = ""
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
