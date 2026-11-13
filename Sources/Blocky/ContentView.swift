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
import UniformTypeIdentifiers
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

    /// Transient fold-animation state — shared with the window driver.
    @StateObject private var fold = FoldState()

    @StateObject private var engine = LauncherEngine()
    @StateObject private var setupManager: SetupManager
    @StateObject private var serverModel = ServerStatusModel()
    @FocusState private var usernameFieldFocused: Bool

    @State private var showSetupWizard = false
    @State private var showServersSheet = false

    /// The setup manager shares this view's engine instance — one object
    /// graph, one source of truth for versions and Java.
    init() {
        let engine = LauncherEngine()
        _engine = StateObject(wrappedValue: engine)
        _setupManager = StateObject(wrappedValue: SetupManager(engine: engine))
    }

    static let collapsedWidth: CGFloat = 340
    static let panelWidth: CGFloat = 372
    static let expandedWidth: CGFloat = collapsedWidth + panelWidth
    static let windowHeight: CGFloat = 528
    /// The hidden titlebar's strip: window content is 480 pt tall, of which
    /// the top 28 is the (invisible) titlebar area over which the backdrop
    /// must bleed to cover the window edge-to-edge.
    static let titleBarBleed: CGFloat = 28
    static let fullWindowHeight: CGFloat = windowHeight + titleBarBleed
    static let foldDuration: Double = 1.0

    /// Two-tap delete confirmation state for the versions list.
    @State private var pendingDeleteVersion: String?

    /// Hover highlight for the near-invisible fold tab.
    @State private var foldTabHovered = false

    /// Finder drops of mod jars and shader-pack zips.
    @State private var dropHovering = false
    @State private var dropNote: String?

    private let cornerRadius: CGFloat = 13

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Stretch marker: keeps the ZStack tracking the window's width so
            // the top-trailing controls ride the live edge. Everything visual
            // is fixed-size — no layer anywhere scales with window resizes,
            // which is what makes the fold's boundary snaps pixel-clean.
            // Hit testing stays off so empty glass drags the window.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            WindowDragger()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            mainColumn
                .frame(width: Self.collapsedWidth)
                // The backdrop is pinned to the constant FULL-WINDOW size and
                // bleeds under the hidden titlebar — covers edge-to-edge and
                // never re-lays (or squishes) when the window folds.
                .background(alignment: .topLeading) {
                    backgroundLayer
                        .frame(width: Self.expandedWidth, height: Self.fullWindowHeight)
                        .ignoresSafeArea(edges: .top)
                }
                // The panel rides an OVERLAY — overlays never contribute to
                // layout sizing. The window clips and reveals it, and the
                // panel fades with the fold so the whole thing dissolves as
                // one window.
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
        .overlay {
            if dropHovering {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    )
                    .overlay {
                        Text("Drop a mod .jar or a shader pack .zip")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .blockyBox(10, scrim: 0.28, lift: 0.16)
                    }
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropHovering) { providers in
            consumeDrop(providers)
        }
        .background(WindowConfigurator(expanded: $expanded, foldState: fold))
        .onAppear(perform: engine.bootstrap)
        .onAppear {
            // First run: walk the user through the machine check (folder,
            // versions, Homebrew, Java). Everything else stays rerunnable
            // from Settings.
            if SetupManager.needsSetup {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showSetupWizard = true
                }
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardView(manager: setupManager)
        }
        .sheet(isPresented: $showServersSheet) {
            ServersSheet(model: serverModel) { entry in
                showServersSheet = false
                engine.launchToServer(
                    username: username,
                    serverAddress: entry.address,
                    serverName: entry.name
                )
            }
        }
        .onAppear {
            // Ping recommended servers immediately — no expansion needed.
            serverModel.refreshAll()
        }
    }

    // MARK: Background

    private var backgroundLayer: some View {
        // Frosted keeps its glass; pixel styles are truly transparent —
        // no material behind them, just blocks floating over the desktop.
        // Half-built and dissolved regions show the raw desktop through
        // the window.
        if PixelBackgroundStyle(rawValue: backgroundRaw) != .frosted,
           let style = PixelBackgroundStyle(rawValue: backgroundRaw) {
            return AnyView(
                ZStack(alignment: .topLeading) {
                    PixelBackgroundView(style: style, fold: fold, assetsDirectory: engine.assetsDirectory)
                    // A light even wash so labels stay readable. The block art
                    // stays the colour from the README swatch.
                    Color.black.opacity(style.scrim * 0.45)
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(false)
            )
        }
        return AnyView(Color.clear.background(.ultraThinMaterial).allowsHitTesting(false))
    }

    // MARK: Window controls (fold toggle + terminal quick-open)

    private var windowControls: some View {
        foldToggle
    }

    /// The fold controls: a near-invisible drawer tab hugging the top-right
    /// corner. Collapsed it is a `›` in accent colour; expanded a `‹` in
    /// secondary grey — the only chrome on the window besides the wordmark,
    /// yet with a full-size hit target and a tooltip so it is never a
    /// mystery.
    private var foldToggle: some View {
        Button {
            // WindowConfigurator picks this up and drives the dissolve.
            expanded.toggle()
        } label: {
            Image(systemName: expanded ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(expanded ? Color.secondary : Color.accentColor)
                .frame(width: 32, height: 34)
                .blockyBox(8, scrim: 0.14, highlighted: foldTabHovered, lift: 0.22)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            foldTabHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(expanded ? "Fold the panel closed (collapse the window)"
                       : "Open settings & terminal (expand the window)")
    }

    // MARK: Main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            header
            Spacer(minLength: 14)
            VStack(spacing: 12) {
                usernameRow
                versionRow
            }
            .frame(maxWidth: .infinity)
            statusSlot
                .padding(.top, 14)
            launchButton
                .padding(.top, 10)
            ServerChips(model: serverModel, launchServer: { entry in
                engine.launchToServer(
                    username: username,
                    serverAddress: entry.address,
                    serverName: entry.name
                )
            }, showAll: {
                showServersSheet = true
            })
            .padding(.top, 14)
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 26)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("BLOCKY")
                .font(.system(size: 27, weight: .heavy, design: .monospaced))
                .kerning(5.5)
                .foregroundStyle(.primary)
            Text("OFFLINE LAUNCHER")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .kerning(2.4)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .blockyBox(14, scrim: 0.22, lift: 0.18)
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
        .blockyBox(cornerRadius, scrim: 0.14, highlighted: usernameFieldFocused, lift: 0.30)
    }

    private var versionRow: some View {
        versionChrome
            .overlay {
                Menu {
                    versionMenuContent
                } label: {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .disabled(engine.isWorking)
            }
    }

    private var versionChrome: some View {
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
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .blockyBox(cornerRadius, scrim: 0.14, lift: 0.30)
    }

    @ViewBuilder
    private var versionMenuContent: some View {
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
            } else if let dropNote, !engine.isWorking {
                statusLabel(dropNote, color: .secondary)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 280)
            .blockyBox(8, scrim: 0.24, lift: 0.12)
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
                ZStack {
                    // Accent body, lifted at the top edge…
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(canLaunch ? 1 : 0.35),
                            canLaunch ? Color.accentColor : Color.accentColor.opacity(0.35)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // …with a glassy sheen riding the upper third.
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0)],
                        startPoint: .top,
                        endPoint: .init(x: 0.5, y: 0.62)
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.accentColor.opacity(canLaunch ? 0.45 : 0), radius: 12, x: 0, y: 4)
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
            panelHeader("SETTINGS")

            // One glass substrate for the whole settings block: every row's
            // text (HEAP slider, AUTO, folders, setup) finally has something
            // behind it, so nothing sits raw on the block texels.
            VStack(alignment: .leading, spacing: 6) {
                settingsRow(label: "HEAP") { heapSlider }
                settingsRow(label: "JAVA") { javaMenu }
                settingsRow(label: "BACKDROP") { backgroundMenu }
                settingsRow(label: "SNAPSHOTS") { snapshotsToggle }
                settingsRow(label: "GAME DIR") { gameDirField }
                settingsRow(label: "FOLDERS") { folderButtons }
                settingsRow(label: "SETUP") {
                    Button {
                        showSetupWizard = true
                    } label: {
                        Label("Run setup wizard", systemImage: "wizard.and.hat")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Re-check Homebrew, Java, and the game folder")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .blockyBox(12, scrim: 0.16, lift: 0.16)

            HStack(spacing: 8) {
                panelHeader("VERSIONS")
                Spacer()
                Text("own files · shared libraries not included")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
            versionsList
                .frame(minHeight: 44)
                .task(id: pendingDeleteVersion) {
                    // Two-tap confirm: the first tap arms the trash, the
                    // second deletes. Arming expires after 2.5 s.
                    guard pendingDeleteVersion != nil else { return }
                    try? await Task.sleep(for: .seconds(2.5))
                    pendingDeleteVersion = nil
                }

            creditsRow
        }
        .padding(.top, 28)
        .padding(.bottom, 16)
        .padding(.horizontal, 18)
        .frame(minHeight: Self.windowHeight, alignment: .top)
    }

    private func panelHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .kerning(2)
            .foregroundStyle(.tertiary)
            .legibleShadow()
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .padding(3)
                }
                .frame(maxHeight: 88)
            }
        }
        .padding(6)
        .blockyBox(10, scrim: 0.14, lift: 0.14)
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
        .blockyBox(
            6,
            scrim: armed ? 0.16 : 0.08,
            tint: armed ? Color.red.opacity(0.16) : nil,
            lift: 0.14
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
        .blockyBox(8, scrim: 0.12, lift: 0.20)
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
        .help(name == "mods"
              ? "Open the mods folder — or drop a .jar anywhere on the window"
              : "Open shader packs — or drop a .zip anywhere on the window")
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
        .frame(height: 24)
        .fixedSize(horizontal: true, vertical: false)
        .blockyBox(8, scrim: 0.18, lift: 0.14)
        .contentShape(Rectangle())
    }

    /// Finder drop: `.jar` lands in `mods/`, `.zip` in `shaderpacks/`.
    private func consumeDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let found = item as? URL {
                    url = found
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            self.installDropped(urls)
        }
        return true
    }

    private func installDropped(_ urls: [URL]) {
        guard !urls.isEmpty else {
            dropNote = "That drop didn't include a file"
            return
        }
        var notes: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let folder: String
            switch ext {
            case "jar":
                folder = "mods"
            case "zip":
                folder = "shaderpacks"
            default:
                notes.append("\(url.lastPathComponent) isn't a .jar or .zip")
                continue
            }
            let directory = engine.minecraftRoot.appendingPathComponent(folder, isDirectory: true)
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                notes.append("\(url.lastPathComponent) → \(folder)")
            } catch {
                notes.append("couldn't copy \(url.lastPathComponent)")
            }
        }
        dropNote = notes.joined(separator: " · ")
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
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .blockyBox(8, scrim: 0.16, lift: 0.12)
    }

    // MARK: Shared shape

}

// MARK: - Shared box treatment

/// One visual language for every box in Blocky.
///
/// Each box is a REAL blur of whatever backdrop sits behind it (block
/// textures, the desktop), darkened with a scrim so text stays legible
/// over the busiest texel, rim-lit top-to-bottom so it reads as glass, and
/// lifted off the wallpaper with a soft shadow. Highlighted picks up an
/// accent edge for focus.
extension View {
    func blockyBox(
        _ radius: CGFloat = 10,
        scrim: Double = 0.14,
        highlighted: Bool = false,
        tint: Color? = nil,
        lift: Double = 0.26
    ) -> some View {
        modifier(BlockyBoxStyle(
            radius: radius, scrim: scrim, highlighted: highlighted, tint: tint, lift: lift
        ))
    }
}

private struct BlockyBoxStyle: ViewModifier {
    var radius: CGFloat
    var scrim: Double
    var highlighted: Bool
    var tint: Color?
    var lift: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(
                ZStack {
                    // Real blur of the backdrop behind the box…
                    shape.fill(.thinMaterial)
                    // …then a darkening wash so text never fights texels.
                    shape.fill(Color.black.opacity(scrim))
                    if let tint {
                        shape.fill(tint)
                    }
                }
            )
            .clipShape(shape)
            .overlay {
                if highlighted {
                    shape.strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1)
                } else {
                    // A sheen that falls off downward reads as a rim catch.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
            }
            .shadow(color: .black.opacity(lift), radius: radius * 0.55, x: 0, y: 2)
    }
}

/// A soft halo so text sitting directly on busy block texels stays legible.
extension View {
    func legibleShadow() -> some View {
        shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
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

    /// The panel UI's own opacity. Collapsing: text dies immediately;
    /// expanding: the pixels build first, the text arrives last.
    var panelOpacity: Double {
        if !isAnimating {
            return progress > 0.5 ? 1 : 0
        }
        if direction < 0 {
            return max(0, min(1, (progress - 0.80) / 0.15))
        }
        return max(0, min(1, (progress - 0.72) / 0.20))
    }
}

/// Fades the panel's UI in step with the fold so the minimize feels complete:
/// the panel's own widgets dissolve out with its backdrop blocks, instead of
/// vanishing abruptly when the window edge passes them.
private struct PanelFade<Content: View>: View {
    @ObservedObject var fold: FoldState
    @ViewBuilder var content: Content

    var body: some View {
        content.opacity(fold.panelOpacity)
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
        case .mossyCobblestone: return "minecraft:block/mossy_cobblestone.png"
        case .sculk:     return "minecraft:block/sculk.png"
        case .amethyst:  return "minecraft:block/amethyst_block.png"
        case .tuff:      return "minecraft:block/tuff.png"
        case .copper:     return "minecraft:block/copper_block.png"
        case .darkOak:    return "minecraft:block/dark_oak_planks.png"
        }
    }

    /// Resolves a material's real texture. First choice is the swatch shipped
    /// in the README (`docs/backdrops/tex`), so the window matches that art.
    /// The installed client jar is only a fallback.
    static func texture(for style: PixelBackgroundStyle, assetsDirectory: URL) -> CGImage? {
        guard let key = textureKey(for: style) else { return nil }
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        if let shipped = readmeTexture(for: style) {
            cache.setObject(shipped, forKey: cacheKey)
            return shipped
        }

        // Jar entry: "minecraft:block/cobblestone.png" →
        // "assets/minecraft/textures/block/cobblestone.png"
        let entry = "assets/minecraft/textures/" + key.replacingOccurrences(
            of: "minecraft:", with: ""
        )

        let versionsDirectory = assetsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("versions", isDirectory: true)
        let fileManager = FileManager.default

        var jars: [URL] = []
        if let versionDirs = try? fileManager.contentsOfDirectory(
            at: versionsDirectory, includingPropertiesForKeys: nil) {
            jars = versionDirs
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .compactMap { dir in
                    let jar = dir.appendingPathComponent(dir.lastPathComponent + ".jar")
                    return fileManager.fileExists(atPath: jar.path) ? jar : nil
                }
        }

        for jar in jars {
            if let data = extractJarEntry(named: entry, fromJar: jar),
               var image = image(from: data) {
                // Animated strips (e.g. sculk): use the first square frame.
                if image.height > image.width {
                    image = image.cropping(to: CGRect(x: 0, y: 0,
                                                      width: image.width,
                                                      height: image.width)) ?? image
                }
                // Grass sides ship with a gray crown; the game composites a
                // biome-tinted overlay on top. Do the same.
                if style == .grass {
                    image = Self.compositedGrassSide(base: image, jar: jar) ?? image
                }
                cache.setObject(image, forKey: cacheKey)
                return image
            }
        }

        // Secondary: legacy named-asset indexes.
        let indexesDirectory = assetsDirectory.appendingPathComponent("indexes", isDirectory: true)
        if let indexes = try? fileManager.contentsOfDirectory(atPath: indexesDirectory.path) {
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
        }
        return nil
    }

    /// The block swatches shown in the README. Same filenames as the style
    /// raw values (`grass.png`, `darkOak.png`, …).
    private static func readmeTexture(for style: PixelBackgroundStyle) -> CGImage? {
        let file = style.rawValue + ".png"
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/backdrops/tex/\(file)")
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("backdrops/tex", isDirectory: true)
            .appendingPathComponent(file)
        for url in [bundled, repo].compactMap({ $0 }) {
            if let image = loadPNG(at: url) { return image }
        }
        return nil
    }

    /// `unzip -p` one entry's bytes out of a jar (jars are zip archives).
    private static func extractJarEntry(named entry: String, fromJar jar: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", jar.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    /// The game's grass-side: dirt + a gray crown, with a separate overlay
    /// texture tinted by the biome's grass color and drawn on top.
    private static func compositedGrassSide(base: CGImage, jar: URL) -> CGImage? {
        guard let overlayData = extractJarEntry(
                named: "assets/minecraft/textures/block/grass_block_side_overlay.png",
                fromJar: jar),
              let overlay = image(from: overlayData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let size = base.width

        // Tint the overlay: overlay × biome green.
        guard let tinted = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        tinted.draw(overlay, in: CGRect(x: 0, y: 0, width: size, height: size))
        tinted.setBlendMode(.multiply)
        // 0x7CBD6B — the game's plains grass color.
        tinted.setFillColor(red: 0x7C / 255.0, green: 0xBD / 255.0, blue: 0x6B / 255.0, alpha: 1)
        tinted.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let tintImage = tinted.makeImage() else { return nil }

        // Composite over the base side.
        guard let composited = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        composited.draw(base, in: CGRect(x: 0, y: 0, width: size, height: size))
        composited.draw(tintImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return composited.makeImage()
    }

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
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
    case mossyCobblestone
    case sculk
    case amethyst
    case tuff
    case copper
    case darkOak

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
        case .mossyCobblestone: return "Mossy Cobble"
        case .sculk:     return "Sculk"
        case .amethyst:  return "Amethyst"
        case .tuff:      return "Tuff"
        case .copper:     return "Copper"
        case .darkOak:    return "Dark Oak"
        }
    }

    /// How much dark scrim keeps UI text readable over the glass — light,
    /// since the blocks carry most of their own darkness.
    var scrim: Double {
        switch self {
        case .frosted:    return 0.0
        case .grass:      return 0.32
        case .dirt:       return 0.28
        case .stone:      return 0.28
        case .cobblestone: return 0.28
        case .planks:     return 0.28
        case .sandstone:  return 0.32
        case .netherrack: return 0.28
        case .endstone:   return 0.32
        case .deepslate:  return 0.18
        case .obsidian:   return 0.15
        case .mossyCobblestone: return 0.26
        case .sculk:     return 0.12
        case .amethyst:  return 0.30
        case .tuff:      return 0.24
        case .copper:     return 0.26
        case .darkOak:    return 0.24
        }
    }
}

// MARK: - Backdrop renderer + cache

/// Renders the full backdrop (all blocks alive) ONCE per style into a
/// 712×452 image, then serves blits. Folds never recompute texels — they
/// only draw cached block regions with per-block alpha — which is what
/// makes the dissolve frame cost ~0.2 ms instead of ~10 ms of texel math.
enum BackdropRenderer {
    private static var cache: [String: (image: CGImage, blocks: [[CGImage]], mainStrip: CGImage)] = [:]
    private static let lock = NSLock()

    static let canvasWidth: CGFloat = 712
    static let canvasHeight: CGFloat = ContentView.fullWindowHeight   // 480 incl. titlebar bleed
    static let block: CGFloat = 64

    /// Renders the backdrop AND pre-slices its block grid in one pass, so
    /// folds never slice mid-animation (no first-fold hitch, no flash).
    static func cache(for style: PixelBackgroundStyle, assetsDirectory: URL)
        -> (image: CGImage, blocks: [[CGImage]], mainStrip: CGImage)? {
        guard style != .frosted else { return nil }
        lock.lock()
        if let cached = cache[style.rawValue] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let image = render(style: style, assetsDirectory: assetsDirectory)
        let step = Int(block)
        var grid: [[CGImage]] = []
        for row in 0...(image.height / step) {
            var rowBlocks: [CGImage] = []
            let y = row * step
            let height = min(step, image.height - y)
            guard height > 0 else { continue }
            for column in 0...(image.width / step) {
                let x = column * step
                let width = min(step, image.width - x)
                guard width > 0 else { continue }
                rowBlocks.append(image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) ?? image)
            }
            grid.append(rowBlocks)
        }

        // Pre-cropped main-column strip — one allocation at cache time,
        // not one per frame.
        let mainColumns = Int((ContentView.collapsedWidth / block).rounded(.up)) + 1
        let stripWidth = min(Int(CGFloat(mainColumns) * block), image.width)
        let mainStrip = image.cropping(to: CGRect(x: 0, y: 0, width: stripWidth, height: image.height)) ?? image

        let entry = (image, grid, mainStrip)
        lock.lock()
        cache[style.rawValue] = entry
        lock.unlock()
        return entry
    }

    private static func render(style: PixelBackgroundStyle, assetsDirectory: URL) -> CGImage {

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: Int(canvasWidth), height: Int(canvasHeight),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let official = OfficialTextures.texture(for: style, assetsDirectory: assetsDirectory)
        let block: CGFloat = BackdropRenderer.block
        let texels = 8
        let texel = block / CGFloat(texels)
        let columns = Int(canvasWidth / block) + 1
        let rows = Int(canvasHeight / block) + 1

        func seeded(_ i: Int) -> Double {
            var value = abs(Double(i % 100003) + 0.5)
            value = sin(value * 12.9898) * 43758.5453
            return value - value.rounded(.towardZero)
        }

        for row in 0..<rows {
            for column in 0..<columns {
                let blockSeed = column &* 73856093 &+ row &* 19349663
                let blockX = CGFloat(column) * block
                let blockY = CGFloat(row) * block

                if let official {
                    // Exact 2:1 of the 128px README swatch, plus one pixel of
                    // overlap so the tiles don't show a dark grout line.
                    ctx.interpolationQuality = .none
                    ctx.draw(official, in: CGRect(x: blockX, y: blockY, width: block + 1, height: block + 1))
                    continue
                }

                let blockShade = CGFloat(0.86 + seeded(blockSeed &+ 3) * 0.28)
                for ty in 0..<texels {
                    for tx in 0..<texels {
                        let texelSeed = blockSeed &+ tx &* 83492791 &+ ty &* 2971215073
                        let noise = seeded(texelSeed)
                        let shade = texelShade(style: style, tx: tx, ty: ty, noise: noise, blockSeed: blockSeed)
                        let rgb = palette(style: style, shade: shade)
                        ctx.setFillColor(
                            red: rgb.0 * Double(blockShade),
                            green: rgb.1 * Double(blockShade),
                            blue: rgb.2 * Double(blockShade),
                            alpha: 1
                        )
                        ctx.fill(CGRect(
                            x: blockX + CGFloat(tx) * texel,
                            y: blockY + CGFloat(ty) * texel,
                            width: texel + 0.5, height: texel + 0.5
                        ))
                    }
                }
            }
        }

        let image = ctx.makeImage()!
        return image
    }

    /// Style-specific shading: returns a 0…1 palette index. (Mirrors the
    /// in-app procedural generator so cached backdrops look identical.)
    private static func texelShade(style: PixelBackgroundStyle, tx: Int, ty: Int,
                                   noise: Double, blockSeed: Int) -> Double {
        func seeded(_ i: Int) -> Double {
            var value = abs(Double(i % 100003) + 0.5)
            value = sin(value * 12.9898) * 43758.5453
            return value - value.rounded(.towardZero)
        }
        let texels = 8
        func clustered(_ tx: Int, _ ty: Int) -> Double {
            seeded(blockSeed &+ (tx / 2) &* 2971 &+ (ty / 2) &* 7331)
        }
        func rowOf(_ seed: Int) -> Int { (seed / 19349663) % 97 }

        switch style {
        case .frosted: return 0.5
        case .grass:
            if ty <= 1 { return noise < 0.18 ? 0.5 : 0.85 }
            if ty == 2 { return seeded(blockSeed &+ tx &* 733) > 0.45 ? 0.7 : 0.55 }
            if ty == 3 && noise < 0.3 { return 0.6 }
            if noise < 0.22 { return 0.22 }
            if noise > 0.9 { return 0.75 }
            return 0.45 + clustered(tx, ty) * 0.15
        case .dirt:
            if noise < 0.22 { return 0.22 }
            if noise > 0.9 { return 0.75 }
            return 0.5
        case .stone:
            let c = clustered(tx, ty)
            if c < 0.3 { return 0.3 }
            if c > 0.78 { return 0.68 }
            return 0.5
        case .cobblestone:
            let border = tx == 0 || ty == 0 || tx == texels - 1 || ty == texels - 1
            if border { return 0.22 }
            return clustered(tx, ty) < 0.35 ? 0.38 : 0.62
        case .planks:
            if ty == 0 { return 0.2 }
            if ty == texels - 1 && seeded(blockSeed &+ 505) > 0.7 { return 0.42 }
            if seeded(blockSeed &+ tx &* 971) < 0.3 { return 0.36 }
            if seeded(blockSeed) > 0.93 && (tx == 3 || tx == 4) && (ty == 3 || ty == 4) { return 0.3 }
            return 0.55
        case .sandstone:
            if ty == 0 && rowOf(blockSeed) % 3 == 0 { return 0.4 }
            if noise < 0.12 { return 0.42 }
            return 0.62
        case .netherrack:
            let c = clustered(tx, ty)
            if c < 0.28 { return 0.25 }
            if noise > 0.955 { return 0.8 }
            return 0.5
        case .endstone:
            let c = clustered(tx, ty)
            if c < 0.34 { return 0.42 }
            if c > 0.82 { return 0.72 }
            return 0.58
        case .deepslate:
            if noise < 0.1 { return 0.2 }
            if noise > 0.96 { return 0.55 }
            return 0.36
        case .obsidian:
            let streak = seeded(blockSeed &+ ty &* 6151) > 0.86
            if streak && tx % 2 == 0 { return 0.5 }
            if noise < 0.1 { return 0.1 }
            return 0.28
        case .mossyCobblestone:
            let border = tx == 0 || ty == 0 || tx == texels - 1 || ty == texels - 1
            if border { return 0.2 }
            if noise < 0.28 { return 0.55 }                       // moss patches
            return clustered(tx, ty) < 0.35 ? 0.36 : 0.60          // stone faces
        case .sculk:
            if noise > 0.93 { return 0.85 }                       // glow spots
            if noise < 0.12 { return 0.18 }
            return 0.45
        case .amethyst:
            let band = seeded((tx + ty) / 2 &+ blockSeed) < 0.4
            if noise > 0.95 { return 0.85 }                       // sparkle
            return band ? 0.40 : 0.62
        case .tuff:
            let c = clustered(tx, ty)
            if c < 0.3 { return 0.24 }
            if c > 0.78 { return 0.55 }
            return 0.40
        case .copper:
            if noise < 0.15 { return 0.62 }                        // patina flecks
            if noise > 0.92 { return 0.75 }
            return 0.5
        case .darkOak:
            if ty == 0 { return 0.14 }
            if seeded(blockSeed &+ tx &* 971) < 0.3 { return 0.28 }
            if seeded(blockSeed) > 0.93 && (tx == 3 || tx == 4) && (ty == 3 || ty == 4) { return 0.24 }
            return 0.42
        }
    }

    private static func palette(style: PixelBackgroundStyle, shade: Double) -> (Double, Double, Double) {
        let ramps: [[Double]] = [
            [0.16, 0.34, 0.12, 0.42, 0.66, 0.30, 0.55, 0.82, 0.42],
            [0.22, 0.15, 0.10, 0.42, 0.29, 0.19, 0.58, 0.43, 0.30],
            [0.28, 0.28, 0.30, 0.46, 0.46, 0.48, 0.62, 0.62, 0.64],
            [0.26, 0.26, 0.28, 0.44, 0.44, 0.46, 0.60, 0.60, 0.62],
            [0.30, 0.22, 0.12, 0.52, 0.40, 0.24, 0.68, 0.55, 0.35],
            [0.52, 0.45, 0.30, 0.72, 0.64, 0.44, 0.86, 0.79, 0.60],
            [0.20, 0.06, 0.05, 0.42, 0.13, 0.10, 0.58, 0.22, 0.16],
            [0.48, 0.46, 0.30, 0.66, 0.63, 0.44, 0.82, 0.79, 0.60],
            [0.07, 0.07, 0.09, 0.15, 0.15, 0.18, 0.22, 0.22, 0.26],
            [0.04, 0.02, 0.09, 0.10, 0.05, 0.18, 0.20, 0.12, 0.34],
            [0.18, 0.20, 0.16, 0.34, 0.40, 0.28, 0.50, 0.60, 0.38],
            [0.04, 0.10, 0.12, 0.09, 0.20, 0.24, 0.16, 0.42, 0.46],
            [0.24, 0.12, 0.40, 0.42, 0.24, 0.62, 0.62, 0.42, 0.85],
            [0.16, 0.16, 0.16, 0.28, 0.28, 0.28, 0.42, 0.42, 0.42],
            [0.38, 0.20, 0.12, 0.58, 0.32, 0.18, 0.80, 0.46, 0.28],
            [0.14, 0.09, 0.05, 0.26, 0.17, 0.09, 0.40, 0.27, 0.15],
        ]
        let index: Int
        switch style {
        case .frosted, .grass: index = 0
        case .dirt: index = 1
        case .stone: index = 2
        case .cobblestone: index = 3
        case .planks: index = 4
        case .sandstone: index = 5
        case .netherrack: index = 6
        case .endstone: index = 7
        case .deepslate: index = 8
        case .obsidian: index = 9
        case .mossyCobblestone: index = 10
        case .sculk: index = 11
        case .amethyst: index = 12
        case .tuff: index = 13
        case .copper: index = 14
        case .darkOak: index = 15
        }
        // Bounds-hardened: a missing ramp entry must never take the app
        // down — fall back to the grass ramp instead.
        let ramp = ramps.indices.contains(index) ? ramps[index] : ramps[0]
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

private struct PixelBackgroundView: View {
    let style: PixelBackgroundStyle
    @ObservedObject var fold: FoldState
    let assetsDirectory: URL

    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        guard style != .frosted else { return }

        guard let (fullImage, grid, mainStrip) = BackdropRenderer.cache(for: style, assetsDirectory: assetsDirectory)
        else { return }

        // One render path for idle AND fold states: the main strip plus
        // the panel's block grid. Settled states are just "all alphas
        // known" — so the instant a fold ends, the picture is bit-identical
        // to the last animation frame. No settle flash, ever.
        //
        // Settled frames draw the cached picture in one blit. Stretching the
        // left strip to the canvas height and then stamping blocks beside it
        // shifted the pattern at the join.
        let block = BackdropRenderer.block
        let mainColumns = Int((ContentView.collapsedWidth / block).rounded(.up)) + 1

        let isAnimating = fold.isAnimating
        let panelAlive = fold.isAnimating || fold.progress > 0.5

        context.withCGContext { ctx in
            ctx.interpolationQuality = .none

            if !isAnimating {
                let source = panelAlive ? fullImage : mainStrip
                ctx.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height)))
                return
            }

            // Main column strip — cached subimage, always alive. Drawn at
            // its own pixel size so the panel blocks land on the same grid.
            ctx.draw(mainStrip, in: CGRect(
                x: 0, y: 0,
                width: CGFloat(mainStrip.width),
                height: CGFloat(mainStrip.height)
            ))

            // Panel blocks. Two passes: fully-opaque blocks draw with no
            // per-block state changes; only the fading band pays for
            // saveGState/setAlpha/restoreGState.
            var fading: [(CGImage, CGRect, Double)] = []
            ctx.setAlpha(1)

            for (rowIndex, rowBlocks) in grid.enumerated() {
                let blockY = CGFloat(rowIndex) * block
                guard blockY < size.height else { break }
                for column in mainColumns..<rowBlocks.count {
                    let blockX = CGFloat(column) * block
                    guard blockX < size.width else { break }

                    let alpha: Double
                    if !isAnimating {
                        alpha = panelAlive ? 1 : 0   // settled: whole or nothing
                    } else {
                        let xNorm = max(0, min(1,
                            (blockX - ContentView.collapsedWidth) / ContentView.panelWidth))
                        let blockSeed = column &* 73856093 &+ rowIndex &* 19349663
                        let threshold = 0.02 + xNorm * 0.77
                            + seeded(blockSeed &+ 101) * 0.08
                        // Wide fade window (0.14 of the fold) — each block
                        // crossfades over ~8 frames instead of popping.
                        alpha = max(0, min(1, (fold.progress - threshold) / 0.14))
                    }
                    if alpha <= 0 { continue }

                    let rect = CGRect(x: blockX, y: blockY, width: block, height: block)
                    if alpha >= 1 {
                        ctx.draw(rowBlocks[column], in: rect)
                    } else {
                        fading.append((rowBlocks[column], rect, alpha))
                    }
                }
            }

            for (image, rect, alpha) in fading {
                ctx.saveGState()
                ctx.setAlpha(alpha)
                ctx.draw(image, in: rect)
                ctx.restoreGState()
            }
            ctx.setAlpha(1)
        }
    }

    private func seeded(_ i: Int) -> Double {
        var value = abs(Double(i % 100003) + 0.5)
        value = sin(value * 12.9898) * 43758.5453
        return value - value.rounded(.towardZero)   // fract()
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

/// Empty regions of the window drag it. Controls stacked above this view
/// still receive their own clicks.
private struct WindowDragger: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
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
        var isGliding = false
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
        var lastTick: Double = 0

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

                // Collapse finishes with a short glide over the already-
                // dissolved (empty, transparent) region. Every layer in the
                // window is fixed-size, so this resize only sweeps a clip —
                // no scaling, no jank — it just removes the jump.
                if coordinator.foldTarget == 0 {
                    WindowConfigurator.glide(
                        to: ContentView.collapsedWidth,
                        window: window,
                        coordinator: coordinator
                    )
                }
            }
        }
    }

    fileprivate static let displayLinkCallback: CVDisplayLinkOutputCallback = { _, _, inNow, _, _, context in
        guard let context else { return kCVReturnSuccess }
        let box = Unmanaged<FoldBox>.fromOpaque(context).takeUnretainedValue()
        // Cap at ~60 fps: on ProMotion displays the link fires at 120 Hz,
        // which doubles canvas work for zero visible gain in a 1 s dissolve.
        do {
            let ts = inNow.pointee
            let tickInterval = ts.videoTimeScale > 0
                ? Double(ts.videoTime) / Double(ts.videoTimeScale)
                : 0
            if tickInterval - box.lastTick < 0.015 { return kCVReturnSuccess }
            box.lastTick = tickInterval
        }
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
        } else if !foldState.isAnimating, !context.coordinator.isGliding,
                  abs(window.frame.width - targetWidth) > 0.5 {
            // Something (restored frames, stray sizing) drifted the window;
            // snap it back to the settled fold state. Never during a fold or
            // a boundary glide — the window deliberately trails the dissolve.
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

        // Expand: the window glides open into empty space while the pixels
        // materialize behind the sweep — no hard pop, no black box.
        if expanded {
            WindowConfigurator.glide(
                to: ContentView.expandedWidth,
                window: window,
                coordinator: coordinator
            )
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

    /// Short eased window resize. Safe now that every layer is fixed-size:
    /// the resize sweeps only a clip — nothing scales, so it stays smooth.
    fileprivate static func glide(to width: CGFloat, window: NSWindow, coordinator: Coordinator) {
        coordinator.isGliding = true
        var frame = window.frame
        frame.size.width = width
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: {
            coordinator.isGliding = false
        })
    }

    private func setFrame(width: CGFloat, of window: NSWindow) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true, animate: false)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        // The fold owns this window's geometry; never let AppKit state
        // restoration resurrect stale frames or spawn phantom windows.
        window.isRestorable = false
        window.invalidateRestorableState()
        window.setFrameAutosaveName("")
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
