//
//  ContentView.swift
//  Blocky
//
//  PART 1 — Frontend UI & UX, the voxel fold, and the utility panel.
//
//  Compact state: a 340 pt portrait column — wordmark, username, version
//  picker, status slot, LAUNCH GAME. The top-right chevron folds the window
//  open to the right (712 pt): settings, a live log terminal, author credit.
//
//  The fold itself is voxel-flavored: the window edge sweeps at display rate
//  while a deterministic storm of small isometric cubes rides it — cubes
//  tumble in ahead of the edge and dissolve behind it, left-to-right on
//  open, disintegrating leftward on collapse. Zero particle state, zero
//  idle cost: the Canvas only redraws while a fold is in flight.
//
//  Mechanics: SwiftUI content is ALWAYS laid out at the full landscape size;
//  only the NSWindow's width changes (340 ↔ 712), anchored at its left edge.
//

import SwiftUI
import AppKit
import BlockyKit

struct ContentView: View {
    /// Persisted with UserDefaults — survives relaunches.
    @AppStorage("blocky.username") private var username: String = ""
    @AppStorage("blocky.expanded") private var expanded: Bool = false

    // Settings surface (engine reads the same keys at launch time).
    @AppStorage("blocky.ramOverrideGB") private var ramOverrideGB: Int = 0
    @AppStorage("blocky.javaOverridePath") private var javaOverridePath: String = ""
    @AppStorage("blocky.showSnapshots") private var showSnapshots: Bool = true
    @AppStorage("blocky.customGameDir") private var customGameDir: String = ""
    @AppStorage("blocky.background") private var backgroundRaw: String = "frosted"
    /// Terminal-focus mode: hide settings/versions, terminal takes the panel.
    @AppStorage("blocky.terminalFocus") private var terminalFocus: Bool = false

    /// Transient fold-animation state — shared with the window driver.
    @StateObject private var fold = FoldState()

    @StateObject private var engine = LauncherEngine()
    @FocusState private var usernameFieldFocused: Bool

    static let collapsedWidth: CGFloat = 340
    static let panelWidth: CGFloat = 372
    static let expandedWidth: CGFloat = collapsedWidth + panelWidth
    static let windowHeight: CGFloat = 452
    static let foldDuration: Double = 1.0

    /// Two-tap delete confirmation state for the versions list.
    @State private var pendingDeleteVersion: String?

    private let cornerRadius: CGFloat = 13

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundLayer
                .ignoresSafeArea()

            mainColumn
                .frame(width: Self.collapsedWidth)
                // The panel rides an OVERLAY — overlays never contribute to
                // layout sizing, so the window's true minimum is the main
                // column. The window itself clips and reveals the panel as
                // the fold sweeps its width, and the panel fades with the
                // fold so the whole thing dissolves as one window.
                .overlay(alignment: .topLeading) {
                    PanelFade(fold: fold) {
                        rightPanel
                            .frame(width: Self.panelWidth)
                    }
                    .frame(width: Self.panelWidth, height: Self.windowHeight, alignment: .leading)
                    .offset(x: Self.collapsedWidth)
                }
        }
        // Locked height, flexible width, hard left anchor.
        .frame(height: Self.windowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The controls ride the window's top-right corner — the very edge
        // the dissolve travels along — so they always sit on the live edge.
        .overlay(alignment: .topTrailing) {
            windowControls
                .padding(.trailing, 12)
                .padding(.top, 10)
        }
        .background(WindowConfigurator(expanded: $expanded, foldState: fold))
        .onAppear(perform: engine.bootstrap)
    }

    // MARK: Background

    private var backgroundLayer: some View {
        if let style = PixelBackgroundStyle(rawValue: backgroundRaw), style != .frosted {
            return AnyView(
                PixelBackgroundView(style: style, fold: fold, assetsDirectory: engine.assetsDirectory)
                    .overlay(Color.black.opacity(style.scrim))
            )
        }
        // Default: fully translucent frosted glass.
        return AnyView(Color.clear.background(.ultraThinMaterial))
    }

    // MARK: Window controls (fold toggle + terminal quick-open)

    private var windowControls: some View {
        foldToggle
    }

    private var foldToggle: some View {
        Button {
            // WindowConfigurator picks this up and drives the dissolve.
            expanded.toggle()
        } label: {
            Image(systemName: expanded ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(expanded ? Color.secondary : Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(expanded ? 0.06 : 0.10)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(expanded ? "Dissolve the panel closed" : "Open settings & terminal")
    }

    // MARK: Main column

    private var mainColumn: some View {
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
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 26)
        .frame(maxHeight: .infinity, alignment: .top)
    }

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
        // Dual-launch protection: while a game process is alive the button
        // stays inert (the engine guard also blocks programmatic calls).
        !engine.isWorking && !engine.selectedVersionID.isEmpty && !engine.gameRunning
    }

    // MARK: Right panel (settings + terminal)

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Terminal-focus mode folds settings + versions away so the
            // terminal owns the whole panel.
            if !terminalFocus {
                panelHeader("SETTINGS")

                VStack(spacing: 6) {
                    settingsRow(label: "HEAP") { heapSlider }
                    settingsRow(label: "JAVA") { javaMenu }
                    settingsRow(label: "BACKDROP") { backgroundMenu }
                    settingsRow(label: "SNAPSHOTS") { snapshotsToggle }
                    settingsRow(label: "GAME DIR") { gameDirField }
                    settingsRow(label: "FOLDERS") { folderButtons }
                }

                Divider().opacity(0.6)

                HStack(spacing: 8) {
                    panelHeader("VERSIONS")
                    Spacer()
                    Text("own files · shared libraries not included")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
                versionsList
                    .task(id: pendingDeleteVersion) {
                        // Two-tap confirm: the first tap arms the trash, the
                        // second deletes. Arming expires after 2.5 s.
                        guard pendingDeleteVersion != nil else { return }
                        try? await Task.sleep(for: .seconds(2.5))
                        pendingDeleteVersion = nil
                    }

                Divider().opacity(0.6)
            }

            HStack(spacing: 8) {
                panelHeader("TERMINAL")
                Spacer()
                Button("Clear") {
                    engine.clearLog()
                }
                .buttonStyle(.link)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))

                // Expand-terminal toggle — only exists while the panel is open.
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        terminalFocus.toggle()
                    }
                } label: {
                    Image(systemName: terminalFocus
                          ? "rectangle.collapse.vertical"
                          : "rectangle.expand.vertical")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(terminalFocus
                                         ? Color.accentColor
                                         : Color.primary.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help(terminalFocus ? "Bring settings back" : "Expand the terminal")
            }

            terminalView

            Divider().opacity(0.6)

            creditsRow
        }
        .padding(.top, 28)
        .padding(.bottom, 16)
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func panelHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .kerning(2)
            .foregroundStyle(.tertiary)
    }

    private func settingsRow<Control: View>(label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .kerning(1)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            control()
        }
        .frame(height: 28)
    }

    /// Heap slider: 2–16 GB, one smooth drag. "Auto" (¼ RAM, capped)
    /// stays one tap away; dragging the slider switches to manual.
    private var heapSlider: some View {
        let autoGB = LauncherEngine.recommendedHeapMegabytes(for: ProcessInfo.processInfo.physicalMemory) / 1024
        let currentGB = ramOverrideGB == 0 ? autoGB : ramOverrideGB
        return HStack(spacing: 10) {
            Button("Auto") {
                ramOverrideGB = 0
            }
            .font(.system(size: 9, weight: ramOverrideGB == 0 ? .bold : .regular, design: .monospaced))
            .foregroundStyle(ramOverrideGB == 0 ? Color.accentColor : Color.primary.opacity(0.55))
            .buttonStyle(.link)

            Slider(
                value: Binding(
                    get: { Double(currentGB) },
                    set: { ramOverrideGB = Int($0.rounded()) }
                ),
                in: 2...16,
                step: 1
            )
            .controlSize(.small)
            .tint(Color.accentColor)

            Text("\(currentGB) GB")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var javaMenu: some View {
        Menu {
            Picker("Java", selection: $javaOverridePath) {
                Text("Auto").tag("")
                ForEach(engine.javaCandidates, id: \.binary) { candidate in
                    Text(candidate.displayName).tag(candidate.binary.path)
                }
            }
        } label: {
            settingsMenuLabel(javaMenuLabel)
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var javaMenuLabel: String {
        guard !javaOverridePath.isEmpty else { return "Auto" }
        if let match = engine.javaCandidates.first(where: { $0.binary.path == javaOverridePath }) {
            return match.displayName
        }
        return URL(fileURLWithPath: javaOverridePath).lastPathComponent
    }

    private var backgroundMenu: some View {
        Menu {
            Picker("Backdrop", selection: $backgroundRaw) {
                ForEach(PixelBackgroundStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
        } label: {
            settingsMenuLabel(
                PixelBackgroundStyle(rawValue: backgroundRaw)?.displayName ?? "Frosted"
            )
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var versionsList: some View {
        Group {
            if engine.installedVersions.isEmpty {
                Text("nothing installed yet")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(engine.installedVersions, id: \.self) { versionID in
                            versionRow(versionID)
                        }
                    }
                }
                .frame(maxHeight: 88)
            }
        }
    }

    private func versionRow(_ versionID: String) -> some View {
        let armed = pendingDeleteVersion == versionID
        return HStack(spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 9))
                .foregroundStyle(armed ? Color.red : Color.secondary.opacity(0.6))
            Text(versionID)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(ByteCountFormatter.string(
                fromByteCount: engine.versionFootprints[versionID] ?? 0,
                countStyle: .file
            ))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.45))
            Button {
                if armed {
                    engine.deleteVersion(versionID)
                    pendingDeleteVersion = nil
                } else {
                    pendingDeleteVersion = versionID
                }
            } label: {
                Image(systemName: armed ? "trash.fill" : "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(armed ? Color.red : Color.primary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help(armed ? "Tap again to delete \(versionID)" : "Delete \(versionID)")
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.red.opacity(armed ? 0.10 : 0))
        )
    }

    private var snapshotsToggle: some View {
        Toggle("", isOn: $showSnapshots)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gameDirField: some View {
        HStack(spacing: 6) {
            TextField("default", text: $customGameDir)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .truncationMode(.middle)

            if !customGameDir.isEmpty {
                Button {
                    customGameDir = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    /// One-tap access to the folders mods and shader packs live in.
    private var folderButtons: some View {
        HStack(spacing: 14) {
            folderButton("mods", icon: "shippingbox")
            folderButton("shaderpacks", icon: "sparkles")
            Spacer(minLength: 0)
        }
    }

    private func folderButton(_ name: String, icon: String) -> some View {
        Button {
            let url = engine.minecraftRoot.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } label: {
            Label(name, systemImage: icon)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.link)
        .help("Open the \(name) folder — drop .jar mods / shader packs here")
    }

    private func settingsMenuLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
    }

    // MARK: Terminal

    private var terminalView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.logLines) { line in
                        Text(line.text)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(terminalColor(for: line.kind))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .overlay {
                if engine.logLines.isEmpty {
                    Text("— waiting for launch —")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
            }
            .onChange(of: engine.logLines.count) { _ in
                if let last = engine.logLines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func terminalColor(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .out:    return Color.primary.opacity(0.85)
        case .err:    return Color.red.opacity(0.9)
        case .info:   return Color.secondary
        case .system: return Color.accentColor
        }
    }

    // MARK: Credits

    private var creditsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.right.square.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Link("Jasonilization/blocky",
                 destination: URL(string: "https://github.com/Jasonilization/blocky")!)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            Spacer()
            Text("MIT · made by Jason")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
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

// MARK: - Fold state

/// Drives both the NSWindow sweep and the dissolve. Progress is
/// published at display rate — but ONLY while a fold is in flight, so idle
/// cost stays exactly zero.
final class FoldState: ObservableObject {
    /// 0 = collapsed, 1 = expanded.
    @Published var progress: CGFloat
    @Published var isAnimating = false
    /// -1 … 1: signed direction of the in-flight fold (0 = settled).
    @Published var direction: CGFloat = 0

    init(expanded: Bool = false) {
        progress = expanded ? 1 : 0
    }
}

/// Fades the panel's UI in step with the fold so the minimize feels complete:
/// the panel's own widgets dissolve out with its backdrop blocks, instead of
/// vanishing abruptly when the window edge passes them.
private struct PanelFade<Content: View>: View {
    @ObservedObject var fold: FoldState
    @ViewBuilder var content: Content

    var body: some View {
        content.opacity(panelContentOpacity)
    }

    private var panelContentOpacity: Double {
        if !fold.isAnimating {
            return fold.progress > 0.5 ? 1 : 0
        }
        // The panel's UI dies EARLY — before its backdrop blocks go — so the
        // dissolve reads as pure pixel disappearance, never sliding widgets.
        return max(0, min(1, (fold.progress - 0.12) * 3.2))
    }
}

// MARK: - Pixel backdrop

/// Loads authentic block textures straight out of the user's own installed
/// game files (`assets/objects`, resolved through the asset indexes Blocky
/// already maintains). No textures ship with Blocky — this reads, never
/// redistributes. When the files aren't there (vanilla not yet downloaded),
/// each style falls back to its procedural rendition.
enum OfficialTextures {
    private static let cache = NSCache<NSString, CGImage>()

    static func textureKey(for style: PixelBackgroundStyle) -> String? {
        switch style {
        case .frosted:    return nil
        case .grass:      return "minecraft:block/grass_block_side.png"
        case .dirt:       return "minecraft:block/dirt.png"
        case .stone:      return "minecraft:block/stone.png"
        case .cobblestone: return "minecraft:block/cobblestone.png"
        case .planks:     return "minecraft:block/oak_planks.png"
        case .sandstone:  return "minecraft:block/sandstone.png"
        case .netherrack: return "minecraft:block/netherrack.png"
        case .endstone:   return "minecraft:block/end_stone.png"
        case .deepslate:  return "minecraft:block/deepslate.png"
        case .obsidian:   return "minecraft:block/obsidian.png"
        }
    }

    /// Scans every asset index on disk for the requested texture.
    static func texture(for style: PixelBackgroundStyle, assetsDirectory: URL) -> CGImage? {
        guard let key = textureKey(for: style) else { return nil }
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let fileManager = FileManager.default
        let indexesDirectory = assetsDirectory.appendingPathComponent("indexes", isDirectory: true)
        guard let indexes = try? fileManager.contentsOfDirectory(atPath: indexesDirectory.path) else {
            return nil
        }

        for index in indexes.sorted().reversed() where index.hasSuffix(".json") {
            let indexURL = indexesDirectory.appendingPathComponent(index)
            guard let data = try? Data(contentsOf: indexURL),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let objects = json["objects"] as? [String: [String: Any]],
                  let entry = objects[key],
                  let hash = entry["hash"] as? String,
                  hash.count >= 2 else { continue }

            let objectURL = assetsDirectory
                .appendingPathComponent("objects", isDirectory: true)
                .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
                .appendingPathComponent(hash)

            if let image = loadPNG(at: objectURL) {
                cache.setObject(image, forKey: cacheKey)
                return image
            }
        }
        return nil
    }

    private static func loadPNG(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Procedural Minecraft-style material backdrops — original art generated on
/// the fly (no game assets). Every block is an 8×8 texel cell drawn with
/// per-material patterns (grass sides, cobble grout, plank grain, nether
/// veins…), and the whole thing is fold-aware: on minimize, the panel's own
/// boxes dissolve one by one, left to right with scatter, each crumbling to
/// a fading mini-cube; on expand they materialize the same way. Idle cost
/// stays zero — the canvas only re-evaluates while a fold is in flight.
enum PixelBackgroundStyle: String, CaseIterable, Identifiable {
    case frosted
    case grass
    case dirt
    case stone
    case cobblestone
    case planks
    case sandstone
    case netherrack
    case endstone
    case deepslate
    case obsidian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frosted:   return "Frosted"
        case .grass:     return "Grass"
        case .dirt:      return "Dirt"
        case .stone:     return "Stone"
        case .cobblestone: return "Cobblestone"
        case .planks:    return "Planks"
        case .sandstone: return "Sandstone"
        case .netherrack: return "Netherrack"
        case .endstone:  return "End Stone"
        case .deepslate: return "Deepslate"
        case .obsidian:  return "Obsidian"
        }
    }

    /// How much dark scrim keeps UI text readable over the texture.
    var scrim: Double {
        switch self {
        case .frosted:    return 0.0
        case .grass:      return 0.58
        case .dirt:       return 0.52
        case .stone:      return 0.52
        case .cobblestone: return 0.52
        case .planks:     return 0.52
        case .sandstone:  return 0.58
        case .netherrack: return 0.52
        case .endstone:   return 0.58
        case .deepslate:  return 0.38
        case .obsidian:   return 0.34
        }
    }
}

private struct PixelBackgroundView: View {
    let style: PixelBackgroundStyle
    @ObservedObject var fold: FoldState
    let assetsDirectory: URL

    private static let block: CGFloat = 44
    private static let texels = 8

    var body: some View {
        Canvas { context, size in
            guard style != .frosted else { return }
            let block = Self.block
            let columns = Int(size.width / block) + 1
            let rows = Int(size.height / block) + 1
            let dissolving = fold.isAnimating
            let official = OfficialTextures.texture(for: style, assetsDirectory: assetsDirectory)

            context.withCGContext { ctx in
                // Opaque base: dissolving blocks fade toward solid dark, never
                // toward see-through — no transparency flash during the fold.
                ctx.setFillColor(red: 0.055, green: 0.063, blue: 0.086, alpha: 1)
                ctx.fill(CGRect(origin: .zero, size: size))

                for row in 0..<rows {
                    for column in 0..<columns {
                        let blockSeed = column &* 73856093 &+ row &* 19349663
                        let blockX = CGFloat(column) * block
                        let blockY = CGFloat(row) * block

                        // ── Per-PIXEL dissolve: every texel of the backdrop
                        // carries its own threshold. Its block's position sets
                        // the coarse gate; the 64 pixels inside then scatter
                        // across a short window — so during a fold they wink
                        // out one by one, sweeping across the panel.
                        let inPanelRegion = blockX >= ContentView.collapsedWidth - block
                        let xNorm = max(0, min(1,
                            (blockX - ContentView.collapsedWidth) / ContentView.panelWidth))
                        let blockGate = 0.02 + xNorm * 0.77
                            + seeded(blockSeed &+ 101) * 0.08

                        // Authentic texture path: one crisp draw per block,
                        // fading as a chunk (per-pixel scatter is a
                        // procedural-path luxury).
                        if let official {
                            let alpha: Double
                            if dissolving, inPanelRegion {
                                alpha = max(0, min(1, (fold.progress - blockGate) / 0.06))
                            } else {
                                alpha = 1
                            }
                            guard alpha > 0 else { continue }

                            ctx.saveGState()
                            ctx.setAlpha(alpha)
                            let rotation = Double((blockSeed &+ 5) % 4) * .pi / 2
                            if rotation != 0 {
                                ctx.translateBy(x: blockX + block / 2, y: blockY + block / 2)
                                ctx.rotate(by: CGFloat(rotation))
                                ctx.translateBy(x: -block / 2, y: -block / 2)
                            } else {
                                ctx.translateBy(x: blockX, y: blockY)
                            }
                            ctx.interpolationQuality = .none
                            ctx.draw(official, in: CGRect(x: 0, y: 0, width: block, height: block))
                            ctx.restoreGState()
                            continue
                        }

                        // Procedural path: true per-pixel death.
                        let texel = block / CGFloat(Self.texels)
                        let blockShade = CGFloat(0.86 + seeded(blockSeed &+ 3) * 0.28)
                        for ty in 0..<Self.texels {
                            for tx in 0..<Self.texels {
                                let texelSeed = blockSeed &+ tx &* 83492791 &+ ty &* 2971215073
                                let noise = seeded(texelSeed)

                                var alpha: Double = 1
                                if dissolving, inPanelRegion {
                                    let withinBlock = Double(tx + ty * Self.texels)
                                        / Double(Self.texels * Self.texels)
                                    let threshold = blockGate
                                        + withinBlock * 0.09
                                        + noise * 0.03
                                    alpha = max(0, min(1, (fold.progress - threshold) / 0.025))
                                }
                                if alpha <= 0 { continue }

                                let shade = texelShade(tx: tx, ty: ty, noise: noise, blockSeed: blockSeed)
                                let rgb = paletteColor(shade)

                                ctx.setFillColor(red: rgb.0 * blockShade, green: rgb.1 * blockShade,
                                                  blue: rgb.2 * blockShade, alpha: alpha)
                                ctx.fill(CGRect(
                                    x: blockX + CGFloat(tx) * texel,
                                    y: blockY + CGFloat(ty) * texel,
                                    width: texel + 0.5,
                                    height: texel + 0.5
                                ))
                            }
                        }
                    }
                }
            }
        }
        // Vignette — pools light in the center so the launcher reads first.
        .overlay(
            RadialGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.34)],
                center: .center,
                startRadius: 80,
                endRadius: 560
            )
            .allowsHitTesting(false)
        )
    }

    private func seeded(_ i: Int) -> Double {
        var value = abs(Double(i % 100003) + 0.5)
        value = sin(value * 12.9898) * 43758.5453
        return value - value.rounded(.towardZero)   // fract()
    }

    /// Cluster noise — 2×2 texel groups share one value for stony blobs.
    private func clustered(tx: Int, ty: Int, blockSeed: Int) -> Double {
        seeded(blockSeed &+ (tx / 2) &* 2971 &+ (ty / 2) &* 7331)
    }

    /// Style-specific shading: returns a 0…1 palette index.
    private func texelShade(tx: Int, ty: Int, noise: Double, blockSeed: Int) -> Double {
        switch style {
        case .frosted:
            return 0.5
        case .grass:
            // The iconic grass-block side: a ragged green crown over dirt.
            if ty <= 1 { return noise < 0.18 ? 0.5 : 0.85 }           // crown
            if ty == 2 { return seeded(blockSeed &+ tx &* 733) > 0.45 ? 0.7 : 0.55 }  // ragged edge
            if ty == 3 && noise < 0.3 { return 0.6 }                  // hanging blades
            if noise < 0.22 { return 0.22 }                          // dark clods
            if noise > 0.9 { return 0.75 }                           // pale grit
            return 0.45 + clustered(tx: tx, ty: ty, blockSeed: blockSeed) * 0.15
        case .dirt:
            if noise < 0.22 { return 0.22 }
            if noise > 0.9 { return 0.75 }
            return 0.5
        case .stone:
            let c = clustered(tx: tx, ty: ty, blockSeed: blockSeed)
            if c < 0.3 { return 0.3 }
            if c > 0.78 { return 0.68 }
            return 0.5
        case .cobblestone:
            let border = tx == 0 || ty == 0 || tx == Self.texels - 1 || ty == Self.texels - 1
            if border { return 0.22 }                                 // grout
            let c = clustered(tx: tx, ty: ty, blockSeed: blockSeed)
            return c < 0.35 ? 0.38 : 0.62
        case .planks:
            if ty == 0 { return 0.2 }                                 // seam
            if ty == Self.texels - 1 && seeded(blockSeed &+ 505) > 0.7 { return 0.42 }  // bevel
            let grain = seeded(blockSeed &+ tx &* 971) < 0.3
            if grain { return 0.36 }
            if seeded(blockSeed) > 0.93 && (tx == 3 || tx == 4) && (ty == 3 || ty == 4) { return 0.3 }  // knot
            return 0.55
        case .sandstone:
            if ty == 0 && rowOf(blockSeed) % 3 == 0 { return 0.4 }    // strata
            if noise < 0.12 { return 0.42 }
            return 0.62
        case .netherrack:
            let c = clustered(tx: tx, ty: ty, blockSeed: blockSeed)
            if c < 0.28 { return 0.25 }                               // maroon veins
            if noise > 0.955 { return 0.8 }                           // ember glints
            return 0.5
        case .endstone:
            let c = clustered(tx: tx, ty: ty, blockSeed: blockSeed)
            if c < 0.34 { return 0.42 }                               // dimples
            if c > 0.82 { return 0.72 }
            return 0.58
        case .deepslate:
            if noise < 0.1 { return 0.2 }
            if noise > 0.96 { return 0.55 }                           // mica sparkle
            return 0.36
        case .obsidian:
            let streak = seeded(blockSeed &+ ty &* 6151) > 0.86
            if streak && tx % 2 == 0 { return 0.5 }                   // lavender sheen
            if noise < 0.1 { return 0.1 }
            return 0.28
        }
    }

    private func rowOf(_ blockSeed: Int) -> Int {
        (blockSeed / 19349663) % 97
    }

    /// Palette ramp: 0 = darkest shade of the style, 1 = brightest.
    private func paletteColor(_ shade: Double) -> (Double, Double, Double) {
        let ramps: [[Double]] = [
            // (dark … light) per style, RGB 0…1
            [0.16, 0.34, 0.12,   0.42, 0.66, 0.30,   0.55, 0.82, 0.42],   // grass greens
            [0.22, 0.15, 0.10,   0.42, 0.29, 0.19,   0.58, 0.43, 0.30],   // dirt browns
            [0.28, 0.28, 0.30,   0.46, 0.46, 0.48,   0.62, 0.62, 0.64],   // stone grays
            [0.26, 0.26, 0.28,   0.44, 0.44, 0.46,   0.60, 0.60, 0.62],   // cobble grays
            [0.30, 0.22, 0.12,   0.52, 0.40, 0.24,   0.68, 0.55, 0.35],   // plank oaks
            [0.52, 0.45, 0.30,   0.72, 0.64, 0.44,   0.86, 0.79, 0.60],   // sandstone
            [0.20, 0.06, 0.05,   0.42, 0.13, 0.10,   0.58, 0.22, 0.16],   // netherrack reds
            [0.48, 0.46, 0.30,   0.66, 0.63, 0.44,   0.82, 0.79, 0.60],   // end stone
            [0.07, 0.07, 0.09,   0.15, 0.15, 0.18,   0.22, 0.22, 0.26],   // deepslate
            [0.04, 0.02, 0.09,   0.10, 0.05, 0.18,   0.20, 0.12, 0.34],   // obsidian purples
        ]
        let rampIndex: Int
        switch style {
        case .frosted: rampIndex = 0
        case .grass: rampIndex = 0
        case .dirt: rampIndex = 1
        case .stone: rampIndex = 2
        case .cobblestone: rampIndex = 3
        case .planks: rampIndex = 4
        case .sandstone: rampIndex = 5
        case .netherrack: rampIndex = 6
        case .endstone: rampIndex = 7
        case .deepslate: rampIndex = 8
        case .obsidian: rampIndex = 9
        }
        let ramp = ramps[rampIndex]
        let t = max(0.0, min(1.0, shade))
        let segment = t < 0.5 ? 0 : 1
        let local = t < 0.5 ? t * 2 : (t - 0.5) * 2
        let low = (ramp[segment * 3], ramp[segment * 3 + 1], ramp[segment * 3 + 2])
        let high = (ramp[segment * 3 + 3], ramp[segment * 3 + 4], ramp[segment * 3 + 5])
        return (
            low.0 + (high.0 - low.0) * local,
            low.1 + (high.1 - low.1) * local,
            low.2 + (high.2 - low.2) * local
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

/// Final NSWindow polish SwiftUI does not expose declaratively:
/// a fully transparent, non-opaque surface for the frosted pane,
/// drag-anywhere behavior — and the fold itself: a display-rate width
/// sweep (so the voxel storm stays glued to the window edge), driven
/// from the persisted `expanded` state.
private struct WindowConfigurator: NSViewRepresentable {
    @Binding var expanded: Bool
    let foldState: FoldState

    final class Coordinator {
        var lastTarget: Bool?
        fileprivate var displayLink: CVDisplayLink?
        fileprivate var foldContext: UnsafeMutableRawPointer?
        fileprivate var foldFrom: CGFloat = 0
        fileprivate var foldTarget: CGFloat = 0
        fileprivate var foldStart: CFTimeInterval = 0

        deinit {
            stopFold()
        }

        fileprivate func stopFold() {
            if let link = displayLink {
                CVDisplayLinkStop(link)
                displayLink = nil
            }
            if let context = foldContext {
                Unmanaged<FoldBox>.fromOpaque(context).release()
                foldContext = nil
            }
        }
    }

    /// One vsync-aligned fold step, dispatched to main. The display link
    /// ticks exactly once per refresh — no timer jitter, no main-queue
    /// scheduling lag — which is what keeps the dissolve butter-smooth.
    fileprivate final class FoldBox {
        weak var window: NSWindow?
        weak var coordinator: Coordinator?
        weak var foldState: FoldState?

        fileprivate func tick() {
            guard let window, let coordinator, let foldState else {
                coordinator?.stopFold()
                return
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - coordinator.foldStart
            let linear = min(1, elapsed / ContentView.foldDuration)
            let eased = WindowConfigurator.easeInOut(CGFloat(linear))
            foldState.progress = coordinator.foldFrom
                + (coordinator.foldTarget - coordinator.foldFrom) * eased

            // NOTE: no per-tick window resize — the dissolve is pure canvas
            // work, which is what keeps it smooth. The window only moves at
            // the fold's boundary (startFold / below).
            if linear >= 1 {
                coordinator.stopFold()
                foldState.progress = coordinator.foldTarget
                foldState.isAnimating = false
                foldState.direction = 0

                // Collapse finishes by snapping the window over the
                // now-empty dark region — the seam is invisible, nothing
                // visibly slides.
                if coordinator.foldTarget == 0 {
                    var frame = window.frame
                    frame.size.width = ContentView.collapsedWidth
                    window.setFrame(frame, display: true)
                }
            }
        }
    }

    fileprivate static let displayLinkCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
        guard let context else { return kCVReturnSuccess }
        let box = Unmanaged<FoldBox>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { box.tick() }
        return kCVReturnSuccess
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Announces the moment SwiftUI attaches the view to its NSWindow —
    /// the only reliable hook for first-appearance sizing.
    final class WindowHookView: NSView {
        var onWindowAttached: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onWindowAttached?()
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowHookView()
        view.onWindowAttached = { [weak view] in
            guard let view, view.window != nil,
                  context.coordinator.lastTarget == nil else { return }
            configure(view.window)
            applyStateImmediately(to: view.window, context: context)

            // Late frame restorations can land after first appearance —
            // enforce once more after the dust settles.
            let window = view.window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak window] in
                guard let window, window == view.window,
                      context.coordinator.displayLink == nil else { return }
                let target = context.coordinator.lastTarget == true
                    ? ContentView.expandedWidth
                    : ContentView.collapsedWidth
                if abs(window.frame.width - target) > 0.5 {
                    var frame = window.frame
                    frame.size.width = target
                    window.setFrame(frame, display: true)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configure(window)

        if context.coordinator.lastTarget == nil {
            // First appearance before the hook fired: apply instantly.
            applyStateImmediately(to: window, context: context)
            return
        }
        if context.coordinator.lastTarget != expanded {
            context.coordinator.lastTarget = expanded
            startFold(to: expanded, window: window, coordinator: context.coordinator)
        } else if !foldState.isAnimating, abs(window.frame.width - targetWidth) > 0.5 {
            // Something (restored frames, stray sizing) drifted the window;
            // snap it back to the settled fold state. Never during a fold —
            // the window deliberately trails the dissolve.
            setFrame(width: targetWidth, of: window)
        }
    }

    // MARK: Fold driving

    private func applyStateImmediately(to window: NSWindow?, context: Context) {
        guard let window else { return }
        context.coordinator.lastTarget = expanded
        foldState.isAnimating = false
        foldState.direction = 0
        foldState.progress = expanded ? 1 : 0
        setFrame(width: expanded ? ContentView.expandedWidth : ContentView.collapsedWidth, of: window)
    }

    /// Sweeps the window edge at true display rate (vsync-locked via
    /// CVDisplayLink) while publishing progress for the pixel dissolve.
    /// The link only exists for the fold's lifetime.
    private func startFold(to expanded: Bool, window: NSWindow, coordinator: Coordinator) {
        coordinator.stopFold()

        let from = foldState.progress
        let target: CGFloat = expanded ? 1 : 0
        guard from != target else {
            foldState.progress = target
            foldState.isAnimating = false
            setFrame(width: expanded ? ContentView.expandedWidth : ContentView.collapsedWidth, of: window)
            return
        }

        foldState.direction = target > from ? 1 : -1
        foldState.isAnimating = true

        // Expand: the window opens FIRST — instantly, into darkness — and
        // the backdrop's pixels materialize into it one by one. Collapse:
        // the window stays put while every pixel dies, then snaps (in tick).
        if expanded {
            setFrame(width: ContentView.expandedWidth, of: window)
        }

        coordinator.foldFrom = from
        coordinator.foldTarget = target
        coordinator.foldStart = CFAbsoluteTimeGetCurrent()

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else {
            // No display link available — settle instantly instead of hanging.
            foldState.progress = target
            foldState.isAnimating = false
            foldState.direction = 0
            setFrame(width: expanded ? ContentView.expandedWidth : ContentView.collapsedWidth, of: window)
            return
        }

        let box = FoldBox()
        box.window = window
        box.coordinator = coordinator
        box.foldState = foldState

        let opaque = Unmanaged.passRetained(box).toOpaque()
        coordinator.foldContext = opaque
        coordinator.displayLink = link
        CVDisplayLinkSetOutputCallback(link, Self.displayLinkCallback, opaque)
        CVDisplayLinkStart(link)
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        // Hermite S-curve — smooth pickup and settle, native-feeling.
        t * t * (3 - 2 * t)
    }

    private func setFrame(width: CGFloat, of window: NSWindow) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true, animate: false)
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
        // The fold owns the width entirely — no invisible edge drags.
        window.styleMask.remove(.resizable)
        window.collectionBehavior = [.fullScreenAuxiliary]
        // SwiftUI persists & restores its own window frames ("NSWindow Frame
        // SwiftUI.WindowGroup<…>") — stale restored frames fight the fold.
        window.setFrameAutosaveName("")
    }

    /// The exact width the window must show for the current fold state.
    /// While a fold is in flight the window deliberately does NOT track
    /// progress — the dissolve is pure canvas work and the window only
    /// moves at the fold's boundary (see startFold).
    private var targetWidth: CGFloat {
        expanded ? ContentView.expandedWidth : ContentView.collapsedWidth
    }
}
