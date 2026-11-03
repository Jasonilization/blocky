//
//  SetupManager.swift
//  Blocky
//
//  PART 5 — First-run setup. The two things that reliably break a fresh
//  Blocky install are a missing Homebrew and a missing (or too old) Java.
//  This manager detects both, and — when the user asks — installs them,
//  streaming every output line into the launcher's own terminal so the
//  whole setup is visible instead of mysterious.
//
//  Everything it needs to decide is read through public, testable API:
//  EnvironmentToolkit (brew) + LauncherEngine (java, versions).
//

import Foundation
import SwiftUI
import Combine
import BlockyKit

@MainActor
final class SetupManager: ObservableObject {

    enum Phase: Equatable {
        case intro        // wizard just opened
        case checking     // probing the machine
        case ready        // rows show state; user picks an action
        case installing   // an install is running
        case done         // actions finished; re-checked
    }

    struct Row: Identifiable, Equatable {
        enum State: Equatable {
            case ok         // nothing to do
            case todo       // action available
            case blocked    // depends on an earlier step
            case fixing     // its action is running
            case failed     // its action failed
        }

        let id: String
        var title: String
        var detail: String
        var state: State
        var actionTitle: String?
        var secondaryTitle: String?

        var isOK: Bool { state == .ok }
    }

    // MARK: Published

    @Published private(set) var phase: Phase = .intro
    @Published private(set) var rows: [Row] = []
    @Published private(set) var stream: [String] = []
    @Published private(set) var busyActionID: String?

    let engine: LauncherEngine
    private var brewProcess: Process?

    init(engine: LauncherEngine) {
        self.engine = engine
    }

    // MARK: Derived facts

    /// The Java major the selected version needs — manifest javaVersion
    /// when Blocky can resolve it, era heuristic otherwise.
    func requiredJavaMajor() -> Int {
        let versionID = engine.selectedVersionID.isEmpty
            ? (engine.remoteVersions.first(where: { $0.isRelease })?.id ?? "26.3")
            : engine.selectedVersionID
        return LauncherEngine.heuristicJavaMajor(for: versionID)
    }

    var brewInstalled: Bool { EnvironmentToolkit.isBrewInstalled() }

    func javaCandidates() -> [LauncherEngine.JavaCandidate] {
        engine.javaCandidates.isEmpty ? LauncherEngine.detectJavaInstallations() : engine.javaCandidates
    }

    var hasSufficientJava: Bool {
        let required = requiredJavaMajor()
        return javaCandidates().contains { $0.major >= required }
    }

    // MARK: Checks

    func runChecks() {
        phase = .checking
        defer { phase = .ready }

        engine.refreshJavaCandidates()
        let brew = EnvironmentToolkit.brewBinary()
        let required = requiredJavaMajor()
        let candidates = javaCandidates()
        let best = candidates.filter { $0.major >= required }.sorted { $0.major < $1.major }.first
            ?? candidates.sorted { $0.major < $1.major }.last

        var newRows: [Row] = []

        newRows.append(Row(
            id: "gamedir",
            title: "GAME FOLDER",
            detail: engine.minecraftRoot.path,
            state: .ok,
            actionTitle: "open",
            secondaryTitle: nil
        ))

        newRows.append(Row(
            id: "versions",
            title: "VERSIONS INSTALLED",
            detail: engine.installedVersions.isEmpty
                ? "none yet — Blocky downloads any version you pick"
                : engine.installedVersions.prefix(4).joined(separator: ", ")
                    + (engine.installedVersions.count > 4 ? " +\(engine.installedVersions.count - 4) more" : ""),
            state: .ok,
            actionTitle: nil,
            secondaryTitle: nil
        ))

        newRows.append(Row(
            id: "brew",
            title: "HOME BREW",
            detail: brew.map { "installed (\($0.path))" } ?? "not installed — needed for one-tap Java",
            state: brew == nil ? .todo : .ok,
            actionTitle: brew == nil ? "Install Homebrew" : nil,
            secondaryTitle: brew == nil ? "learn more" : nil
        ))

        let brewState: Row.State
        if best?.major ?? 0 >= required {
            brewState = .ok
        } else if brew == nil {
            brewState = .blocked
        } else {
            brewState = .todo
        }

        newRows.append(Row(
            id: "java",
            title: "JAVA \(required)+",
            detail: best.map { "\u{2713} Java \($0.major) — \($0.displayName)" }
                ?? "no Java \(required)+ runtime found",
            state: brewState,
            actionTitle: brewState == .todo ? "Install Java \(required)" : nil,
            secondaryTitle: brewState == .todo ? "download Temurin" : nil
        ))

        rows = newRows
    }

    func rowState(for id: String) -> Row.State? {
        rows.first(where: { $0.id == id })?.state
    }

    // MARK: Actions

    func performAction(for row: Row) {
        switch row.id {
        case "gamedir":
            NSWorkspace.shared.open(engine.minecraftRoot)
        case "brew":
            installHomebrew()
        case "java":
            installJava()
        default:
            break
        }
    }

    func performSecondary(for row: Row) {
        switch row.id {
        case "brew":
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
        case "java":
            NSWorkspace.shared.open(URL(string: "https://adoptium.net/temurin/releases/")!)
        default:
            break
        }
    }

    // MARK: Homebrew install

    private func installHomebrew() {
        guard brewProcess == nil else { return }
        appendStream("==> Installing Homebrew — approve the prompt, macOS needs administrator rights")
        setRow(id: "brew", state: .fixing)

        let command = EnvironmentToolkit.homebrewInstallCommand().joined(separator: " ")
        // The AppleScript source needs the inner command escaped for its
        // own double-quoted string literal.
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendStreamText(text) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.pipeFinished(pipe)
                self?.brewProcess = nil
                if process.terminationStatus == 0 {
                    self?.appendStream("==> Homebrew installed")
                    // Apple Silicon installs to a prefix not on PATH for GUI
                    // apps — make it discoverable for this session.
                    self?.evaluateShellEnv()
                } else {
                    self?.appendStream("==> Homebrew install failed (status \(process.terminationStatus))")
                    self?.setRow(id: "brew", state: .failed)
                }
                self?.runChecks()
            }
        }

        do {
            brewProcess = process
            try process.run()
        } catch {
            setRow(id: "brew", state: .failed)
            appendStream("==> could not start the installer: \(error.localizedDescription)")
        }
    }

    /// GUI apps launch without the shell profile, so a fresh Homebrew
    /// prefix never lands on our PATH. Brew's own shellenv fixes that.
    private func evaluateShellEnv() {
        guard let brew = EnvironmentToolkit.brewBinary() else { return }
        if let output = ShellRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-lc", "\(brew.path) shellenv"]
        ) {
            for line in output.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("export ") else { continue }
                // export PATH="…" → key=value
                let body = text.replacingOccurrences(of: "export ", with: "")
                if let eq = body.firstIndex(of: "=") {
                    let key = String(body[body.startIndex..<eq])
                    var value = String(body[body.index(after: eq)...])
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    setenv(key, value, 1)
                }
            }
        }
    }

    // MARK: Java install

    private func installJava() {
        guard let brew = EnvironmentToolkit.brewBinary() else {
            appendStream("==> Homebrew missing — install it first")
            return
        }
        let required = requiredJavaMajor()
        let formula = EnvironmentToolkit.openJDKFormula(for: required)

        appendStream("==> brew install \(formula) — this takes a few minutes")
        setRow(id: "java", state: .fixing)

        let process = Process()
        process.executableURL = brew
        process.arguments = EnvironmentToolkit.brewInstallCommand(
            formula: formula, brewBinary: brew
        )

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendStreamText(text) }
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.pipeFinished(pipe)
                if finished.terminationStatus == 0 {
                    self?.appendStream("==> Java \(required) installed")
                    self?.runChecks()
                } else {
                    self?.appendStream("==> brew install failed (status \(finished.terminationStatus))")
                    self?.setRow(id: "java", state: .failed)
                }
            }
        }

        do {
            try process.run()
        } catch {
            setRow(id: "java", state: .failed)
            appendStream("==> could not start brew: \(error.localizedDescription)")
        }
    }

    // MARK: Stream helpers

    private func pipeFinished(_ pipe: Pipe) {
        // Drain whatever the readability handler has not yet seen.
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
            appendStreamText(text)
        }
    }

    private func appendStreamText(_ text: String) {
        Task { @MainActor in
            for raw in text.split(separator: "\n") {
                let line = String(raw)
                if line.isEmpty { continue }
                self.stream.append(line)
            }
            if self.stream.count > 200 { self.stream.removeFirst(self.stream.count - 200) }
        }
    }

    private func appendStream(_ line: String) {
        stream.append(line)
    }

    private func setRow(id: String, state: Row.State) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
    }

    // MARK: Completion

    func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }

    static var needsSetup: Bool {
        !UserDefaults.standard.bool(forKey: completedKey)
    }

    static let completedKey = "blocky.setupCompleted"
}
