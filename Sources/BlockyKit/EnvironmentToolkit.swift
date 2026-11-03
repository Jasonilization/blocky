//
//  EnvironmentToolkit.swift
//  Blocky
//
//  PART 3 — Machine setup: Homebrew discovery, Homebrew installation, and
//  JDK installation through it. The launcher's promise is "it just works",
//  and the two things that most often break that on a fresh Mac are a
//  missing Homebrew and a missing (or wrong-major) Java. Everything here is
//  oath-neutral: pure Foundation, testable without root, no GUI.
//

import Foundation

public struct EnvironmentToolkit {

    // MARK: Homebrew discovery

    /// The binaries Homebrew can appear as, in preference order.
    public static let brewCandidatePaths = [
        "/opt/homebrew/bin/brew",   // Apple Silicon default
        "/usr/local/bin/brew",      // Intel default
        "/home/linuxbrew/.linuxbrew/bin/brew",
    ]

    /// First executable brew on the standard paths, verified by asking it for
    /// its version (a stale symlink that points at a moved keg is not brew).
    public static func brewBinary() -> URL? {
        for path in brewCandidatePaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            if brewVersion(of: url) != nil { return url }
        }
        // PATH lookup as a last resort (brewportable, custom prefixes).
        if let fromPath = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init)
            .compactMap({ dir -> URL? in
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent("brew")
                return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
            })
            .first(where: { brewVersion(of: $0) != nil }) {
            return fromPath
        }
        return nil
    }

    /// `brew --version` output with the path prefix stripped, or nil.
    public static func brewVersion(of binary: URL) -> String? {
        guard let output = ShellRunner.run(executablePath: binary.path, arguments: ["--version"]),
              let line = output.split(separator: "\n").first else { return nil }
        let text = line.trimmingCharacters(in: .whitespaces)
        // "Homebrew 4.x.y" / "Homebrew 5.0.1-..."
        return text.replacingOccurrences(of: "Homebrew ", with: "")
    }

    /// True when brew is installed and callable.
    public static func isBrewInstalled() -> Bool {
        brewBinary() != nil
    }

    // MARK: Java formulas

    /// The openjdk formula name for a required Java major:
    /// `openjdk@25` for 25+, `openjdk` for old LTS tracks that have no
    /// `@`-versioned keg (8/11 are long out of core; we still map them).
    public static func openJDKFormula(for major: Int) -> String {
        switch major {
        case 8:  return "openjdk@8"           // no keg on current brew, but the name stays honest
        case 11: return "openjdk@11"
        default: return "openjdk@" + String(major)
        }
    }

    /// The keg prefix where brew would install this formula, used to tell the
    /// user (and our own probe) where to find it afterwards.
    public static func expectedBrewKegPath(for formula: String) -> String {
        return "/opt/homebrew/opt/" + formula
    }

    /// After `brew install openjdk@25`, the JDK lives under
    /// `…/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home/bin/java` (or
    /// bin/java depending on the keg layout). Both are probed by the engine's
    /// Java discovery; this exposes the primary one for messaging.
    public static func expectableJavaBinaryPaths(for major: Int) -> [String] {
        let formula = openJDKFormula(for: major)
        let prefix = brewPrefixForCurrentArchitecture()
        return [
            "\(prefix)/opt/\(formula)/bin/java",
            "\(prefix)/opt/\(formula)/libexec/openjdk.jdk/Contents/Home/bin/java",
            "/Library/Java/JavaVirtualMachines/openjdk-\(major).jdk/Contents/Home/bin/java",
        ]
    }

    /// Apple Silicon vs Intel homebrew prefix.
    public static func brewPrefixForCurrentArchitecture() -> String {
        #if arch(arm64)
        return "/opt/homebrew"
        #else
        return "/usr/local"
        #endif
    }

    // MARK: Command construction

    /// The full command line for installing Homebrew non-interactively.
    /// The official installer needs root for its first step; the caller is
    /// expected to run it through an administrator-privileges shell.
    public static func homebrewInstallCommand() -> [String] {
        [
            "NONINTERACTIVE=1",
            "/bin/bash",
            "-c",
            "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)",
        ]
    }

    /// `brew install <formula>` argv for spawning directly (no root needed).
    public static func brewInstallCommand(formula: String, brewBinary: URL) -> [String] {
        [brewBinary.path, "install", formula]
    }
}
