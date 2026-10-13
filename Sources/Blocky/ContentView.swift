//
//  ContentView.swift
//  Blocky
//
//  PART 1 — Frontend UI & UX.
//
//  Hyper-minimalist single-column layout on a frosted-glass panel:
//    · tracked monospaced wordmark + secondary caption
//    · profile icon inline with a rounded username field (persisted)
//    · a streamlined version picker (local versions + online catalog)
//    · a reserved status slot — red for exceptions, neutral for progress
//    · a full-width accent action button with hover transitions and a
//      native progress spinner while the launch pipeline is running.
//

import SwiftUI
import AppKit
import BlockyKit

struct ContentView: View {
    /// Persisted with UserDefaults — survives relaunches.
    @AppStorage("blocky.username") private var username: String = ""

    @StateObject private var engine = LauncherEngine()
    @FocusState private var usernameFieldFocused: Bool

    private let cornerRadius: CGFloat = 13

    var body: some View {
        ZStack {
            // Fully translucent frosted-glass panel, edge to edge.
            Color.clear
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 34)
                header
                Spacer(minLength: 26)
                VStack(spacing: 12) {
                    usernameRow
                    versionRow
                }
                statusSlot
                    .padding(.top, 14)
                launchButton
                    .padding(.top, 10)
                footer
                    .padding(.top, 16)
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 26)
        }
        .frame(width: 340, height: 452)
        .background(WindowConfigurator())
        .onAppear(perform: engine.bootstrap)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("BLOCKY")
                .font(.system(size: 27, weight: .heavy, design: .monospaced))
                .kerning(5.5)
                .foregroundStyle(.primary)
            Text("OFFLINE LAUNCHER")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .kerning(2.4)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Username

    private var usernameRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(
                    usernameFieldFocused ? Color.accentColor : Color.secondary.opacity(0.75)
                )

            TextField("Username", text: $username)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .focused($usernameFieldFocused)
                .onSubmit { engine.requestLaunch(username: username) }
                .padding(.vertical, 2)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(fieldBackground(highlighted: usernameFieldFocused))
    }

    // MARK: Version picker

    private var versionRow: some View {
        Menu {
            Picker("Version", selection: $engine.selectedVersionID) {
                Section("Installed") {
                    if engine.installedVersions.isEmpty {
                        Text("No local versions")
                    } else {
                        ForEach(engine.installedVersions, id: \.self) { versionID in
                            Text(versionID).tag(versionID)
                        }
                    }
                }
                Section("Available online") {
                    if engine.fetchableVersions.isEmpty {
                        Text("Catalog loading…")
                    } else {
                        ForEach(engine.fetchableVersions) { remote in
                            Label {
                                Text(remote.id + (remote.isRelease ? "" : "  ·  snapshot"))
                            } icon: {
                                Image(systemName: remote.isRelease ? "icloud" : "bolt.fill")
                            }
                            .tag(remote.id)
                        }
                    }
                }
            }

            Divider()

            Button {
                engine.bootstrap()
            } label: {
                Label("Refresh versions", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.secondary.opacity(0.75))

                Text(versionTitle)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(fieldBackground(highlighted: false))
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .disabled(engine.isWorking)
    }

    private var versionTitle: String {
        let selection = engine.selectedVersionID
        if selection.isEmpty {
            return "Select a version…"
        }
        if engine.installedVersions.contains(selection) {
            return selection
        }
        return selection + "  ·  fetch online"
    }

    // MARK: Status / error slot

    /// A permanently reserved slot so failures never shift the layout.
    private var statusSlot: some View {
        VStack(spacing: 6) {
            if let error = engine.errorMessage {
                statusLabel(error, color: .red)
            } else if let status = engine.statusMessage {
                statusLabel(status, color: .secondary)
                if engine.isWorking {
                    Button("Cancel") {
                        engine.cancelWork()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .padding(0)
                }
            } else if showUsernameHint {
                statusLabel("Username — 1–16 letters, numbers, or underscores", color: .red)
            } else if engine.gameRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                    Text("MINECRAFT RUNNING")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .kerning(1.6)
                        .foregroundStyle(.secondary)
                }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(minHeight: 46, alignment: .top)
        .padding(.horizontal, 2)
    }

    private var showUsernameHint: Bool {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !LauncherEngine.isValidMinecraftUsername(trimmed)
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
            .animation(.easeInOut(duration: 0.2), value: text)
    }

    // MARK: Launch button

    private var launchButton: some View {
        Button {
            usernameFieldFocused = false
            engine.requestLaunch(username: username)
        } label: {
            HStack(spacing: 10) {
                if engine.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(engine.isWorking ? "LAUNCHING" : "LAUNCH GAME")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .kerning(2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(canLaunch ? Color.accentColor : Color.accentColor.opacity(0.35))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(LaunchButtonStyle(enabled: canLaunch))
        .disabled(!canLaunch)
    }

    private var canLaunch: Bool {
        !engine.isWorking && !engine.selectedVersionID.isEmpty
    }

    // MARK: Footer

    private var footer: some View {
        Text("LOCAL · OFFLINE · NO ACCOUNTS")
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .kerning(1.8)
            .foregroundStyle(.quaternary)
    }

    // MARK: Shared shape

    private func fieldBackground(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        highlighted ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - Button style

/// Hover: smooth scale-up + opacity dip with native easing.
/// Pressed: quick 0.97 squeeze. Disabled: inert and dimmed.
private struct LaunchButtonStyle: ButtonStyle {
    let enabled: Bool

    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(scale(for: configuration))
            .opacity(opacity(for: configuration))
            .animation(.easeInOut(duration: 0.18), value: hovered)
            .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
            .onHover { hovering in
                hovered = hovering
                guard enabled else { return }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private func scale(for configuration: Configuration) -> CGFloat {
        if configuration.isPressed { return 0.97 }
        return (hovered && enabled) ? 1.02 : 1.0
    }

    private func opacity(for configuration: Configuration) -> Double {
        if configuration.isPressed { return 0.85 }
        return (hovered && enabled) ? 0.88 : 1.0
    }
}

// MARK: - Window configuration

/// Final NSWindow polish that SwiftUI does not expose declaratively:
/// a fully transparent, non-opaque surface so the ultra-thin material reads
/// as a single frosted pane, plus drag-anywhere behavior for the
/// title-bar-less layout.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.collectionBehavior = [.fullScreenAuxiliary]
    }
}
