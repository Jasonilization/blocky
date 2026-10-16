import Foundation
import Testing
@testable import BlockyKit

// MARK: - Helpers

/// Thread-safe line collector for the log-streaming test.
final class LineBox {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

func makeTempDirectory(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("blocky-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func waitFor(
    timeout seconds: Double,
    _ condition: @escaping () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(40))
    }
}

// MARK: - Offline identity

struct OfflineIdentityTests {

    @Test func notchMatchesJavaNameUUIDFromBytes() {
        // MD5("OfflinePlayer:Notch") = b50ad385829da141a2167e7d7539ba7f;
        // byte 6 → 0x31 (version 3), byte 8 = 0xa2 keeps its 10xx variant
        // pattern — the Java expression is idempotent for this input.
        #expect(LauncherEngine.offlinePlayerUUID(username: "Notch")
                == "b50ad385-829d-3141-a216-7e7d7539ba7f")
    }

    @Test func secondSampleMatchesJavaNameUUIDFromBytes() {
        #expect(LauncherEngine.offlinePlayerUUID(username: "Velo_Player1")
                == "a1c17221-396d-3e8b-a441-4db0c7267194")
    }

    @Test func canonicalFormatting() {
        let uuid = LauncherEngine.offlinePlayerUUID(username: "Player1")
        #expect(uuid.count == 36)
        #expect(uuid.filter { $0 == "-" }.count == 4)
        let groups = uuid.split(separator: "-")
        #expect(groups[2].hasPrefix("3"))                      // version nibble
        #expect(["8", "9", "a", "b"].contains(String(groups[3].prefix(1))))  // variant
        #expect(LauncherEngine.formatAsUUID([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
                == "00010203-0405-0607-0809-0a0b0c0d0e0f")
    }
}

// MARK: - Version ordering & discovery

struct VersionOrderingTests {

    @Test func naturalOrdering() {
        #expect(LauncherEngine.naturalAscending("1.9.4", "1.21.4"))
        #expect(LauncherEngine.naturalAscending("1.7", "1.7.10"))
        #expect(LauncherEngine.descending("1.21.4", "1.9.4"))
    }

    @Test func eraBucketsKeepBetasBelowModernReleases() {
        #expect(LauncherEngine.descending("1.21.4", "b1.7.3"))
        #expect(LauncherEngine.descending("b1.7.3", "a1.2.6"))
        #expect(LauncherEngine.descending("a1.2.6", "rd-132211"))
    }

    @Test func releaseDatesDriveOrdering() {
        let ordered = LauncherEngine.applyReleaseDateOrdering(
            to: ["1.12.2", "1.21.4", "1.16.5", "custom-build"],
            releaseDates: ["1.12.2": "2017-09-18", "1.21.4": "2024-12-04", "1.16.5": "2021-01-15"]
        )
        let datedPositions = ["1.21.4", "1.16.5", "1.12.2"].compactMap { ordered.firstIndex(of: $0) }
        #expect(datedPositions.count == 3)
        #expect(datedPositions == datedPositions.sorted())
    }

    @Test func scanFiltersHiddenAndSortsDescending() throws {
        let fm = FileManager.default
        let versionsDir = makeTempDirectory("scan").appendingPathComponent("versions", isDirectory: true)
        try fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        try fm.createDirectory(
            at: versionsDir.appendingPathComponent("1.21.4", isDirectory: true),
            withIntermediateDirectories: true)
        fm.createFile(atPath: versionsDir.appendingPathComponent("1.21.4/1.21.4.jar").path, contents: Data([0]))

        try fm.createDirectory(
            at: versionsDir.appendingPathComponent("1.12.2", isDirectory: true),
            withIntermediateDirectories: true)
        fm.createFile(atPath: versionsDir.appendingPathComponent("1.12.2/1.12.2.json").path, contents: Data([0]))

        fm.createFile(atPath: versionsDir.appendingPathComponent("b1.7.3.jar").path, contents: Data([0]))
        fm.createFile(atPath: versionsDir.appendingPathComponent(".DS_Store").path, contents: Data([0]))
        fm.createFile(atPath: versionsDir.appendingPathComponent("README.txt").path, contents: Data([0]))

        let scanned = LauncherEngine.scanInstalledVersions(in: versionsDir)
        #expect(scanned.count == 3)
        #expect(!scanned.contains(".DS_Store") && !scanned.contains("README"))
        #expect(scanned.first == "1.21.4")
        #expect(scanned.last == "b1.7.3")
        #expect(scanned.contains("1.12.2"))
    }
}

// MARK: - Java detection

struct JavaDetectionTests {

    @Test func parsesVersionStrings() {
        #expect(LauncherEngine.parseJavaMajor(from: "openjdk version \"21.0.1\" 2023-10-17") == 21)
        #expect(LauncherEngine.parseJavaMajor(from: "java version \"1.8.0_402\"") == 8)
        #expect(LauncherEngine.parseJavaMajor(from: "openjdk version \"17.0.9\" 2023-10-17 LTS") == 17)
    }

    @Test func heuristicsPerEra() {
        #expect(LauncherEngine.heuristicJavaMajor(for: "1.21.4") == 21)
        #expect(LauncherEngine.heuristicJavaMajor(for: "1.20.5") == 21)
        #expect(LauncherEngine.heuristicJavaMajor(for: "1.20.4") == 17)
        #expect(LauncherEngine.heuristicJavaMajor(for: "1.18.2") == 17)
        #expect(LauncherEngine.heuristicJavaMajor(for: "1.17") == 16)
        #expect(LauncherEngine.heuristicJavaMajor(for: "1.16.5") == 8)
        #expect(LauncherEngine.heuristicJavaMajor(for: "24w13a") == 21)
        #expect(LauncherEngine.heuristicJavaMajor(for: "b1.7.3") == 8)
    }

    @Test func yearStyleVersionsMapToPreviousYearJVM() {
        // 26.3 ships Java 25; 27.x will want 26; snapshot ids stay at 21.
        #expect(LauncherEngine.heuristicJavaMajor(for: "26.3") == 25)
        #expect(LauncherEngine.heuristicJavaMajor(for: "26.4-snapshot-3") == 25)
        #expect(LauncherEngine.heuristicJavaMajor(for: "27.0") == 26)
    }

    @Test func legacyArgumentAdjustments() {
        let modern = LauncherEngine.legacyArgumentAdjustments(for: "1.21.4")
        #expect(!modern.omitsAssetIndex && !modern.includesUserProperties)
        let old = LauncherEngine.legacyArgumentAdjustments(for: "1.6.4")
        #expect(old.omitsAssetIndex && old.includesUserProperties)
        let pre172 = LauncherEngine.legacyArgumentAdjustments(for: "1.7.1")
        #expect(pre172.omitsAssetIndex && pre172.includesUserProperties)
    }
}

// MARK: - Launch parameters

struct LaunchParameterTests {

    @Test func heapSizing() {
        let gigabyte: UInt64 = 1024 * 1024 * 1024
        #expect(LauncherEngine.recommendedHeapMegabytes(for: 8 * gigabyte) == 2048)
        #expect(LauncherEngine.recommendedHeapMegabytes(for: 16 * gigabyte) == 4096)
        #expect(LauncherEngine.recommendedHeapMegabytes(for: 32 * gigabyte) == 4096)
        #expect(LauncherEngine.recommendedHeapMegabytes(for: 2 * gigabyte) == 1024)
    }

    @Test func usernameValidation() {
        #expect(LauncherEngine.isValidMinecraftUsername("Notch"))
        #expect(LauncherEngine.isValidMinecraftUsername("Velo_Player1"))
        #expect(!LauncherEngine.isValidMinecraftUsername(""))
        #expect(!LauncherEngine.isValidMinecraftUsername(String(repeating: "a", count: 17)))
        #expect(!LauncherEngine.isValidMinecraftUsername("a b"))
        #expect(!LauncherEngine.isValidMinecraftUsername("a.b"))
    }
}

// MARK: - Maven layout & integrity

struct MavenLayoutTests {

    @Test func mavenPathDerivation() {
        #expect(MojangDownloader.mavenPath(for: "com.mojang:brigadier:1.0.18")
                == "com/mojang/brigadier/1.0.18/brigadier-1.0.18.jar")
        #expect(MojangDownloader.mavenPath(for: "org.lwjgl.lwjgl:lwjgl-platform:2.9.1:natives-osx")
                == "org/lwjgl/lwjgl/lwjgl-platform/2.9.1/lwjgl-platform-2.9.1-natives-osx.jar")
        #expect(MojangDownloader.mavenPath(for: "org.lwjgl.lwjgl:lwjgl-platform:2.9.1", classifier: "natives-osx")
                == "org/lwjgl/lwjgl/lwjgl-platform/2.9.1/lwjgl-platform-2.9.1-natives-osx.jar")
    }

    @Test func sha1AndIntegrity() throws {
        let probe = makeTempDirectory("sha1").appendingPathComponent("probe.bin")
        let data = Data("velo".utf8)
        try data.write(to: probe)

        #expect(MojangDownloader.sha1(ofData: data) == "803ddf02118a9bb1e44b909fc9e0a2892c0fd41d")
        #expect(try MojangDownloader.sha1(ofFile: probe) == MojangDownloader.sha1(ofData: data))
        #expect(MojangDownloader.fileIsIntact(at: probe, size: 4))
        #expect(!MojangDownloader.fileIsIntact(at: probe, size: 5))
        #expect(!MojangDownloader.fileIsIntact(at: probe.deletingLastPathComponent().appendingPathComponent("nope"), size: 4))
    }
}

// MARK: - Manifest resolution

struct ManifestResolutionTests {

    static let fixtureJSON = """
    {
      "id": "test", "type": "release",
      "mainClass": "net.minecraft.client.main.Main",
      "assets": "1.21",
      "assetIndex": {"id": "1.21", "sha1": "abc", "size": 1, "totalSize": 2, "url": "https://example.invalid/1.21.json"},
      "javaVersion": {"component": "java-runtime-gamma", "majorVersion": 21},
      "downloads": {"client": {"sha1": "x", "size": 100, "url": "https://example.invalid/client.jar"}},
      "libraries": [
        {"name": "com.mojang:brigadier:1.0.18",
         "downloads": {"artifact": {"path": "com/mojang/brigadier/1.0.18/brigadier-1.0.18.jar", "sha1": "a", "size": 10, "url": "https://example.invalid/brigadier.jar"}}},
        {"name": "org.lwjgl.lwjgl:lwjgl-platform:2.9.1",
         "natives": {"osx": "natives-osx"},
         "rules": [{"action": "allow", "os": {"name": "osx"}}, {"action": "allow", "os": {"name": "linux"}}],
         "downloads": {"artifact": {"path": "org/lwjgl/lwjgl/lwjgl-platform/2.9.1/lwjgl-platform-2.9.1.jar", "sha1": "b", "size": 20, "url": "https://example.invalid/lwjgl-platform.jar"},
                       "classifiers": {"natives-osx": {"path": "org/lwjgl/lwjgl/lwjgl-platform/2.9.1/lwjgl-platform-2.9.1-natives-osx.jar", "sha1": "c", "size": 30, "url": "https://example.invalid/natives-osx.jar"}}}},
        {"name": "net.java.jinput:jinput-platform:2.0.5",
         "natives": {"windows": "natives-windows", "osx": "natives-osx"},
         "downloads": {"classifiers": {"natives-windows": {"path": "w.jar", "url": "https://example.invalid/w.jar"}}}},
        {"name": "com.mojang:text2speech:1.11.3",
         "rules": [{"action": "allow", "os": {"name": "linux"}}],
         "downloads": {"artifact": {"path": "com/mojang/text2speech/1.11.3/text2speech-1.11.3.jar", "sha1": "d", "size": 5, "url": "https://example.invalid/t2s.jar"}}},
        {"name": "org.legacy:oldlib:0.1", "url": "https://libraries.minecraft.net/"}
      ]
    }
    """

    @Test func decodesVersionPackage() throws {
        let package = try MojangDownloader.decodeVersionPackage(Data(Self.fixtureJSON.utf8))
        #expect(package.mainClass == "net.minecraft.client.main.Main")
        #expect(package.javaVersion?.majorVersion == 21)
        #expect(package.assetIndex?.id == "1.21")
    }

    @Test func resolvesOSXLibraryRequests() throws {
        let package = try MojangDownloader.decodeVersionPackage(Data(Self.fixtureJSON.utf8))
        let requests = MojangDownloader.libraryRequests(for: package)
        let paths = requests.map { $0.path }

        #expect(requests.count == 5)
        #expect(!paths.contains("com/mojang/text2speech/1.11.3/text2speech-1.11.3.jar"))   // linux-only
        #expect(paths.contains("org/lwjgl/lwjgl/lwjgl-platform/2.9.1/lwjgl-platform-2.9.1.jar"))
        #expect(paths.contains("org/lwjgl/lwjgl/lwjgl-platform/2.9.1/lwjgl-platform-2.9.1-natives-osx.jar"))
        #expect(paths.contains("net/java/jinput/jinput-platform/2.0.5/jinput-platform-2.0.5-natives-osx.jar"))
        #expect(paths.contains("org/legacy/oldlib/0.1/oldlib-0.1.jar"))
        if let legacy = requests.first(where: { $0.path == "org/legacy/oldlib/0.1/oldlib-0.1.jar" }) {
            #expect(legacy.url == "https://libraries.minecraft.net/org/legacy/oldlib/0.1/oldlib-0.1.jar")
        }
    }

    @Test func decodesLegacyAssetIndexKeys() throws {
        let indexJSON = """
        {"objects": {"minecraft/sounds/a.ogg": {"hash": "deadbeef01", "size": 3}},
         "virtual": true, "map_to_resources": true}
        """
        let index = try MojangDownloader.decoder.decode(
            AssetIndex.self,
            from: Data(indexJSON.utf8)
        )
        #expect(index.virtual == true)
        #expect(index.mapToResources == true)
        #expect(index.objects["minecraft/sounds/a.ogg"]?.hash == "deadbeef01")
    }

    // MARK: Manifest jvm arguments (future-proofing channel)

    @Test func extractsOSRelevantJVMFlagsFromManifest() throws {
        let packageJSON = """
        {
          "id": "26.3", "type": "release",
          "mainClass": "net.minecraft.client.main.Main",
          "javaVersion": {"component": "java-runtime-gamma", "majorVersion": 25},
          "downloads": {"client": {"sha1": "x", "size": 1, "url": "https://example.invalid/c.jar"}},
          "arguments": {
            "jvm": [
              {"rules": [{"action": "allow", "os": {"name": "osx"}}], "value": ["-XstartOnFirstThread"]},
              {"rules": [{"action": "allow", "os": {"name": "windows"}}], "value": "-XX:HeapDumpPath=MojangTricksIntelDriversForPerformance_javaw.exe_minecraft.exe.heapdump"},
              {"rules": [{"action": "allow", "os": {"arch": "x86"}}], "value": "-Xss1M"},
              "-XX:StackShadowPages=32",
              "--enable-native-access=ALL-UNNAMED",
              "--add-exports",
              "java.base/jdk.internal.misc=ALL-UNNAMED",
              "-Djava.library.path=${natives_directory}/java",
              "-Djna.tmpdir=${natives_directory}/jna",
              "-Dminecraft.launcher.brand=${launcher_name}",
              "-cp",
              "${classpath}"
            ],
            "game": ["--username", "${auth_player_name}"]
          }
        }
        """
        let package = try MojangDownloader.decodeVersionPackage(Data(packageJSON.utf8))
        let flags = MojangDownloader.jvmFlags(in: package)

        #expect(flags.contains("-XstartOnFirstThread"))                 // osx rule
        #expect(flags.contains("-XX:StackShadowPages=32"))              // bare string
        #expect(flags.contains("--enable-native-access=ALL-UNNAMED"))
        #expect(flags.contains("--add-exports"))
        #expect(flags.contains("java.base/jdk.internal.misc=ALL-UNNAMED"))
        #expect(flags.contains("-Xss1M"))                               // arch rule → allowed
        #expect(!flags.contains("-XX:HeapDumpPath=MojangTricksIntelDriversForPerformance_javaw.exe_minecraft.exe.heapdump"))  // windows rule
        #expect(!flags.contains("-cp"))                                 // Blocky owns the classpath
        #expect(!flags.contains("${classpath}"))
        #expect(!flags.contains { $0.contains("${") })                  // every template dropped
        #expect(flags.filter { $0 == "-XstartOnFirstThread" }.count == 1)
    }

    @Test func emptyManifestYieldsNoFlags() throws {
        // 1.12-era manifests predate `arguments` — nothing to merge.
        let package = try MojangDownloader.decodeVersionPackage(Data("""
        {"id": "1.12.2", "mainClass": "net.minecraft.client.main.Main",
         "downloads": {"client": {"sha1": "x", "size": 1, "url": "https://example.invalid/c.jar"}}}
        """.utf8))
        #expect(MojangDownloader.jvmFlags(in: package).isEmpty)
    }
}

// MARK: - Classpath compilation

struct ClasspathTests {

    @Test func recursiveScanPlusClientJarLast() throws {
        let fm = FileManager.default
        let root = makeTempDirectory("classpath")
        let engine = LauncherEngine(minecraftRoot: root)

        for jar in ["libraries/com/example/a/1.0/a-1.0.jar",
                    "libraries/org/other/b-2.0.jar",
                    "libraries/nested/deep/c-3.0.jar"] {
            let url = root.appendingPathComponent(jar, isDirectory: false)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data([0]))
        }
        fm.createFile(atPath: root.appendingPathComponent("libraries/ignored.txt").path, contents: Data([0]))
        fm.createFile(atPath: root.appendingPathComponent("libraries/.hidden/h.jar").path, contents: Data([0]))

        let clientJar = root.appendingPathComponent("versions/1.20.1/1.20.1.jar", isDirectory: false)
        try fm.createDirectory(at: clientJar.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: clientJar.path, contents: Data([0]))

        let classpath = try engine.buildClasspath(clientJar: clientJar, package: nil)
        let entries = classpath.components(separatedBy: ":")

        #expect(entries.count == 4)
        #expect(classpath.contains(":"))
        #expect(entries.last?.hasSuffix("1.20.1.jar") == true)
        #expect(entries.contains { $0.hasSuffix("c-3.0.jar") })
        #expect(!classpath.contains("ignored.txt") && !classpath.contains("h.jar"))
    }

    @Test func heapOverrideWinsOverAutoSizing() {
        #expect(LauncherEngine.heapMegabytes(manualOverrideGB: 6) == 6144)
        // 0 = auto: falls back to the RAM-sized default (machine-dependent,
        // but always within the sane band).
        let auto = LauncherEngine.heapMegabytes(manualOverrideGB: 0)
        #expect(auto >= 1024 && auto <= 4096)
    }

    @Test func inheritsFromMergeKeepsChildMainClassAndParentClient() throws {
        // Fabric-style profile: no client download, its own mainClass and
        // loader libraries, inheriting vanilla's client/assets/java.
        let childJSON = """
        {
          "id": "fabric-loader-26.3-0.16.14", "type": "release",
          "inheritsFrom": "26.3",
          "mainClass": "net.fabricmc.loader.impl.launch.knot.KnotClient",
          "libraries": [
            {"name": "net.fabricmc:fabric-loader:0.16.14",
             "downloads": {"artifact": {"path": "net/fabricmc/fabric-loader/0.16.14/fabric-loader-0.16.14.jar", "sha1": "a", "size": 4, "url": "https://maven.fabricmc.test/fabric-loader-0.16.14.jar"}}}
          ]
        }
        """
        let parentJSON = """
        {
          "id": "26.3", "type": "release",
          "mainClass": "net.minecraft.client.main.Main",
          "assets": "26.3",
          "assetIndex": {"id": "34", "sha1": "x", "size": 1, "totalSize": 2, "url": "https://example.invalid/34.json"},
          "javaVersion": {"component": "java-runtime-gamma", "majorVersion": 25},
          "downloads": {"client": {"sha1": "c", "size": 9, "url": "https://example.invalid/client.jar"}},
          "libraries": [
            {"name": "com.mojang:brigadier:1.0.18",
             "downloads": {"artifact": {"path": "com/mojang/brigadier/1.0.18/brigadier-1.0.18.jar", "sha1": "b", "size": 3, "url": "https://example.invalid/brigadier.jar"}}}
          ]
        }
        """
        let child = try MojangDownloader.decodeVersionPackage(Data(childJSON.utf8))
        let parent = try MojangDownloader.decodeVersionPackage(Data(parentJSON.utf8))
        let merged = LauncherEngine.merged(child: child, parent: parent)

        #expect(merged.inheritsFrom == nil)
        #expect(merged.mainClass == "net.fabricmc.loader.impl.launch.knot.KnotClient")
        #expect(merged.downloads?.client?.url == "https://example.invalid/client.jar")
        #expect(merged.assetIndex?.id == "34")
        #expect(merged.javaVersion?.majorVersion == 25)
        #expect(merged.libraries?.count == 2)
        #expect(merged.libraries?[0].name?.hasPrefix("net.fabricmc") == true)     // child's loader first
        #expect(merged.libraries?[1].name?.hasPrefix("com.mojang") == true)      // parent's vanilla libs second
    }
}

// MARK: - Process output streaming

struct ProcessStreamingTests {

    @Test func reassemblesLinesIncludingFinalPartialLine() async throws {
        let box = LineBox()
        let streamer = LogStreamer(label: "test") { box.append($0) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'alpha\\nbeta\\ngamma'"]   // no trailing newline
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        streamer.attach(to: pipe)
        process.waitUntilExit()
        streamer.finish()

        try await waitFor(timeout: 2.0) { box.values.count >= 3 }
        #expect(box.values == ["alpha", "beta", "gamma"])
    }
}

// MARK: - Concurrency gate

struct ConcurrencyGateTests {

    @Test func boundsConcurrentTransfersToCapacity() async throws {
        let gate = AsyncConcurrencyGate(capacity: 2)
        let counter = FinalCounter()
        var peak = 0

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.acquire()
                    let now = counter.increment()
                    peak = max(peak, now)
                    try? await Task.sleep(for: .milliseconds(8))
                    counter.decrement()
                    await gate.release()
                }
            }
        }

        #expect(peak <= 2)
        #expect(peak > 0)
    }
}

/// Thread-safe activity gauge for the gate test.
final class FinalCounter {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        value += 1
        let current = value
        lock.unlock()
        return current
    }

    func decrement() {
        lock.lock()
        value -= 1
        lock.unlock()
    }
}
