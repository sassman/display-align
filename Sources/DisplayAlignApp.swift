import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct DisplayAlignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = DisplayManager()

    var body: some Scene {
        MenuBarExtra {
            if let name = manager.externalName {
                Text(name).font(.headline)
                Text(manager.statusMessage)
            } else {
                Text("No external display")
            }

            Divider()

            Button("Align Now") { manager.align() }
                .disabled(manager.externalName == nil || !manager.isAligned && manager.statusMessage == "Ignored")
                .keyboardShortcut("a")

            Toggle("Auto-align on connect", isOn: $manager.autoAlign)

            Divider()

            if manager.arrangementNames.count > 1 {
                Menu("Active Arrangement: \(manager.activeArrangement)") {
                    ForEach(manager.arrangementNames, id: \.self) { name in
                        Button {
                            manager.switchArrangement(name)
                        } label: {
                            if name == manager.activeArrangement {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                }
            } else {
                Text("Active Arrangement: \(manager.activeArrangement)")
            }

            Divider()

            Button("Open Config...") {
                NSWorkspace.shared.selectFile(
                    Config.configFile.path,
                    inFileViewerRootedAtPath: Config.configDir.path
                )
            }

            Button("Configure Arrangement…") {
                manager.openArrangementEditor()
            }
            .disabled(manager.externalName == nil)

            Divider()

            Button("About DisplayAlign…") {
                AboutWindow.show()
            }

            Button("Missing a feature?") {
                NSWorkspace.shared.open(URL(
                    string: "https://github.com/sassman/display-align/issues/new?labels=enhancement&title=Feature%20request%3A%20"
                )!)
            }

            Divider()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")

        } label: {
            Image(systemName: manager.isAligned ? "display.2" : "display")
        }
    }
}
