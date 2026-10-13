# Blocky

<h3 align="center">The minimalist offline Minecraft launcher for macOS — frosted glass, one button, zero accounts.</h3>

<p align="center">
  <a href="https://github.com/Jasonilization/blocky/releases"><img src="https://img.shields.io/badge/platform-macOS%2013%2B-333333?style=flat-square&logo=apple&logoColor=white" alt="macOS 13+"></a>
  <a href="https://github.com/Jasonilization/blocky/actions"><img src="https://img.shields.io/github/actions/workflow/status/Jasonilization/blocky/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-000000?style=flat-square" alt="MIT"></a>
  <img src="https://img.shields.io/badge/price-free-34C759?style=flat-square" alt="Free">
</p>

---

Blocky is a tiny, single-window launcher that starts Minecraft entirely from the files on your Mac, in offline mode, without Microsoft accounts. Type a username, pick a version, press one button. If the version isn't installed yet, Blocky fetches the client, libraries, and assets straight from Mojang's public manifest servers first — sha1-verified, HTTPS-only — and then launches. No logins, no telemetry, no Electron, no window chrome. It is honest about what it is: a local launcher for people who already own the game.

## What it does

- **Offline by design** — no Microsoft account, no auth flow, no network requirement for installed versions. The game receives an explicit `--accessToken 0 --userType legacy` offline session and the standard offline UUID (MD5-based, version 3 — byte-for-byte identical to Java's `UUID.nameUUIDFromBytes`, e.g. `Notch` → `b50ad385-829d-3141-a216-7e7d7539ba7f`).
- **Frosted-glass utility window** — borderless, fixed-size, forced-dark panel on `.ultraThinMaterial`; bold monospaced wordmark; drag anywhere; traffic lights stay.
- **Username that remembers you** — persisted via `@AppStorage`; validated to the classic `1–16 [A-Za-z0-9_]` shape with a red inline hint when it isn't.
- **Version picker fed by a real scanner** — reads `~/Library/Application Support/minecraft/versions`, filters hidden files, supports both `<id>/<id>.jar` and ancient flat-jar layouts, and sorts newest-first using manifest release dates with a numeric-aware, era-bucketed fallback (betas sort *below* modern releases, snapshots above).
- **Fetches missing versions from Mojang** — piston-meta manifest → per-version package JSON → client jar + rule-filtered libraries (including macOS natives classifiers) + the full asset index. Downloads run on a bounded concurrent queue (8 for libraries, 12 for assets), are sha1-verified, written atomically, and skipped when already intact — so re-launching is cheap.
- **Correct multi-version classpaths** — the version's own resolved dependencies come first on `-cp`, then the recursive sweep of every `.jar` under `libraries/`, then the client jar last — so two versions sharing the `libraries/` folder never shadow each other with stale artifacts.
- **Java detection that prefers the right JDK** — `/usr/libexec/java_home`, Homebrew openjdk (both `/opt` and `/usr/local` prefixes), `/Library/Java/JavaVirtualMachines`, and `JAVA_HOME`. The version JSON's `javaVersion` block is authoritative (1.20.5+ needs 21, 1.18+ needs 17, 1.17 needs 16, older needs 8); a heuristic covers JSON-less installs. Exact major preferred, then the newest.
- **Natives handled** — macOS classifier jars are extracted (`unzip` → `ditto` → `jar` fallback chain) into `versions/<id>/natives-<id>/` and wired via `-Djava.library.path`, fresh on every launch.
- **Console streaming** — the child's stdout/stderr are piped into the development console line-by-line through async readability handlers on a utility queue; the final partial line is always flushed.
- **Legacy quirks respected** — pre-1.7.2 builds drop `--assetIndex` and gain `--userProperties {}`; `legacy`/`pre-1.6` asset layouts resolve to their virtual mirror; the Log4Shell kill-switch (`-Dlog4j2.formatMsgNoLookups=true`) rides along on 1.7–1.18.
- **A reserved status slot, not a modal** — download progress, missing-file errors, and crash exit codes render inline (red for exceptions, secondary gray for progress), never shifting the layout.

## Screenshot

![Blocky](screenshot.png)

Captured from the running app on macOS — 340×480 frosted panel over the desktop.

## 📦 Requirements

| | |
|---|---|
| **OS** | macOS 13 (Ventura) or newer |
| **Arch** | Apple Silicon and Intel |
| **Java** | detected automatically — `brew install openjdk@17` (or `openjdk@21` for 1.20.5+; `openjdk@8` for ≤1.12) if you have none |
| **Build** | Swift 6 toolchain — Command Line Tools are enough, no Xcode required |
| **Sandbox** | must run **unsandboxed** — it spawns Java and writes into `~/Library/Application Support/minecraft`, which App Sandbox forbids |

## 🚀 Installation

From source (a signed release build is on the roadmap):

```bash
git clone https://github.com/Jasonilization/blocky.git
cd blocky
./Scripts/bundle.sh release   # → Blocky.app, ad-hoc signed
open Blocky.app
```

First launch: right-click → **Open** (the app is ad-hoc signed, not notarized). The bundle intentionally carries no sandbox entitlements — see the table above.

## 🎮 Using it

1. Type a username (1–16 letters, numbers, or underscores).
2. Pick a version — **Installed** lists what's on disk, **Available online** lists the forty newest releases/snapshots from Mojang's manifest.
3. Press **LAUNCH GAME**. The button locks, spins, streams progress ("Fetching libraries — 12/96"), then hands off to the JVM. Everything the game prints lands in your console, tagged `[minecraft]` / `[minecraft:err]`.

Selecting an online version downloads it on first launch — client jar, every rule-allowed dependency, and the whole asset sweep — then starts it. Rough sizes: ~30 MB client, ~50–120 MB libraries, 300–800 MB assets for modern versions.

## 🔧 How a launch works

1. **Resolve the version definition** — `versions/<id>/<id>.json` locally, else the manifest entry. The JSON is persisted immediately so interrupted installs resume.
2. **Ensure artifacts** — client jar, libraries, asset index + objects (with `virtual/` and `resources/` mirrors for legacy layouts), each verified by sha1 where Mojang publishes one, installed atomically via replace-if-exists.
3. **Compile the classpath** — resolved dependency paths, then the recursive `libraries/` sweep, then the client jar; joined with `:`.
4. **Extract natives** into `versions/<id>/natives-<id>/`.
5. **Choose a JVM** per the version's `javaVersion` (heuristic fallback for unknown ids), memory sized from physical RAM (¼ of RAM, floored at 2 GB, capped at 4 GB).
6. **Spawn on a background utility queue**:

```
java -Xms512M -Xmx…M -XX:+UseG1GC -Djava.library.path=… -Dlog4j2.formatMsgNoLookups=true \
     -cp <libraries…>:<client.jar> net.minecraft.client.main.Main \
     --username <you> --version <id> --gameDir <…>/minecraft --assetsDir <…>/assets \
     --assetIndex <index> --uuid <offline-uuid> --accessToken 0 --userType legacy --versionType release
```

7. **Stream output** — readability handlers reassemble chunks into lines on a serial utility queue; the reaper waits for exit and reports non-zero statuses back into the status slot.

## 🔎 Troubleshooting

- **"No Java runtime found"** — install one: `brew install openjdk@17` (or `@21` for 1.20.5+). Blocky also picks up system JVMs in `/Library/Java/JavaVirtualMachines` and `JAVA_HOME`.
- **Old version won't start on Apple Silicon** — ≤1.12 ships x86_64 natives; install an x86_64 Java under Rosetta (`softwareupdate --install-rosetta`, then Homebrew's Intel prefix under `/usr/local`) and it will run.
- **"was not found locally and is not in Mojang's manifest"** — the id you selected no longer exists upstream and has no local files; remove it from `versions/` or re-download it.
- **Integrity check failed** — a transfer didn't match Mojang's sha1; the next launch automatically re-fetches it.
- **Rebuilt as a raw SwiftPM binary?** `./Scripts/swift-build.sh && .build/debug/Blocky` works, but `UserDefaults` persistence keys off the executable path — prefer the bundled `.app` for daily use.

## Honest notes

- **You must own the game.** Blocky launches offline sessions of the game files on your Mac; it does not and will not bypass paid servers, Realms, skins, or anything requiring a genuine Microsoft session. Offline identity == "Offline Mode" on a LAN server.
- **No telemetry, no accounts, no auto-update.** The only network traffic is Mojang's public piston-meta endpoints, and only while fetching a version.
- **macOS beta caveat** — on the macOS 27 beta SDK, SwiftUI's `@State` becomes a macro whose plugin ships only with full Xcode; the build scripts pin the 26.5 SDK so Command Line Tools users keep building (see `Scripts/swift-build.sh`).

## 🧪 Development

```bash
./Scripts/swift-build.sh    # SDK pinning handled automatically on CLT-only machines
./Scripts/swift-test.sh     # 20 tests / 9 suites — offline UUID byte-exactness, scanner,
                            # ordering, Java probing, maven layout, rule engine,
                            # classpath assembly, log streaming, concurrency gate
```

The launcher core lives in `Sources/BlockyKit` (engine + downloader) and is fully unit-tested; the UI lives in `Sources/Blocky` and is deliberately thin. MIT licensed — see [LICENSE](LICENSE).
