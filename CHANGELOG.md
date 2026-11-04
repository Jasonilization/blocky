# Changelog

## 1.2.0 — 2026-11-04

### Fixed

- **Versions like 26.4-snapshot-6 and 1.21.11 could not run at all.** The classpath swept every jar under `libraries/` recursively, so a machine that had played several versions through several launchers (official, TLauncher, Blocky) put multiple LWJGL builds — 3.3.3, 3.4.1, 3.4.3 — plus three client jars and stale authlib/netty on one classpath, and LWJGL aborted every launch with "Incompatible Java and native library versions detected". The classpath is now exactly the selected version's manifest library list plus its client jar, the same thing the official launcher does; the full-tree sweep survives only as the fallback for folders without a manifest. Verified with real launches: 26.4-snapshot-6 at 82 jars and 1.21.11 at 72, zero LWJGL errors, both reaching "Setting user: Steve".

### Added

- First-run setup wizard: checks the game folder, installed versions, Homebrew and Java, and installs the two that break — Homebrew with a single administrator approval, then `openjdk@N` via brew — with every output line streamed into the launcher terminal. Rerunnable from Settings → Setup.
- Recommended servers: a curated list (the big networks plus offline-friendly servers) with real Server List Pings — live player counts, latency, MOTD — and one-tap address copy.
- Regression tests: classpath isolation against a mixed libraries tree, Java requirement inference per era, legacy argument surface, environment toolkit, server directory, and SLP response parsing.

### Changed

- The fold control is now a near-invisible drawer tab: a bare chevron `›` / `‹` with a full-size hit target, hover plate and tooltip, replacing the circled button.

## 1.1.0 — 2026-11-01

### Added

- Drag-to-Applications installer: `./Scripts/dmg.sh` builds `Blocky-<version>-macOS.dmg` with the app and an Applications shortcut laid out in Finder.
- README showcase: the fold gif, the backdrop carousel, and pressable swatches.
- Sixteen block backdrops, shipped in the app from the README swatches and tiled upright as one continuous picture. The installed client jar is only a fallback. Tiles are larger, with a light even wash and no vignette, so the block art stays the colour of the swatch.

### Fixed

- Backdrop shifted at the middle of the window: the left strip was stretched to the canvas height while the panel blocks were stamped on the unscaled grid.
- Crash on a new material whose procedural palette was shorter than the style index.
- DMG icon size and label size now live on the icon view options, so the Finder layout sticks.

### Removed

- Water backdrop. It shipped briefly and came back out; the set is the solid block faces.

## 1.0.0 — 2026-10-16

First public release.

### Added

- Offline launcher core: local version scanning (hidden-file filtering, manifest-date ordering with era-bucketed numeric fallback), Mojang manifest fetching (piston-meta + launchermeta fallback), concurrent sha1-verified downloads (client jar, rule-filtered libraries with macOS natives classifiers, full asset sweeps with legacy virtual/resources mirrors), and full offline launch parameters (`--accessToken 0 --userType legacy`, the standard offline UUID byte-exact with Java's `nameUUIDFromBytes`).
- macOS-critical JVM flags: `-XstartOnFirstThread` (SDL3/GFML backends die without it — "Unable to initialize SDL" → status 255), plus manifest-driven jvm arguments (`arguments.jvm` parsed with OS rules, `-cp` and `${templates}` excluded) so future version flags flow through automatically; year-style Java heuristics ("26.3" → Java 25); modern-flag safety net gated on the actual JVM.
- Mod-loader launch support: `inheritsFrom` chain merging (child mainClass + libraries, ancestor client jar/assets/Java) — Fabric/NeoForge profiles and modpacks launch correctly; legacy 2013-format library descriptors and absolute-URL maven artifacts supported.
- MoltenVK latency knob: the game process gets `MVK_CONFIG_PRESENT_MODE=0` (IMMEDIATE present) so the Vulkan backend never waits on a translation-layer vsync.
- Folding utility panel with a **pixel dissolve**: on minimize the backdrop's individual pixels wink out one by one into an opaque dark base and the window then snaps over the emptied region (no sliding, no per-frame window resize — the dissolve is pure canvas work driven by a vsync-locked CVDisplayLink); on expand the window opens instantly and pixels materialize one by one.
- Backdrops: frosted glass plus ten Minecraft-material textures — the real 16×16 block textures read live from the user's own `assets/objects` via the asset indexes (nearest-neighbor crisp, per-block quarter-turn variety), with procedural fallbacks (grass side, cobblestone grout, plank grain, netherrack veins, endstone, sandstone strata, deepslate, obsidian sheen).
- Settings: heap slider (2–16 GB with Auto), Java runtime picker with on-disk candidate detection, backdrop picker, snapshot visibility toggle, custom game directory, one-tap `mods`/`shaderpacks` folder opening, terminal-focus mode that folds settings away and gives the log the whole panel.
- Version management: on-disk footprint per version (own files), two-tap confirmed deletion, refusal while a game process is alive.
- Dual-launch protection: second spawns blocked while the game runs; button inert; reaper reports non-zero exits to the status slot.
- Built-in log terminal: ring-buffered (800 lines, amortized trims), stdout/stderr/system coloring, auto-scroll, clear.
- Setup script (`Scripts/setup.sh`): Homebrew, Temurin/openjdk 25 + 17 + 8, Rosetta 2, and the app bundle in one pass.
- App icon (procedural grass-block squircle), CLT-friendly build scripts (macOS 26.5 SDK pin, Swift Testing plugin paths), CI mirroring the house workflow.
- 25-test suite / 9 suites: offline UUID byte-exactness (two known identities), version ordering and era buckets, scanner filtering, Java version parsing and per-era heuristics, legacy argument adjustments, heap sizing + override, username validation, maven layout, sha1 + integrity checks, manifest decoding, OS-rule library resolution, `arguments.jvm` extraction, `inheritsFrom` merging, classpath assembly, log-stream reassembly (final partial line included), concurrency gate bounds.

### Fixed

- Game exited with status 255 instantly: the JVM was never put on the first thread — fixed with `-XstartOnFirstThread`; the final manifest flag list is now honored verbatim.
- Minimize collapse failure: the side panel's fixed frame imposed a 713 pt layout minimum the window could never fold below (SwiftUI's required AutoLayout constraints + a stale saved frame fighting manual sizes) — the panel now rides a non-sizing overlay, autosave is disabled, and the fold snaps at its boundaries.
- Fold jank: the window was resized 48×/second through live material recomposition — the dissolve no longer resizes mid-animation at all (one boundary snap), and ticking is vsync-locked.
- Dissolve flash: transparent window background showed the desktop through dying pixels — an opaque base layer now sits beneath every backdrop.
- `LogStreamer` dropped the game's final log line when it had no trailing newline — `finish()` always flushes.
- Beta versions sorted above modern releases in the picker — era buckets (`rd* < alpha < beta < 1.x < snapshots`).
