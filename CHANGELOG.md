# Changelog

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
