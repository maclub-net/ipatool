import AppKit
import SwiftUI

extension Color {
    /// App 主题色 #F67F3B
    static let appAccent = Color(red: 0xF6 / 255, green: 0x7F / 255, blue: 0x3B / 255)
}

@main
struct IPAToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .accentColor(.appAccent)
                .task {
                    (NSApp.delegate as? AppDelegate)?.configureAppearance()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func configureAppearance() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.down.app.fill", accessibilityDescription: "IPATool")
            button.image?.size = NSSize(width: 20, height: 20)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "打开 IPATool", action: #selector(showMainWindow), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 IPATool", action: #selector(terminateApp), keyEquivalent: "q")
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.delegate = self
    }

    @objc func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func terminateApp() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}