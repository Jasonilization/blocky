//
//  BlockyApp.swift
//  Blocky
//
//  Entry configuration: a single, fixed-size, borderless utility window with a
//  forced dark appearance. There is no title bar, no multi-window spawning,
//  and the app terminates when the window is closed.
//

import SwiftUI
import AppKit
import BlockyKit

@main
struct BlockyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Blocky") {
            ContentView()
                // Force the dark system color scheme throughout the app.
                .preferredColorScheme(.dark)
        }
        // Eliminates the default OS title bar while keeping traffic lights.
        .windowStyle(.hiddenTitleBar)
        // The window's size is dictated by its content — a fixed utility panel.
        .windowResizability(.contentSize)
        .commands {
            // Strip the "File > New" item so only one launcher window exists.
            CommandGroup(replacing: CommandGroupPlacement.newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pin every material, control and vibrancy effect to dark variants.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
