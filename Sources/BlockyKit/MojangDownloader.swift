//
//  MojangDownloader.swift
//  Blocky
//
//  PART 3 — Dynamic Asset & Client Downloader (Network Engine).
//
//  When a requested version is not present on disk (or is missing libraries /
//  assets), this engine talks to Mojang's public manifest servers, resolves
//  the exact download manifest for that version, and pulls every required
//  artifact into the canonical on-disk layout:
//
//      ~/Library/Application Support/minecraft/
//      ├── versions/<id>/<id>.jar           (the game client)
//      ├── versions/<id>/<id>.json          (version definition)
//      ├── libraries/<group>/<artifact>/…    (every dependency jar)
//      └── assets/indexes + assets/objects  (+ virtual / resources mirrors)
//
//  All transfers are HTTPS, sha1-verified, written atomically, and run on a
//  bounded concurrency queue so a 1200-file asset sweep saturates the network
//  without spawning 1200 sockets.
//

import Foundation
import CryptoKit

// MARK: - Catalog model

/// One entry of Mojang's master version manifest.
public struct RemoteVersion: Identifiable, Hashable {
    public let id: String
    public let type: String                 // "release", "snapshot", "old_beta", "old_alpha"
    public let packageURL: URL
    public let releaseTime: String?         // ISO-8601, sorts lexicographically

    public var isRelease: Bool { type == "release" }
}

// MARK: - Wire format models

private struct Manifest: Decodable {
    let versions: [Entry]

    struct Entry: Decodable {
        let id: String
        let type: String
        let url: String
        let releaseTime: String?
    }
}

/// The subset of Mojang's per-version JSON that a launcher needs.
struct VersionPackage: Decodable {
    let id: String?
    let type: String?
    let mainClass: String?
    let assets: String?
    let assetIndex: AssetIndexReference?
    let libraries: [LibraryReference]?
    let javaVersion: JavaVersionReference?
    let downloads: ClientDownloads?
    let arguments: LaunchArguments?
    let inheritsFrom: String?   // mod loaders chain into a base version

    struct AssetIndexReference: Decodable {
        let id: String
        let sha1: String?
        let size: Int?
        let totalSize: Int?
        let url: String
    }

    struct JavaVersionReference: Decodable {
        let component: String?
        let majorVersion: Int
    }

    struct ClientDownloads: Decodable {
        let client: Artifact?
    }

    struct Artifact: Decodable {
        let sha1: String?
        let size: Int?
        let path: String?
        let url: String
    }

    struct LibraryReference: Decodable {
        let name: String?               // "group:artifact:version[:classifier][:ext]"
        let url: String?                // legacy base URL (2013-era manifests)
        let downloads: Downloads?
        let natives: [String: String]?  // e.g. { "osx": "natives-osx" }
        let rules: [Rule]?

        struct Downloads: Decodable {
            let artifact: Artifact?
            let classifiers: [String: Artifact]?
        }

        struct Rule: Decodable {
            let action: String           // "allow" | "deny"
            let os: OperatingSystem?

            struct OperatingSystem: Decodable {
                let name: String?
                let arch: String?
            }
        }
    }

    /// Mojang's argument lists (`arguments.jvm` / `arguments.game`): each
    /// element is either a bare string or a rule-guarded value.
    struct LaunchArguments: Decodable {
        let jvm: [VersionArgument]?
        let game: [VersionArgument]?
    }

    enum VersionArgument: Decodable {
        case literal(String)
        case guarded(rules: [LibraryReference.Rule], values: [String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let literal = try? container.decode(String.self) {
                self = .literal(literal)
                return
            }

            struct Coded: Decodable {
                let rules: [VersionPackage.LibraryReference.Rule]?
                let value: ValueUnion

                enum ValueUnion: Decodable {
                    case one(String)
                    case many([String])

                    init(from decoder: Decoder) throws {
                        let valueContainer = try decoder.singleValueContainer()
                        if let single = try? valueContainer.decode(String.self) {
                            self = .one(single)
                            return
                        }
                        self = .many(try valueContainer.decode([String].self))
                    }
                }
            }

            let coded = try container.decode(Coded.self)
            switch coded.value {
            case .one(let single):
                self = .guarded(rules: coded.rules ?? [], values: [single])
            case .many(let many):
                self = .guarded(rules: coded.rules ?? [], values: many)
            }
        }
    }
}

/// An asset index document ("1.21", "legacy", …).
struct AssetIndex: Decodable {
    let objects: [String: Object]
    let virtual: Bool?
    let mapToResources: Bool?

    struct Object: Decodable {
        let hash: String
        let size: Int
    }

    enum CodingKeys: String, CodingKey {
        case objects
        case virtual
        case mapToResources = "map_to_resources"
    }
}

// MARK: - Download unit

/// A single resolved file transfer: where it goes and where it comes from.
struct LibraryRequest: Hashable {
    let path: String        // maven-relative path under libraries/
    let url: String          // absolute https URL
    let sha1: String?
    let size: Int?
    let label: String        // human readable name for diagnostics
}

// MARK: - Concurrency helpers

/// Bounds how many transfers execute in parallel inside a TaskGroup.
/// Slots pass directly from a releasing task to the next waiter.
actor AsyncConcurrencyGate {
    private var availableSlots: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        availableSlots = max(1, capacity)
    }

    func acquire() async {
        if availableSlots > 0 {
            availableSlots -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            availableSlots += 1
        }
    }
}

/// Thread-safe progress counter for parallel download phases.
final class ProgressCounter {
    private let lock = NSLock()
    private var count = 0
    let total: Int

    init(total: Int) {
        self.total = total
    }

    func increment() -> Int {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        return current
    }
}

// MARK: - Downloader

final class MojangDownloader {

    // piston-meta is the current production endpoint; launchermeta stays as a
    // fallback because it still serves identical documents.
    static let manifestEndpoints = [
        "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json",
        "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json",
    ]
    static let defaultLibraryBase = "https://libraries.minecraft.net/"
    static let resourceBase = "https://resources.download.minecraft.net/"

    static let decoder = JSONDecoder()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: Manifest & package retrieval

    /// Fetches the master manifest — every release and snapshot Mojang publishes.
    func fetchVersionManifest() async throws -> [RemoteVersion] {
        var lastError: Error = LaunchError.downloadFailed("Mojang manifest unreachable")

        for endpoint in Self.manifestEndpoints {
            do {
                guard let url = URL(string: endpoint) else { continue }
                let (data, response) = try await session.data(from: url)
                try Self.validateHTTP(response)
                let decoded = try Self.decoder.decode(Manifest.self, from: data)
                return decoded.versions
                    .compactMap { entry -> RemoteVersion? in
                        guard let packageURL = URL(string: entry.url) else { return nil }
                        return RemoteVersion(
                            id: entry.id,
                            type: entry.type,
                            packageURL: packageURL,
                            releaseTime: entry.releaseTime
                        )
                    }
                    .sorted { ($0.releaseTime ?? "") > ($1.releaseTime ?? "") }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    /// Downloads and parses an individual version's data sheet.
    func fetchVersionPackage(_ remote: RemoteVersion) async throws -> (data: Data, package: VersionPackage) {
        let (data, response) = try await session.data(from: remote.packageURL)
        try Self.validateHTTP(response)
        let package = try Self.decodeVersionPackage(data)
        return (data, package)
    }

    static func decodeVersionPackage(_ data: Data) throws -> VersionPackage {
        try decoder.decode(VersionPackage.self, from: data)
    }

    // MARK: Client jar

    func installClientJar(
        package: VersionPackage,
        versionID: String,
        versionsDirectory: URL,
        progress: @escaping (String) -> Void
    ) async throws {
        guard let client = package.downloads?.client, let url = URL(string: client.url) else {
            throw LaunchError.versionUnavailable(versionID)
        }

        let directory = versionsDirectory.appendingPathComponent(versionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(versionID).jar")

        if Self.fileIsIntact(at: destination, size: client.size) { return }

        let humanSize = ByteCountFormatter.string(fromByteCount: Int64(client.size ?? 0), countStyle: .file)
        progress("Downloading \(versionID) client (\(humanSize))…")

        let temporary = try await downloadToTemporaryFile(url: url, label: "\(versionID) client jar")
        if let expected = client.sha1 {
            guard try Self.sha1(ofFile: temporary) == expected else {
                try? FileManager.default.removeItem(at: temporary)
                throw LaunchError.checksumMismatch("\(versionID) client jar")
            }
        }
        try Self.install(temporary, at: destination)
    }

    // MARK: Libraries

    /// Ensures every rule-allowed dependency jar of the version exists under
    /// libraries/ — including the macOS natives classifiers. Files that are
    /// already intact are skipped, so re-launching is cheap and idempotent.
    func ensureLibraries(
        package: VersionPackage,
        librariesDirectory: URL,
        progress: @escaping (Int, Int) -> Void
    ) async throws {
        let requests = Self.libraryRequests(for: package)
        guard !requests.isEmpty else { return }

        let gate = AsyncConcurrencyGate(capacity: 8)
        let counter = ProgressCounter(total: requests.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask { [gate, counter] in
                    await gate.acquire()
                    do {
                        try await self.transferLibrary(
                            request,
                            librariesDirectory: librariesDirectory,
                            counter: counter,
                            progress: progress
                        )
                    } catch {
                        await gate.release()
                        throw error
                    }
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }
    }

    /// Downloads (and sha1-verifies) a single library jar into its maven home.
    private func transferLibrary(
        _ request: LibraryRequest,
        librariesDirectory: URL,
        counter: ProgressCounter,
        progress: @escaping (Int, Int) -> Void
    ) async throws {
        try Task.checkCancellation()

        let destination = librariesDirectory.appendingPathComponent(request.path)
        if Self.fileIsIntact(at: destination, size: request.size) {
            progress(counter.increment(), counter.total)
            return
        }

        guard let url = URL(string: request.url) else {
            print("[Blocky] Skipping library with malformed URL: \(request.label)")
            return
        }

        let temporary = try await downloadToTemporaryFile(url: url, label: request.label)
        if let expected = request.sha1 {
            guard try Self.sha1(ofFile: temporary) == expected else {
                try? FileManager.default.removeItem(at: temporary)
                throw LaunchError.checksumMismatch(request.label)
            }
        }
        try Self.install(temporary, at: destination)
        print("[Blocky] Library fetched: \(request.path)")
        progress(counter.increment(), counter.total)
    }

    // MARK: Assets

    /// Ensures the asset index and every object it references is present under
    /// assets/, mirroring to virtual/ or resources/ for legacy versions.
    func ensureAssets(
        package: VersionPackage,
        minecraftRoot: URL,
        progress: @escaping (Int, Int) -> Void
    ) async throws {
        guard let reference = package.assetIndex,
              let indexURL = URL(string: reference.url) else { return }

        let assetsDirectory = minecraftRoot.appendingPathComponent("assets", isDirectory: true)
        let indexesDirectory = assetsDirectory.appendingPathComponent("indexes", isDirectory: true)
        let objectsDirectory = assetsDirectory.appendingPathComponent("objects", isDirectory: true)
        let indexFile = indexesDirectory.appendingPathComponent("\(reference.id).json")

        // 1. Obtain (or reuse) the asset index document itself.
        var indexData: Data
        if let cached = try? Data(contentsOf: indexFile),
           reference.sha1 == nil || Self.sha1(ofData: cached) == reference.sha1 {
            indexData = cached
        } else {
            indexData = try await downloadData(from: indexURL, label: "\(reference.id) asset index")
            if let expected = reference.sha1 {
                guard Self.sha1(ofData: indexData) == expected else {
                    throw LaunchError.checksumMismatch("\(reference.id) asset index")
                }
            }
            try FileManager.default.createDirectory(at: indexesDirectory, withIntermediateDirectories: true)
            try indexData.write(to: indexFile, options: .atomic)
        }

        let index = try Self.decoder.decode(AssetIndex.self, from: indexData)

        // Many keys map to the same content hash — dedupe the transfer list.
        let uniqueObjects = Dictionary(
            index.objects.map { ($0.value.hash, $0.value.size) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !uniqueObjects.isEmpty else { return }

        let gate = AsyncConcurrencyGate(capacity: 12)
        let counter = ProgressCounter(total: uniqueObjects.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (hash, size) in uniqueObjects {
                group.addTask { [gate, counter] in
                    await gate.acquire()
                    do {
                        try await self.transferAsset(
                            hash: hash,
                            size: size,
                            objectsDirectory: objectsDirectory,
                            counter: counter,
                            progress: progress
                        )
                    } catch {
                        await gate.release()
                        throw error
                    }
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }

        // Legacy layouts expect a human-readable mirror of the object store.
        if index.virtual == true {
            let mirror = assetsDirectory
                .appendingPathComponent("virtual", isDirectory: true)
                .appendingPathComponent(reference.id, isDirectory: true)
            try Self.mirrorAssets(index, from: objectsDirectory, to: mirror)
        }
        if index.mapToResources == true {
            try Self.mirrorAssets(
                index,
                from: objectsDirectory,
                to: minecraftRoot.appendingPathComponent("resources", isDirectory: true)
            )
        }
    }

    /// Downloads (and sha1-verifies) a single content-addressed asset object.
    /// Asset names are their own sha1, so a size match is enough to trust an
    /// object that is already on disk.
    private func transferAsset(
        hash: String,
        size: Int,
        objectsDirectory: URL,
        counter: ProgressCounter,
        progress: @escaping (Int, Int) -> Void
    ) async throws {
        try Task.checkCancellation()

        let prefix = String(hash.prefix(2))
        let destination = objectsDirectory
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(hash)

        if Self.fileIsIntact(at: destination, size: size) {
            progress(counter.increment(), counter.total)
            return
        }

        guard let source = URL(string: Self.resourceBase + prefix + "/" + hash) else { return }
        let temporary = try await downloadToTemporaryFile(url: source, label: "asset \(hash)")
        guard try Self.sha1(ofFile: temporary) == hash else {
            try? FileManager.default.removeItem(at: temporary)
            throw LaunchError.checksumMismatch("asset \(hash)")
        }
        try Self.install(temporary, at: destination)
        progress(counter.increment(), counter.total)
    }

    /// Extracts the OS-relevant, launcher-independent JVM flags declared by a
    /// version's manifest (`arguments.jvm`). This is the future-proofing
    /// channel: any new flag Mojang ships for a new SDL/GL/Vulkan backend
    /// flows through automatically, no launcher update required.
    ///
    /// Dropped on purpose: `-cp` (Blocky builds its own classpath) and every
    /// `${template}` value (`${classpath}`, `${natives_directory}` …) whose
    /// expansion is Blocky's own job or whose directories the game fills at
    /// runtime from the classpath.
    static func jvmFlags(in package: VersionPackage) -> [String] {
        guard let jvmArguments = package.arguments?.jvm else { return [] }

        var flags: [String] = []
        func collect(_ values: [String]) {
            for value in values where value != "-cp" {
                flags.append(value)
            }
        }

        for argument in jvmArguments {
            switch argument {
            case .literal(let literal):
                collect([literal])
            case .guarded(let rules, let values):
                guard rulesAllow(rules) else { continue }
                collect(values)
            }
        }

        return flags.filter { !$0.contains("${") }
    }

    // MARK: Resolution helpers

    /// The full transfer list for a version's libraries, with OS rules applied.
    /// Used both by the downloader and by the classpath compiler.
    static func libraryRequests(for package: VersionPackage) -> [LibraryRequest] {
        var requests: [LibraryRequest] = []
        var seenPaths = Set<String>()

        func append(_ request: LibraryRequest) {
            guard seenPaths.insert(request.path).inserted else { return }
            requests.append(request)
        }

        for library in package.libraries ?? [] {
            guard rulesAllow(library.rules) else { continue }

            // Modern format: an explicit artifact descriptor with url + sha1.
            if let artifact = library.downloads?.artifact, !artifact.url.isEmpty {
                let path = artifact.path
                    ?? mavenPath(for: library.name ?? "")
                    ?? String(artifact.url.split(separator: "/").last ?? "artifact.jar")
                append(LibraryRequest(
                    path: path,
                    url: artifact.url,
                    sha1: artifact.sha1,
                    size: artifact.size,
                    label: library.name ?? path
                ))
            }

            // macOS natives — resolved through the classifiers map when present.
            if let classifier = library.natives?["osx"] ?? library.natives?["macos"] {
                if let classified = library.downloads?.classifiers?[classifier], !classified.url.isEmpty {
                    let path = classified.path
                        ?? mavenPath(for: library.name ?? "", classifier: classifier)
                        ?? "\(classifier).jar"
                    append(LibraryRequest(
                        path: path,
                        url: classified.url,
                        sha1: classified.sha1,
                        size: classified.size,
                        label: "\(library.name ?? path):\(classifier)"
                    ))
                } else if let name = library.name,
                          let derived = mavenPath(for: name, classifier: classifier) {
                    let base = library.url ?? defaultLibraryBase
                    append(LibraryRequest(
                        path: derived,
                        url: base + derived,
                        sha1: nil,
                        size: nil,
                        label: "\(name):\(classifier)"
                    ))
                }
            }

            // Ancient format (2013): only a maven name and maybe a base URL.
            if library.downloads == nil, let name = library.name, let path = mavenPath(for: name) {
                let base = library.url ?? defaultLibraryBase
                guard !base.isEmpty else { continue }
                append(LibraryRequest(path: path, url: base + path, sha1: nil, size: nil, label: name))
            }
        }

        return requests
    }

    /// Absolute paths of the natives jars this version needs on macOS.
    /// Only jars that actually exist on disk are returned.
    static func nativeJarPaths(for package: VersionPackage, librariesDirectory: URL) -> [URL] {
        var paths: [URL] = []
        var seen = Set<String>()

        for library in package.libraries ?? [] {
            guard rulesAllow(library.rules) else { continue }
            guard let classifier = library.natives?["osx"] ?? library.natives?["macos"] else { continue }

            let relative: String?
            if let artifact = library.downloads?.classifiers?[classifier] {
                relative = artifact.path ?? mavenPath(for: library.name ?? "", classifier: classifier)
            } else {
                relative = library.name.flatMap { mavenPath(for: $0, classifier: classifier) }
            }

            guard let relative, !seen.contains(relative) else { continue }
            let absolute = librariesDirectory.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: absolute.path) else { continue }

            seen.insert(relative)
            paths.append(absolute)
        }

        return paths
    }

    /// Evaluates a library's rules for this machine. No rules means include;
    /// otherwise the last matching rule decides, exactly like the official
    /// launcher's rule engine.
    static func rulesAllow(_ rules: [VersionPackage.LibraryReference.Rule]?) -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules where Self.ruleMatchesOS(rule.os) {
            allowed = (rule.action == "allow")
        }
        return allowed
    }

    private static func ruleMatchesOS(_ os: VersionPackage.LibraryReference.Rule.OperatingSystem?) -> Bool {
        guard let os else { return true }   // rule without an os matcher applies universally
        if let name = os.name {
            switch name {
            case "osx", "macos", "mac":
                break                       // this launcher runs on macOS
            default:
                return false
            }
        }
        // Mojang only tags "x86" for legacy natives; those dylibs still load
        // under Rosetta on Apple Silicon, so arch never disqualifies a rule.
        return true
    }

    /// "org.lwjgl.lwjgl:lwjgl-platform:2.9.1:natives-osx" →
    /// "org/lwjgl/lwjgl/lwjgl-platform/2.9.1/lwjgl-platform-2.9.1-natives-osx.jar"
    static func mavenPath(for name: String, classifier: String? = nil) -> String? {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }

        let groupPath = parts[0].replacingOccurrences(of: ".", with: "/")
        let artifact = parts[1]
        let version = parts[2]

        let classifierSuffix: String
        if parts.count >= 4, !parts[3].isEmpty {
            classifierSuffix = "-" + parts[3]
        } else if let classifier, !classifier.isEmpty {
            classifierSuffix = "-" + classifier
        } else {
            classifierSuffix = ""
        }
        let fileExtension = (parts.count >= 5 && !parts[4].isEmpty) ? parts[4] : "jar"

        return "\(groupPath)/\(artifact)/\(version)/\(artifact)-\(version)\(classifierSuffix).\(fileExtension)"
    }

    // MARK: Transfer primitives

    private func downloadData(from url: URL, label: String) async throws -> Data {
        let temporary = try await downloadToTemporaryFile(url: url, label: label)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try Data(contentsOf: temporary)
    }

    /// Downloads to a temporary file with bounded retries. The returned URL is
    /// moved (or replaced) into its final home by `install(_:at:)`.
    private func downloadToTemporaryFile(url: URL, label: String) async throws -> URL {
        var lastError: Error?

        for attempt in 1...3 {
            do {
                try Task.checkCancellation()
                let (temporary, response) = try await session.download(from: url)
                try Self.validateHTTP(response)
                return temporary
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }
            }
        }

        throw LaunchError.downloadFailed("\(label): \(lastError?.localizedDescription ?? "network error")")
    }

    /// Atomically moves a finished download into place.
    private static func install(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func mirrorAssets(_ index: AssetIndex, from objectsDirectory: URL, to destinationRoot: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        for (key, object) in index.objects {
            let source = objectsDirectory
                .appendingPathComponent(String(object.hash.prefix(2)), isDirectory: true)
                .appendingPathComponent(object.hash)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let destination = destinationRoot.appendingPathComponent(key, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    // MARK: Integrity

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw LaunchError.downloadFailed("HTTP \(http.statusCode)")
        }
    }

    /// Cheap on-disk validation: existence + expected size. Post-download
    /// transfers additionally verify sha1 before this ever gets called.
    static func fileIsIntact(at fileURL: URL, size: Int?) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }

        if let size {
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let actual = attributes[.size] as? NSNumber,
                  actual.intValue == size else { return false }
        }
        return true
    }

    static func sha1(ofData data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1(ofFile fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
