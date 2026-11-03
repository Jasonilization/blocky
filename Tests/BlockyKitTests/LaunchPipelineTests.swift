import Testing
import Foundation
@testable import BlockyKit

// MARK: - The classpath-isolation regression

/// The launch failure that looked like "this version can't run": a machine
/// that installed several versions through several launchers accumulates
/// every dependency under the shared libraries/ folder. Blocky used to
/// glob the whole tree onto the classpath, so two LWJGL builds landed
/// together and LWJGL aborted every launch with
/// "Incompatible Java and native library versions detected".
/// The classpath must be EXACTLY the manifest's list for the version.
@Test
func classpathIsExactlyTheManifestsLibraries() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("blocky-classpath-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fm = FileManager.default
    let libs = root.appendingPathComponent("libraries", isDirectory: true)
    let versions = root.appendingPathComponent("versions", isDirectory: true)

    let wanted = libs.appendingPathComponent("org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3.jar", isDirectory: false)
    let stale = libs.appendingPathComponent("org/lwjgl/lwjgl/3.3.3/lwjgl-3.3.3.jar", isDirectory: false)
    let otherLauncher = libs.appendingPathComponent("org/tlauncher/authlib/6.0.55.3/authlib-6.0.55.3.jar", isDirectory: false)
    for jar in [wanted, stale, otherLauncher] {
        try fm.createDirectory(at: jar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("empty jar".utf8).write(to: jar)
    }

    let clientDir = versions.appendingPathComponent("t", isDirectory: true)
    try fm.createDirectory(at: clientDir, withIntermediateDirectories: true)
    let clientJar = clientDir.appendingPathComponent("t.jar")
    try Data("client jar".utf8).write(to: clientJar)

    let engine = LauncherEngine(minecraftRoot: root)

    // A package that declares ONLY the modern LWJGL — the others merely
    // sit in libraries/ from other versions/launchers.
    let package = VersionPackage(
        id: "t",
        type: "release",
        mainClass: "net.minecraft.client.main.Main",
        assets: "1",
        assetIndex: nil,
        libraries: [
            VersionPackage.LibraryReference(
                name: "org.lwjgl:lwjgl:3.4.3",
                url: nil,
                downloads: nil,
                natives: nil,
                rules: nil
            ),
            // A natives classifier entry — must resolve to its own path
            // and never the plain artifact's.
            VersionPackage.LibraryReference(
                name: "com.mojang:jtracy:1.14.38",
                url: nil,
                downloads: nil,
                natives: ["osx": "natives-macos-arm64"],
                rules: nil
            ),
        ],
        javaVersion: nil,
        downloads: nil,
        arguments: nil,
        inheritsFrom: nil
    )

    let classpath = try engine.buildClasspath(clientJar: clientJar, package: package)
    #expect(classpath.contains("lwjgl-3.4.3.jar"))
    #expect(!classpath.contains("lwjgl-3.3.3.jar"),
            "a second LWJGL on the classpath aborts every launch")
    #expect(!classpath.contains("tlauncher"))
    #expect(classpath.hasSuffix(clientJar.path), "the client jar rides last")

    // Without a manifest there is nothing to resolve — the whole-tree
    // sweep is the only honest fallback.
    let sweep = try engine.buildClasspath(clientJar: clientJar, package: nil)
    #expect(sweep.contains("lwjgl-3.3.3.jar"),
            "manifestless versions fall back to the full sweep")
}

@Test
func classpathThrowsWhenClientJarIsMissing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("blocky-classpath-missing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = LauncherEngine(minecraftRoot: root)
    let missing = root.appendingPathComponent("versions/t/t.jar")
    var threw = false
    do {
        _ = try engine.buildClasspath(clientJar: missing, package: nil)
    } catch {
        threw = true
    }
    #expect(threw, "a missing client jar must abort the launch, not silently boot")
}

// MARK: - Java requirement inference

@Test
func javaRequirementInference() throws {
    // Year-style ids pair with the previous year's LTS line.
    #expect(LauncherEngine.heuristicJavaMajor(for: "26.4-snapshot-6") == 25)
    #expect(LauncherEngine.heuristicJavaMajor(for: "26.3") == 25)
    // Classic era, exactly matching real Minecraft requirements:
    // 8 through 1.16.5, 16 at 1.17, 17 through 1.20.4, 21 from 1.20.5.
    #expect(LauncherEngine.heuristicJavaMajor(for: "1.21.11") == 21)
    #expect(LauncherEngine.heuristicJavaMajor(for: "1.20.5") == 21)
    #expect(LauncherEngine.heuristicJavaMajor(for: "1.20.4") == 17)
    #expect(LauncherEngine.heuristicJavaMajor(for: "1.18.1") == 17)
    #expect(LauncherEngine.heuristicJavaMajor(for: "1.17.1") == 16)
    #expect(LauncherEngine.heuristicJavaMajor(for: "1.16.5") == 8)
    #expect(LauncherEngine.heuristicJavaMajor(for: "b1.7.3") == 8)
    #expect(LauncherEngine.heuristicJavaMajor(for: "a1.0.17") == 8)
    // Modern snapshot ids stay on the baseline.
    #expect(LauncherEngine.heuristicJavaMajor(for: "24w13a") == 21)
}

// MARK: - Legacy argument surface

@Test
func legacyArgumentSurface() throws {
    let ancient = LauncherEngine.legacyArgumentAdjustments(for: "b1.2.6")
    #expect(ancient.omitsAssetIndex)
    #expect(ancient.includesUserProperties)

    let pre172 = LauncherEngine.legacyArgumentAdjustments(for: "1.2.5")
    #expect(pre172.omitsAssetIndex)
    #expect(pre172.includesUserProperties)

    let post172 = LauncherEngine.legacyArgumentAdjustments(for: "1.7.10")
    #expect(!post172.omitsAssetIndex)
    #expect(!post172.includesUserProperties)

    let modern = LauncherEngine.legacyArgumentAdjustments(for: "1.21.4")
    #expect(!modern.omitsAssetIndex)
    #expect(!modern.includesUserProperties)
}

// MARK: - Environment toolkit

@Test
func environmentToolkitBasics() throws {
    #expect(!EnvironmentToolkit.brewCandidatePaths.isEmpty)

    // openjdk@N is the formula for every supported major but the unversioned core.
    #expect(EnvironmentToolkit.openJDKFormula(for: 25) == "openjdk@25")
    #expect(EnvironmentToolkit.openJDKFormula(for: 21) == "openjdk@21")

    #expect(EnvironmentToolkit.expectedBrewKegPath(for: "openjdk@25") == "/opt/homebrew/opt/openjdk@25")

    let install = EnvironmentToolkit.homebrewInstallCommand()
    #expect(install.contains("NONINTERACTIVE=1"))
    // The installer URL rides inside the bash -c invocation.
    let joined = install.joined(separator: " ")
    #expect(joined.contains("https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"))

    let paths = EnvironmentToolkit.expectableJavaBinaryPaths(for: 25)
    #expect(paths.contains("/opt/homebrew/opt/openjdk@25/bin/java"))
    #expect(paths.contains("/opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home/bin/java"))

    let invocation = EnvironmentToolkit.brewInstallCommand(
        formula: "openjdk@25",
        brewBinary: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    )
    #expect(invocation == ["/opt/homebrew/bin/brew", "install", "openjdk@25"])
}

// MARK: - Server directory

@Test
func serverDirectoryIntegrity() throws {
    let servers = ServerDirectory.recommended
    #expect(servers.count >= 8)

    // Uniqueness + sane ports.
    var hosts = Set<String>()
    for server in servers {
        #expect(hosts.insert(server.host).inserted, "duplicate host \(server.host)")
        #expect(server.port > 0)
        #expect(!server.name.isEmpty)
        #expect(!server.blurb.isEmpty)
    }

    // The user's example must survive in the recommendation set.
    #expect(servers.contains { $0.host == "mc.mineberry.org" && $0.port == 25565 })
}

@Test
func serverAddressParsing() throws {
    // Default port.
    let bare = try #require(ServerDirectory.parseAddress("mc.hypixel.net"))
    #expect(bare.port == 25565)
    #expect(bare.address == "mc.hypixel.net")

    // Explicit port — copy-safe.
    let explicit = try #require(ServerDirectory.parseAddress("mc.example.org:25570"))
    #expect(explicit.port == 25570)
    #expect(explicit.address == "mc.example.org:25570")

    #expect(ServerDirectory.parseAddress("   ") == nil)
    #expect(ServerDirectory.parseAddress(":25565") == nil)
}

// MARK: - SLP response parsing

@Test
func serverListPingResponseParsing() throws {
    // A status response as a real server writes it:
    // packetLength, packetID(0x00), jsonLength, JSON.
    let json = """
    {"version":{"name":"1.21.4","protocol":769},"players":{"online":42,"max":100},"description":"Hypixel Network"}
    """
    var packet = Data()
    packet.append(0x00)                                     // packet id
    packet.append(UInt8(json.utf8.count))                    // string length
    packet.append(json.data(using: .utf8)!)

    var frame = Data()
    frame.append(UInt8(packet.count))                        // packet length
    frame.append(packet)

    let answer = ServerPingClient.parseStatusResponse(frame)
    #expect(answer != nil)
    #expect(answer?.playersOnline == 42)
    #expect(answer?.playersMax == 100)
    #expect(answer?.versionLabel == "1.21.4")
    #expect(answer?.motd == "Hypixel Network")

    // Truncated buffers report nil rather than garbage.
    #expect(ServerPingClient.parseStatusResponse(Data([0x7F])) == nil)
    #expect(ServerPingClient.parseStatusResponse(Data()) == nil)

    // Chat-object MOTDs ({"text":…}) resolve too.
    let objectMOTD = #"{"description":{"text":"Welcome"}}"#
    var packet2 = Data()
    packet2.append(0x00)
    packet2.append(UInt8(objectMOTD.utf8.count))
    packet2.append(objectMOTD.data(using: .utf8)!)
    var frame2 = Data()
    frame2.append(UInt8(packet2.count))
    frame2.append(packet2)
    #expect(ServerPingClient.parseStatusResponse(frame2)?.motd == "Welcome")
}
