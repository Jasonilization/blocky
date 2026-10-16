//
//  LauncherEngine.swift
//  Blocky
//
//  PART 2 — Core Launcher Backend Mechanics.
//
//  An ObservableObject that owns the entire launch pipeline:
//    1. Resolves ~/Library/Application Support/minecraft automatically.
//    2. Scans the local versions folder (hidden files filtered, natural
//       descending order) to populate the frontend picker.
//    3. Generates the standard offline UUID (MD5 "OfflinePlayer:<name>",
//       version-3 + RFC 4122 variant bits — identical to Java's
//       UUID.nameUUIDFromBytes).
//    4. Compiles the runtime classpath: every .jar under libraries/,
//       recursively, plus the version's main client jar, colon-joined.
//    5. Auto-detects a suitable Java runtime (java_home, Homebrew openjdk,
//       system JVMs, JAVA_HOME) and spawns the game via Process() on a
//       background utility queue with full offline parameters.
//    6. Streams the child's stdout/stderr into the development console with
//       asynchronous readability handlers.
//

import Foundation
import CryptoKit
import Combine

// MARK: - Errors

enum LaunchError: LocalizedError {
    case versionUnavailable(String)
    case clientJarMissing(String)
    case librariesMissing
    case javaNotFound(Int)
    case downloadFailed(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .versionUnavailable(let id):
            return "“\(id)” was not found locally and is not in Mojang's manifest."
        case .clientJarMissing(let id):
            return "The client jar for “\(id)” is missing — select the version again to re-fetch it."
        case .librariesMissing:
            return "No library jars were found — let Blocky download the version first."
        case .javaNotFound(let required):
            return "No Java runtime found (Java \(required)+ required). Install one:  brew install openjdk@\(required)"
        case .downloadFailed(let detail):
            return "Download failed — \(detail)"
        case .checksumMismatch(let label):
            return "Integrity check failed for \(label) — the download will be retried on the next launch."
        }
    }

    var userFacingMessage: String {
        errorDescription ?? "Unexpected launch error."
    }
}

// MARK: - Shell helper

/// Tiny synchronous wrapper around Process used only for fast probes
/// (`/usr/libexec/java_home`, `java -version`, archive extraction).
enum ShellRunner {

    /// Runs a binary and returns its combined output on exit code 0.
    static func run(executablePath: String, arguments: [String] = []) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        // One shared pipe for both channels: neither probe produces more than
        // a few kilobytes, so a single 64 KiB buffer cannot deadlock.
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// Runs a prepared Process discarding all output; true on exit code 0.
    static func runSilently(_ process: Process) -> Bool {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - Output streaming

/// Pipes a child process's output into the development console line by line.
/// A readability handler pushes chunks onto a serial utility queue where they
/// are reassembled into lines, so the buffer never stalls the child process.
final class LogStreamer {

    private let queue: DispatchQueue
    private let sink: (String) -> Void
    private let lock = NSLock()
    private var pendingLine = Data()
    private var readingHandle: FileHandle?

    init(label: String, sink: @escaping (String) -> Void) {
        self.queue = DispatchQueue(label: "dev.blocky.launcher.stream.\(label)", qos: .utility)
        self.sink = sink
    }

    /// Wires the asynchronous readability-handler loop to a pipe.
    func attach(to pipe: Pipe) {
        let handle = pipe.fileHandleForReading

        lock.lock()
        readingHandle = handle
        lock.unlock()

        handle.readabilityHandler = { [weak self] fileHandle in
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty else { return }   // EOF — finish() tears down
            self?.queue.async { self?.consume(chunk) }
        }
    }

    /// Detaches the handler and drains anything still buffered in the pipe.
    /// Always flushes afterwards — Minecraft does not guarantee a trailing
    /// newline, so the last partial line must still reach the console.
    func finish() {
        lock.lock()
        let handle = readingHandle
        readingHandle = nil
        lock.unlock()

        handle?.readabilityHandler = nil
        let remaining = handle?.readDataToEndOfFile() ?? Data()
        queue.async { [weak self] in
            self?.consume(remaining)
            self?.flushPending()
        }
    }

    // MARK: Internals

    private func consume(_ chunk: Data) {
        lock.lock()
        pendingLine.append(chunk)

        while let newline = pendingLine.firstIndex(of: 0x0A) {
            let lineData = pendingLine.subdata(in: pendingLine.startIndex..<newline)
            let remainderStart = pendingLine.index(after: newline)
            pendingLine = pendingLine.subdata(in: remainderStart..<pendingLine.endIndex)
            lock.unlock()
            emit(lineData)
            lock.lock()
        }
        lock.unlock()
    }

    private func flushPending() {
        lock.lock()
        let remainder = pendingLine
        pendingLine = Data()
        lock.unlock()
        emit(remainder)
    }

    private func emit(_ data: Data) {
        guard !data.isEmpty else { return }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? data.map { String(format: "%02x", $0) }.joined()
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        guard !trimmed.isEmpty else { return }
        sink(trimmed)
    }
}

// MARK: - Log terminal model

/// One line in the launcher's built-in terminal.
public struct LogLine: Identifiable {
    public let id: Int
    public let text: String
    public let kind: Kind

    public enum Kind {
        case info      // launcher phase messages
        case out       // game stdout
        case err       // game stderr
        case system    // command summaries, exit statuses
    }
}

// MARK: - Engine

public final class LauncherEngine: ObservableObject {

    // MARK: Published UI state

    @Published public private(set) var installedVersions: [String] = []
    @Published public private(set) var remoteVersions: [RemoteVersion] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var gameRunning = false
    @Published public private(set) var logLines: [LogLine] = []
    @Published public private(set) var javaCandidates: [JavaCandidate] = []
    /// On-disk size (bytes) of each installed version's own files —
    /// `versions/<id>/` only; shared libraries and assets are not included.
    @Published public private(set) var versionFootprints: [String: Int64] = [:]

    /// The picker binding. Persisted across launches via UserDefaults.
    @Published public var selectedVersionID: String = "" {
        didSet {
            guard oldValue != selectedVersionID else { return }
            UserDefaults.standard.set(selectedVersionID, forKey: Self.selectedVersionKey)
            refreshSelectionHint()
        }
    }

    /// Remote catalog entries that are not installed yet. Snapshot display
    /// is user-tunable via the "blocky.showSnapshots" setting.
    public var fetchableVersions: [RemoteVersion] {
        let showSnapshots = (UserDefaults.standard.object(forKey: "blocky.showSnapshots") as? Bool) ?? true
        return remoteVersions.filter { version in
            guard !installedVersions.contains(version.id) else { return false }
            return showSnapshots || version.isRelease
        }
    }

    public var isSelectedVersionInstalled: Bool {
        !selectedVersionID.isEmpty && installedVersions.contains(selectedVersionID)
    }

    // MARK: Constants & paths

    private static let selectedVersionKey = "blocky.selectedVersion"
    private static let remoteCatalogDisplayLimit = 40

    public let minecraftRoot: URL

    var versionsDirectory: URL { minecraftRoot.appendingPathComponent("versions", isDirectory: true) }
    var librariesDirectory: URL { minecraftRoot.appendingPathComponent("libraries", isDirectory: true) }
    public var assetsDirectory: URL { minecraftRoot.appendingPathComponent("assets", isDirectory: true) }
    public var modsDirectory: URL { minecraftRoot.appendingPathComponent("mods", isDirectory: true) }
    public var shaderpacksDirectory: URL { minecraftRoot.appendingPathComponent("shaderpacks", isDirectory: true) }

    public static func defaultMinecraftDirectory() -> URL {
        // Power users may point Blocky at a non-default game directory:
        //   defaults write dev.blocky.Blocky customGameDir "~/mc-test"
        if let custom = UserDefaults.standard.string(forKey: "blocky.customGameDir"),
           !custom.isEmpty,
           custom != minecraftStandardName {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(minecraftStandardName, isDirectory: true)
    }
    private static let minecraftStandardName = "minecraft"

    private let downloader = MojangDownloader()
    private let catalogLock = NSLock()
    private var remoteIndex: [String: RemoteVersion] = [:]
    private var workTask: Task<Void, Never>?
    private var gameProcess: Process?          // main-thread only
    private let processQueue = DispatchQueue(label: "dev.blocky.launcher.process", qos: .utility)
    private var selectionHintActive = false

    public init(minecraftRoot: URL = LauncherEngine.defaultMinecraftDirectory()) {
        self.minecraftRoot = minecraftRoot
        self.selectedVersionID = UserDefaults.standard.string(forKey: Self.selectedVersionKey) ?? ""
        Self.createIfMissing([versionsDirectory, librariesDirectory, assetsDirectory])
    }

    private static func createIfMissing(_ directories: [URL]) {
        for directory in directories {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: Log terminal plumbing

    private static let logLineLimit = 800
    private var logCounter = 0

    /// Appends one line to the built-in terminal. Main thread only.
    private func appendLog(_ text: String, kind: LogLine.Kind) {
        logCounter += 1
        logLines.append(LogLine(id: logCounter, text: text, kind: kind))

        // Batched trim keeps heavy game-log bursts amortized O(1).
        if logLines.count > Self.logLineLimit + 50 {
            logLines.removeFirst(logLines.count - Self.logLineLimit)
        }
    }

    /// Thread-safe entry point for the game's streamers (utility queues).
    private func enqueueLog(_ text: String, kind: LogLine.Kind) {
        DispatchQueue.main.async {
            self.appendLog(text, kind: kind)
        }
    }

    public func clearLog() {
        logLines = []
    }

    /// Snapshot of every discoverable JVM, published for the settings menu.
    /// Probing shells out to `java -version`, so it runs off the main thread.
    public func refreshJavaCandidates() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let candidates = LauncherEngine.detectJavaInstallations()
            await MainActor.run {
                self?.javaCandidates = candidates
            }
        }
    }

    // MARK: Bootstrap & discovery

    public func bootstrap() {
        refreshJavaCandidates()
        Task { [weak self] in
            guard let self else { return }
            await self.reloadInstalledVersions()
            await self.reloadRemoteCatalog()
            self.reconcileSelectionOnMain()
        }
    }

    func reloadInstalledVersions() async {
        let scanned = Self.scanInstalledVersions(in: versionsDirectory)
        let ordered = Self.applyReleaseDateOrdering(
            to: scanned,
            releaseDates: releaseDateIndexSnapshot()
        )
        // Version footprints (own files only) — computed off-main next to the scan.
        let footprints = Self.measureFootprints(for: ordered, in: versionsDirectory)
        await MainActor.run {
            installedVersions = ordered
            versionFootprints = footprints
            reconcileSelectionOnMain()
        }
    }

    /// Recursively sizes each version's own files (jar, json, natives).
    static func measureFootprints(for versionIDs: [String], in versionsDirectory: URL) -> [String: Int64] {
        let fileManager = FileManager.default
        var results: [String: Int64] = [:]

        for versionID in versionIDs {
            var total: Int64 = 0
            let directory = versionsDirectory.appendingPathComponent(versionID, isDirectory: true)
            if let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values?.isRegularFile == true {
                        total += Int64(values?.fileSize ?? 0)
                    }
                }
            }
            let flatJar = versionsDirectory.appendingPathComponent("\(versionID).jar")
            if let size = try? flatJar.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
            results[versionID] = total
        }

        return results
    }

    /// Removes an installed version's own files. Refuses to run while a game
    /// process is alive; reports through the status slot either way.
    @discardableResult
    public func deleteVersion(_ versionID: String) -> Bool {
        guard !gameRunning else {
            errorMessage = "Quit Minecraft before deleting versions."
            return false
        }

        let directory = versionsDirectory.appendingPathComponent(versionID, isDirectory: true)
        let flatJar = versionsDirectory.appendingPathComponent("\(versionID).jar")
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            } else if fileManager.fileExists(atPath: flatJar.path) {
                try fileManager.removeItem(at: flatJar)
            } else {
                return false
            }
        } catch {
            errorMessage = "Couldn't delete \(versionID) — \(error.localizedDescription)"
            return false
        }

        statusMessage = "Deleted \(versionID)"
        Task { [weak self] in
            await self?.reloadInstalledVersions()
        }
        return true
    }

    func reloadRemoteCatalog() async {
        do {
            let catalog = try await downloader.fetchVersionManifest()
            let dates = Dictionary(
                catalog.compactMap { version -> (String, String)? in
                    guard let release = version.releaseTime else { return nil }
                    return (version.id, release)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let index = Dictionary(
                catalog.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            await MainActor.run {
                remoteVersions = Array(catalog.prefix(Self.remoteCatalogDisplayLimit))
                storeRemoteIndex(index)
                installedVersions = Self.applyReleaseDateOrdering(
                    to: installedVersions,
                    releaseDates: dates
                )
                reconcileSelectionOnMain()
            }
        } catch {
            // Offline mode is a feature, not a failure — local versions still work.
            await MainActor.run {
                if remoteVersions.isEmpty {
                    statusMessage = "Mojang catalog unreachable — showing local versions only."
                }
            }
        }
    }

    /// Reads the versions folder, filters hidden system files, and returns
    /// valid version identifiers sorted newest-first.
    static func scanInstalledVersions(in versionsDirectory: URL) -> [String] {
        let fileManager = FileManager.default
        var discovered: [String] = []

        guard let entries = try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        for entry in entries {
            let name = entry.lastPathComponent

            // Hidden system entries (.DS_Store, ._resource forks, …) never
            // contain usable version data.
            guard !name.hasPrefix(".") else { continue }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // Modern layout: versions/<id>/<id>.jar (+ <id>.json)
                let jarURL = entry.appendingPathComponent("\(name).jar")
                let jsonURL = entry.appendingPathComponent("\(name).json")
                let hasPayload = fileManager.fileExists(atPath: jarURL.path)
                    || fileManager.fileExists(atPath: jsonURL.path)
                if hasPayload {
                    discovered.append(name)
                }
            } else if entry.pathExtension.lowercased() == "jar" {
                // Ancient layout: versions/<id>.jar directly in the folder.
                discovered.append((name as NSString).deletingPathExtension)
            }
        }

        return discovered.sorted { descending($0, $1) }
    }

    // MARK: Version ordering

    /// True when `lhs` should be listed before `rhs` (newest first). Release
    /// dates from the manifest win when both are known; otherwise a
    /// historical-era bucket and a natural (numeric-aware) comparison keep
    /// "1.21.4" above "1.7.10" and modern releases above old betas.
    static func descending(_ lhs: String, _ rhs: String, releaseDates: [String: String] = [:]) -> Bool {
        if let leftDate = releaseDates[lhs], let rightDate = releaseDates[rhs], leftDate != rightDate {
            return leftDate > rightDate
        }
        let lhsEra = historicalEra(of: lhs)
        let rhsEra = historicalEra(of: rhs)
        if lhsEra != rhsEra {
            return lhsEra > rhsEra
        }
        return naturalAscending(rhs, lhs)
    }

    /// Rough chronological buckets for ids without manifest dates:
    /// pre-classic (rd*) < alpha (a1*) < beta (b1*) < the release line (1.*)
    /// < snapshot-style ids (e.g. "24w13a"). Custom names ride in the
    /// release-line bucket and natural-sort within it.
    private static func historicalEra(of versionID: String) -> Int {
        let lowered = versionID.lowercased()
        if lowered.hasPrefix("rd") { return 0 }
        if lowered.hasPrefix("a1") { return 1 }
        if lowered.hasPrefix("b1") { return 2 }
        if versionID.split(separator: ".").first == "1" { return 3 }
        if let first = lowered.first, first.isASCII, first.isNumber { return 4 }
        return 3
    }

    static func applyReleaseDateOrdering(to versions: [String], releaseDates: [String: String]) -> [String] {
        guard !releaseDates.isEmpty else { return versions }
        return versions.sorted { descending($0, $1, releaseDates: releaseDates) }
    }

    /// Numeric-aware ordering: splits "1.21.4-rc1" into digit / non-digit runs
    /// and compares digit runs by magnitude, so 1.21 > 1.9 > 1.7.10.
    static func naturalAscending(_ lhs: String, _ rhs: String) -> Bool {
        let lhsTokens = tokenize(lhs)
        let rhsTokens = tokenize(rhs)
        let commonCount = min(lhsTokens.count, rhsTokens.count)

        for index in 0..<commonCount {
            let left = lhsTokens[index]
            let right = rhsTokens[index]
            if left == right { continue }
            if let numericOrder = numericTokenOrder(left, right) {
                return numericOrder
            }
            return left < right
        }

        return lhsTokens.count < rhsTokens.count
    }

    private static func numericTokenOrder(_ lhs: String, _ rhs: String) -> Bool? {
        guard isNumericToken(lhs), isNumericToken(rhs) else { return nil }
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        return lhs < rhs   // equal-length digit strings compare numerically
    }

    private static func isNumericToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previousWasNumeric: Bool?

        for character in value {
            let isNumeric = character.isASCII && character.isNumber
            if let previous = previousWasNumeric, previous != isNumeric, !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            current.append(character)
            previousWasNumeric = isNumeric
        }
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    // MARK: Authentication mocking — the standard offline UUID

    /// Reproduces Minecraft's offline identifier byte-for-byte:
    /// MD5("OfflinePlayer:<username>"), then force UUID version 3 and the
    /// RFC 4122 variant, then render as a canonical 36-character hyphenated
    /// string. Matches Java's `UUID.nameUUIDFromBytes` exactly, e.g.
    /// "Notch" → b50ad385-829d-3141-8216-7e7d7539ba7f.
    static func offlinePlayerUUID(username: String) -> String {
        let digest = Insecure.MD5.hash(data: Data("OfflinePlayer:\(username)".utf8))
        var bytes = Array<UInt8>(digest)

        // byte 6:  high nibble → 0011 (version 3, name-based / MD5)
        bytes[6] = (bytes[6] & 0x0F) | 0x30
        // byte 8:  two high bits → 10 (RFC 4122 variant)
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return formatAsUUID(bytes)
    }

    static func formatAsUUID(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16, "A UUID requires exactly 16 bytes")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20)),
        ].joined(separator: "-")
    }

    // MARK: Classpath compilation

    /// Recursive scan of the libraries folder gathering the absolute path of
    /// every dependency .jar, hidden files excluded.
    static func collectJarsRecursively(in directory: URL) -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            guard url.pathExtension.lowercased() == "jar" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            paths.append(url.path)
        }

        return paths.sorted()
    }

    /// Assembles the complete `-cp` argument: the version's exact resolved
    /// dependencies first (so duplicate artifacts of other versions never
    /// shadow them), then the recursive sweep of every jar in libraries/,
    /// and finally the main game client jar. With an `inheritsFrom` chain
    /// (mod loaders), both the child's and the base version's libraries are
    /// already merged into `package`.
    func buildClasspath(clientJar: URL, package: VersionPackage?) throws -> String {
        let fileManager = FileManager.default
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            guard fileManager.fileExists(atPath: path) else { return }
            guard seen.insert(path).inserted else { return }
            ordered.append(path)
        }

        if let package {
            for request in MojangDownloader.libraryRequests(for: package) {
                append(librariesDirectory.appendingPathComponent(request.path).path)
            }
        }

        for jarPath in Self.collectJarsRecursively(in: librariesDirectory) {
            append(jarPath)
        }

        guard fileManager.fileExists(atPath: clientJar.path) else {
            throw LaunchError.clientJarMissing(clientJar.lastPathComponent)
        }
        append(clientJar.path)

        guard ordered.count > 1 else {
            throw LaunchError.librariesMissing
        }

        return ordered.joined(separator: ":")
    }

    // MARK: Path helpers

    func clientJarURL(for versionID: String) -> URL {
        let nested = versionsDirectory
            .appendingPathComponent(versionID, isDirectory: true)
            .appendingPathComponent("\(versionID).jar")
        if FileManager.default.fileExists(atPath: nested.path) { return nested }

        let flat = versionsDirectory.appendingPathComponent("\(versionID).jar")
        if FileManager.default.fileExists(atPath: flat.path) { return flat }

        return nested
    }

    func versionPackageURL(for versionID: String) -> URL {
        versionsDirectory
            .appendingPathComponent(versionID, isDirectory: true)
            .appendingPathComponent("\(versionID).json")
    }

    func nativesDirectory(for versionID: String) -> URL {
        versionsDirectory
            .appendingPathComponent(versionID, isDirectory: true)
            .appendingPathComponent("natives-\(versionID)", isDirectory: true)
    }

    // MARK: Java detection

    public struct JavaCandidate: Hashable {
        public let binary: URL
        public let major: Int

        /// Short human label: "Temurin 25" from a JDK bundle path.
        public var displayName: String {
            let parent = binary.deletingLastPathComponent()          // …/bin
            let home = parent.deletingLastPathComponent()           // …/Contents/Home or …/openjdk
            let raw = home.deletingLastPathComponent().lastPathComponent
            let styled = raw
                .replacingOccurrences(of: ".jdk", with: "")
                .replacingOccurrences(of: "openjdk", with: "OpenJDK")
            let name = styled.isEmpty ? home.lastPathComponent : styled
            return "\(name) \(major)"
        }
    }

    /// Probes the standard macOS installation sites, in priority order.
    /// The /usr/bin/java stub is deliberately excluded: probing it on a
    /// JVM-less machine triggers Apple's installer dialog, and every JVM it
    /// could reach is already visible via java_home or the glob below.
    static func detectJavaInstallations() -> [JavaCandidate] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var binaries: [URL] = []

        func register(_ path: String) {
            let url = URL(fileURLWithPath: path)
            guard fileManager.isExecutableFile(atPath: url.path) else { return }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            binaries.append(url)
        }

        // 1. The canonical macOS resolver.
        if let home = ShellRunner.run(executablePath: "/usr/libexec/java_home")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            register(home + "/bin/java")
            register(home + "/jre/bin/java")
        }

        // 2. Homebrew openjdk formulas (Apple Silicon + Intel prefixes).
        for base in ["/opt/homebrew/opt", "/usr/local/opt"] {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
            for entry in entries where entry.hasPrefix("openjdk") {
                register("\(base)/\(entry)/bin/java")
                register("\(base)/\(entry)/libexec/openjdk.jdk/Contents/Home/bin/java")
            }
        }

        // 3. System JVMs (Oracle / Temurin / Adoptium casks).
        if let jdks = try? fileManager.contentsOfDirectory(atPath: "/Library/Java/JavaVirtualMachines") {
            for jdk in jdks where !jdk.hasPrefix(".") {
                register("/Library/Java/JavaVirtualMachines/\(jdk)/Contents/Home/bin/java")
            }
        }

        // 4. Explicit JAVA_HOME override.
        if let javaHome = ProcessInfo.processInfo.environment["JAVA_HOME"],
           !javaHome.isEmpty {
            register((javaHome as NSString).expandingTildeInPath + "/bin/java")
        }

        return binaries
            .compactMap { binary -> JavaCandidate? in
                guard let major = probeJavaMajor(at: binary) else { return nil }
                return JavaCandidate(binary: binary, major: major)
            }
            .sorted { $0.major < $1.major }
    }

    static func probeJavaMajor(at binary: URL) -> Int? {
        guard let output = ShellRunner.run(executablePath: binary.path, arguments: ["-version"]) else {
            return nil
        }
        return parseJavaMajor(from: output)
    }

    /// `openjdk version "21.0.1" …` → 21;  `java version "1.8.0_402"` → 8.
    static func parseJavaMajor(from output: String) -> Int? {
        guard let openQuote = output.firstIndex(of: "\""),
              let closeQuote = output[output.index(after: openQuote)...].firstIndex(of: "\"") else {
            return nil
        }
        let versionString = String(output[output.index(after: openQuote)..<closeQuote])
        let components = versionString
            .split(separator: ".")
            .map { Int($0.prefix(while: { $0.isASCII && $0.isNumber })) ?? 0 }
        guard let first = components.first else { return nil }
        if first == 1, components.count > 1 {
            return components[1]     // legacy "1.8" scheme
        }
        return first
    }

    /// Exact match first, then the smallest newer runtime, then the largest
    /// older one as a last resort.
    static func bestJavaCandidate(requiredMajor: Int) throws -> JavaCandidate {
        let candidates = detectJavaInstallations()

        if let exact = candidates.first(where: { $0.major == requiredMajor }) {
            return exact
        }
        if let newer = candidates.first(where: { $0.major > requiredMajor }) {
            return newer
        }
        if let older = candidates.last(where: { $0.major < requiredMajor }) {
            return older
        }
        throw LaunchError.javaNotFound(requiredMajor)
    }

    static func inferredJavaHome(for binary: URL) -> URL {
        let parent = binary.deletingLastPathComponent()
        if parent.lastPathComponent == "bin" {
            return parent.deletingLastPathComponent()
        }
        return parent
    }

    /// Version → required Java major, used when the version JSON carries no
    /// explicit javaVersion block.
    static func heuristicJavaMajor(for versionID: String) -> Int {
        let lowercased = versionID.lowercased()
        guard !lowercased.hasPrefix("b1"),
              !lowercased.hasPrefix("a1"),
              !lowercased.hasPrefix("rd") else {
            return 8   // ancient betas and alphas
        }

        let segments = versionID.split(separator: ".")
        let numbers = segments.map { Int($0.prefix(while: { $0.isASCII && $0.isNumber })) ?? 0 }

        // Year-style release ids ("26.3", "27.0") pair with the previous
        // year's LTS line — 26.3 ships Java 25, 25.1 shipped 21. Snapshot
        // ids ("24w13a") have no dot and stay at the modern baseline.
        if numbers.count >= 2, numbers[0] != 1,
           (24...40).contains(numbers[0]) {
            return max(21, numbers[0] - 1)
        }

        guard numbers.count >= 2, numbers[0] == 1 else {
            return 21  // modern snapshot ids such as "24w13a"
        }

        let minor = numbers[1]
        let patch = numbers.count > 2 ? numbers[2] : 0

        switch (minor, patch) {
        case (20, 5...): return 21     // 1.20.5 and newer
        case (21..., _): return 21
        case (18...20, _): return 17
        case (17, _): return 16
        default: return 8
        }
    }

    public static func recommendedHeapMegabytes(for physicalMemory: UInt64) -> Int {
        let megabyte: UInt64 = 1024 * 1024
        let installedMegabytes = physicalMemory / megabyte

        if installedMegabytes < 4096 {
            return max(1024, Int(installedMegabytes / 4))
        }
        return min(max(2048, Int(installedMegabytes / 4)), 4096)
    }

    /// Versions before 1.7.2 neither accept `--assetIndex` nor tolerate a
    /// missing `--userProperties`; this keeps their arg surface happy.
    static func legacyArgumentAdjustments(for versionID: String) -> (omitsAssetIndex: Bool, includesUserProperties: Bool) {
        let lowercased = versionID.lowercased()
        if lowercased.hasPrefix("b1") || lowercased.hasPrefix("a1") || lowercased.hasPrefix("rd") {
            return (true, true)
        }

        let numbers = versionID
            .split(separator: ".")
            .map { Int($0.prefix(while: { $0.isASCII && $0.isNumber })) ?? 0 }
        guard numbers.count >= 2, numbers[0] == 1 else {
            return (false, false)
        }

        let minor = numbers[1]
        let patch = numbers.count > 2 ? numbers[2] : 0
        let isPre172 = (minor < 7) || (minor == 7 && patch < 2)
        return (isPre172, isPre172)
    }

    // MARK: Validation

    public static func isValidMinecraftUsername(_ username: String) -> Bool {
        guard (1...16).contains(username.count) else { return false }
        return username.allSatisfy { character in
            (character.isLetter && character.isASCII)
                || (character.isNumber && character.isASCII)
                || character == "_"
        }
    }

    // MARK: Launch entry point

    public func requestLaunch(username rawUsername: String) {
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isWorking else { return }

        // Dual-launch protection: exactly one game process at a time.
        guard !gameRunning else {
            errorMessage = nil
            statusMessage = "Minecraft is already running — quit it first."
            appendLog("✕ blocked duplicate launch — a game process is alive", kind: .system)
            return
        }

        guard !username.isEmpty else {
            errorMessage = "Enter a username first."
            return
        }
        guard Self.isValidMinecraftUsername(username) else {
            errorMessage = "Invalid username — use 1–16 letters, numbers, or underscores."
            return
        }
        guard !selectedVersionID.isEmpty else {
            errorMessage = "Select a Minecraft version first."
            return
        }

        errorMessage = nil
        selectionHintActive = false
        statusMessage = "Preparing…"
        isWorking = true

        let versionID = selectedVersionID
        workTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runLaunchSequence(username: username, versionID: versionID)
        }
    }

    public func cancelWork() {
        workTask?.cancel()
    }

    // MARK: Launch sequence

    private func runLaunchSequence(username: String, versionID: String) async {
        do {
            try Task.checkCancellation()

            // ── Phase 1: resolve the version definition (local JSON, else
            // manifest), folding `inheritsFrom` chains for mod loaders.
            let resolved = try await resolvePackage(versionID: versionID)
            progress("Preparing launch files…")

            // ── Phase 2: the client jar — from the ancestor that ships one
            // (fabric-loader profiles inherit vanilla's client jar).
            let clientJar = clientJarURL(for: resolved?.clientVersionID ?? versionID)
            if !FileManager.default.fileExists(atPath: clientJar.path) {
                guard let resolved else { throw LaunchError.versionUnavailable(versionID) }
                try await downloader.installClientJar(
                    package: resolved.package,
                    versionID: resolved.clientVersionID,
                    versionsDirectory: versionsDirectory
                ) { [weak self] label in
                    self?.progress(label)
                }
            }

            try Task.checkCancellation()

            // ── Phase 3: dependencies + assets (idempotent, sha1-gated)
            if let package = resolved?.package {
                try await downloader.ensureLibraries(
                    package: package,
                    librariesDirectory: librariesDirectory
                ) { [weak self] done, total in
                    self?.progress("Fetching libraries — \(done)/\(total)")
                }
                try await downloader.ensureAssets(
                    package: package,
                    minecraftRoot: minecraftRoot
                ) { [weak self] done, total in
                    self?.progress("Fetching assets — \(done)/\(total)")
                }
            }

            try Task.checkCancellation()

            // ── Phase 4: classpath
            progress("Compiling classpath…")
            let classpath = try buildClasspath(clientJar: clientJar, package: resolved?.package)
            print("[Blocky] Classpath entries: \(classpath.components(separatedBy: ":").count)")

            // ── Phase 5: Java runtime
            let requiredMajor = resolved?.package.javaVersion?.majorVersion
                ?? Self.heuristicJavaMajor(for: versionID)
            let java = try resolveJava(requiredMajor: requiredMajor)

            #if arch(arm64)
            // Old natives are x86_64-only; on Apple Silicon they load only
            // through Rosetta 2 + an Intel JVM. Surface that before it
            // surfaces as an UnsatisfiedLinkError.
            if requiredMajor <= 8, resolved?.package.libraries?.isEmpty == false {
                progress("Heads up — pre-1.17 natives are x86_64; if this crashes, install Rosetta 2 and an Intel JDK (brew under /usr/local).")
            }
            #endif

            // ── Phase 6: native libraries
            let natives = extractNatives(
                package: resolved?.package,
                versionID: versionID,
                javaHome: Self.inferredJavaHome(for: java.binary)
            )

            // ── Phase 7: spawn
            try await spawn(
                username: username,
                versionID: versionID,
                java: java,
                classpath: classpath,
                nativesDirectory: natives,
                package: resolved?.package
            )

            complete(status: "Minecraft is running — logs stream to this console.")
            await reloadInstalledVersions()

        } catch is CancellationError {
            complete(status: "Launch cancelled.")
        } catch {
            let message = (error as? LaunchError)?.userFacingMessage ?? error.localizedDescription
            print("[Blocky] Launch failed: \(message)")
            fail(message)
        }
    }

    /// The result of resolving a version definition, including `inheritsFrom`
    /// chains. `clientVersionID` is the ancestor that actually ships the
    /// game client jar (Fabric/Forge profiles inherit it from vanilla).
    private struct ResolvedVersion {
        let package: VersionPackage
        let clientVersionID: String
    }

    /// Resolves a version definition: local JSON first, else the manifest.
    /// Walks `inheritsFrom` chains the way mod loaders (Fabric, Forge,
    /// NeoForge) and the official launcher expect — the child keeps its own
    /// mainClass and libraries, ancestors fill in the client jar, assets,
    /// and Java requirements.
    private func resolvePackage(versionID: String) async throws -> ResolvedVersion? {
        var chain: [VersionPackage] = []
        var visited: Set<String> = []

        var nextID: String? = versionID
        while let currentID = nextID, visited.insert(currentID).inserted, visited.count <= 4 {
            guard let loaded = try await loadRawPackage(versionID: currentID) else { break }
            chain.append(loaded)
            nextID = loaded.inheritsFrom
        }

        guard let child = chain.first else { return nil }

        var merged = child
        for parent in chain.dropFirst() {
            merged = Self.merged(child: merged, parent: parent)
        }

        // The nearest ancestor that ships the client jar provides it — a
        // fabric-loader profile has no client download of its own.
        let clientVersionID = chain.first { $0.downloads?.client != nil }?.id ?? versionID

        return ResolvedVersion(package: merged, clientVersionID: clientVersionID)
    }

    /// Loads one link of the chain, persisting manifest fetches immediately so
    /// interrupted installs resume on the next launch.
    private func loadRawPackage(versionID: String) async throws -> VersionPackage? {
        if let data = try? Data(contentsOf: versionPackageURL(for: versionID)),
           let package = try? MojangDownloader.decodeVersionPackage(data) {
            return package
        }
        if let remote = remoteIndexSnapshot()[versionID] {
            let fetched = try await downloader.fetchVersionPackage(remote)
            try writePackageJSON(fetched.data, versionID: versionID)
            return fetched.package
        }
        return nil
    }

    /// Child-first merge for inheritsFrom chains.
    static func merged(child: VersionPackage, parent: VersionPackage) -> VersionPackage {
        let arguments: VersionPackage.LaunchArguments?
        if let childArguments = child.arguments {
            arguments = VersionPackage.LaunchArguments(
                jvm: childArguments.jvm ?? parent.arguments?.jvm,
                game: childArguments.game ?? parent.arguments?.game
            )
        } else {
            arguments = parent.arguments
        }

        return VersionPackage(
            id: child.id ?? parent.id,
            type: child.type ?? parent.type,
            mainClass: child.mainClass ?? parent.mainClass,
            assets: child.assets ?? parent.assets,
            assetIndex: child.assetIndex ?? parent.assetIndex,
            libraries: (child.libraries ?? []) + (parent.libraries ?? []),
            javaVersion: child.javaVersion ?? parent.javaVersion,
            downloads: child.downloads ?? parent.downloads,
            arguments: arguments,
            inheritsFrom: nil
        )
    }

    private func writePackageJSON(_ data: Data, versionID: String) throws {
        let directory = versionsDirectory.appendingPathComponent(versionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: versionPackageURL(for: versionID), options: .atomic)
    }

    private func resolveJava(requiredMajor: Int) throws -> JavaCandidate {
        // A manual override from Settings always wins when it is usable.
        if let override = manualJavaOverride() {
            print("[Blocky] Java override: \(override.binary.path) (major \(override.major))")
            return override
        }

        let candidate = try Self.bestJavaCandidate(requiredMajor: requiredMajor)
        if candidate.major < requiredMajor {
            progress("Java \(candidate.major) found — this version prefers Java \(requiredMajor); launch may fail.")
        }
        print("[Blocky] Java runtime: \(candidate.binary.path) (major \(candidate.major))")
        return candidate
    }

    /// User-pinned runtime from Settings ("blocky.javaOverridePath").
    private func manualJavaOverride() -> JavaCandidate? {
        guard let path = UserDefaults.standard.string(forKey: "blocky.javaOverridePath"),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let major = Self.probeJavaMajor(at: url) else { return nil }
        return JavaCandidate(binary: url, major: major)
    }

    /// Heap for the game: user override (Settings) or RAM-sized auto default.
    static func heapMegabytes(manualOverrideGB: Int) -> Int {
        guard manualOverrideGB > 0 else {
            return recommendedHeapMegabytes(for: ProcessInfo.processInfo.physicalMemory)
        }
        return manualOverrideGB * 1024
    }

    // MARK: Natives

    private func extractNatives(package: VersionPackage?, versionID: String, javaHome: URL) -> URL? {
        guard let package else { return nil }
        let nativeJars = MojangDownloader.nativeJarPaths(
            for: package,
            librariesDirectory: librariesDirectory
        )
        guard !nativeJars.isEmpty else { return nil }

        let target = nativesDirectory(for: versionID)
        let fileManager = FileManager.default

        do {
            // Fresh extraction every launch — a few MB at most, and it can
            // never accumulate stale binaries from older versions.
            try? fileManager.removeItem(at: target)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

            for jar in nativeJars {
                if !Self.extractArchive(jar, into: target, javaHome: javaHome) {
                    print("[Blocky] Warning: could not extract natives from \(jar.lastPathComponent).")
                }
            }
            try? fileManager.removeItem(at: target.appendingPathComponent("META-INF", isDirectory: true))
            print("[Blocky] Extracted \(nativeJars.count) natives jar(s) into \(target.path)")
            return target
        } catch {
            print("[Blocky] Natives extraction skipped: \(error.localizedDescription)")
            return nil
        }
    }

    /// Extraction chain: unzip → ditto → the JDK's own jar tool.
    static func extractArchive(_ archive: URL, into destination: URL, javaHome: URL) -> Bool {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", archive.path, "-d", destination.path, "-x", "META-INF/*"]
        if ShellRunner.runSilently(unzip) { return true }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, destination.path]
        if ShellRunner.runSilently(ditto) {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent("META-INF", isDirectory: true))
            return true
        }

        let jar = Process()
        jar.executableURL = javaHome.appendingPathComponent("bin/jar", isDirectory: false)
        jar.arguments = ["xf", archive.path]
        jar.currentDirectoryURL = destination
        if ShellRunner.runSilently(jar) {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent("META-INF", isDirectory: true))
            return true
        }

        return false
    }

    // MARK: Process execution

    private func spawn(
        username: String,
        versionID: String,
        java: JavaCandidate,
        classpath: String,
        nativesDirectory: URL?,
        package: VersionPackage?
    ) async throws {
        let fileManager = FileManager.default

        let playerUUID = Self.offlinePlayerUUID(username: username)
        let mainClass = package?.mainClass ?? "net.minecraft.client.main.Main"
        let assetIndexName = package?.assetIndex?.id ?? package?.assets ?? "legacy"
        let legacyFlags = Self.legacyArgumentAdjustments(for: versionID)

        // Legacy asset layouts live in a virtual mirror of the object store.
        var effectiveAssetsDirectory = assetsDirectory
        if ["legacy", "pre-1.6"].contains(assetIndexName) {
            let virtualMirror = assetsDirectory
                .appendingPathComponent("virtual", isDirectory: true)
                .appendingPathComponent(assetIndexName, isDirectory: true)
            if fileManager.fileExists(atPath: virtualMirror.path) {
                effectiveAssetsDirectory = virtualMirror
            }
        }

        let heapMegabytes = Self.heapMegabytes(
            manualOverrideGB: UserDefaults.standard.integer(forKey: "blocky.ramOverrideGB")
        )

        // Future-proofing: every OS-relevant JVM flag the version manifest
        // declares rides along automatically (26.x sends
        // `-XstartOnFirstThread`, `--enable-native-access`, `--add-exports`,
        // `-XX:StackShadowPages=32` this way — whatever 27.x+ needs next).
        let manifestFlags = package.map { MojangDownloader.jvmFlags(in: $0) } ?? []

        var arguments: [String] = [
            // THE macOS flag: SDL (26.x) and GLFW (≤25.x) both require their
            // Cocoa backend to run on thread 0. Without this the JVM parks
            // itself on a pthread and the game dies with "Unable to
            // initialize SDL: No available video device" → System.exit(-1)
            // → shell status 255. Every official launcher on macOS sends it.
            "-XstartOnFirstThread",
            "-Xms512M",
            "-Xmx\(heapMegabytes)M",
            "-XX:+UseG1GC",
            "-XX:-UseAdaptiveSizePolicy",
            "-Dlog4j2.formatMsgNoLookups=true",   // Log4Shell hard-stop (1.7–1.18)
            "-Xdock:name=Minecraft",              // keep the Dock honest
            "-Dminecraft.launcher.brand=blocky",
            "-Dminecraft.launcher.version=1.0.0",
        ]

        for flag in manifestFlags where !arguments.contains(flag) {
            arguments.append(flag)
        }

        // Fallback for modern-era installs with no manifest at all — same
        // flags the 26.x manifests declare. Java 8 rejects unrecognized `--`
        // options outright, so gate on the JVM we actually picked.
        if manifestFlags.isEmpty && java.major >= 16 {
            arguments.append(contentsOf: [
                "--enable-native-access=ALL-UNNAMED",   // LWJGL/JNA/SDL do raw FFI
                "--add-exports", "java.base/jdk.internal.misc=ALL-UNNAMED",
                "-XX:StackShadowPages=32",              // guard pages for native GL callbacks
            ])
        }

        if let nativesDirectory {
            arguments.append("-Djava.library.path=\(nativesDirectory.path)")
        }
        arguments.append(contentsOf: ["-cp", classpath, mainClass])

        arguments.append(contentsOf: [
            "--username", username,
            "--version", versionID,
            "--gameDir", minecraftRoot.path,
            "--assetsDir", effectiveAssetsDirectory.path,
        ])
        if !legacyFlags.omitsAssetIndex {
            arguments.append(contentsOf: ["--assetIndex", assetIndexName])
        }
        arguments.append(contentsOf: [
            "--uuid", playerUUID,
            "--accessToken", "0",          // explicit null token → offline session
            "--userType", "legacy",
            "--versionType", package?.type ?? "release",
        ])
        if legacyFlags.includesUserProperties {
            arguments.append(contentsOf: ["--userProperties", "{}"])
        }

        print("[Blocky] ▸ \(java.binary.path) \(arguments.joined(separator: " "))")
        appendLog(
            "▸ java \(java.major) · heap \(heapMegabytes) MB · classpath \(classpath.components(separatedBy: ":").count) jars · main \(mainClass)",
            kind: .system
        )

        let process = Process()
        process.executableURL = java.binary
        process.arguments = arguments
        process.currentDirectoryURL = minecraftRoot
        process.qualityOfService = .userInitiated

        // Latency knob: MoltenVK's IMMEDIATE present mode — no vsync at the
        // Vulkan translation layer. The game's own VSync-off should request
        // it, but this makes it certain (raw value 0 = IMMEDIATE).
        var environment = ProcessInfo.processInfo.environment
        environment["MVK_CONFIG_PRESENT_MODE"] = "0"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Scheduled on a background utility queue — the UI never blocks.
        try processQueue.sync { try process.run() }

        let stdoutStreamer = LogStreamer(label: "stdout") { [weak self] line in
            print("[minecraft] \(line)")
            self?.enqueueLog(line, kind: .out)
        }
        let stderrStreamer = LogStreamer(label: "stderr") { [weak self] line in
            print("[minecraft:err] \(line)")
            self?.enqueueLog(line, kind: .err)
        }
        stdoutStreamer.attach(to: stdoutPipe)
        stderrStreamer.attach(to: stderrPipe)

        DispatchQueue.main.async {
            self.gameProcess = process
            self.gameRunning = true
        }

        // Reaper: waits on a utility queue, finalizes the streamers, then
        // reports the exit status back to the UI.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            process.waitUntilExit()
            stdoutStreamer.finish()
            stderrStreamer.finish()
            let status = process.terminationStatus

            DispatchQueue.main.async {
                guard let self, self.gameProcess === process else { return }
                self.gameProcess = nil
                self.gameRunning = false

                if status != 0 {
                    self.errorMessage = "Minecraft exited with status \(status) — see the terminal."
                    self.statusMessage = nil
                    self.appendLog("✕ game exited with status \(status)", kind: .system)
                } else if self.errorMessage == nil {
                    self.statusMessage = "Minecraft quit normally."
                    self.appendLog("✓ game quit normally", kind: .system)
                }
            }
        }
    }

    // MARK: Remote catalog index (thread-safe)

    private func remoteIndexSnapshot() -> [String: RemoteVersion] {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        return remoteIndex
    }

    private func storeRemoteIndex(_ index: [String: RemoteVersion]) {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        remoteIndex = index
    }

    private func releaseDateIndexSnapshot() -> [String: String] {
        remoteIndexSnapshot().compactMapValues { $0.releaseTime }
    }

    // MARK: Selection bookkeeping (main thread)

    private func reconcileSelectionOnMain() {
        let installed = installedVersions
        let remote = remoteVersions
        let current = selectedVersionID

        if current.isEmpty {
            selectedVersionID = installed.first ?? remote.first?.id ?? ""
            return
        }

        let stillValid = installed.contains(current) || remote.contains { $0.id == current }
        if !stillValid {
            selectedVersionID = installed.first ?? remote.first?.id ?? ""
        }
    }

    private func refreshSelectionHint() {
        guard !isWorking, errorMessage == nil else { return }
        if !selectedVersionID.isEmpty, !installedVersions.contains(selectedVersionID) {
            statusMessage = "“\(selectedVersionID)” isn't installed — it will be fetched on launch."
            selectionHintActive = true
        } else if selectionHintActive {
            statusMessage = nil
            selectionHintActive = false
        }
    }

    // MARK: UI state plumbing

    /// Mid-sequence status update — always funneled onto the main thread.
    private func progress(_ text: String) {
        DispatchQueue.main.async {
            self.statusMessage = text
            self.appendLog(text, kind: .info)
        }
    }

    private func complete(status: String?) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusMessage = status
            if let status { self.appendLog(status, kind: .info) }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusMessage = nil
            self.errorMessage = message
            self.appendLog("✕ \(message)", kind: .err)
        }
    }
}
