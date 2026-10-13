# Changelog

## 1.0.0 — 2026-10-13

Initial release.

### Added

- Borderless fixed-size frosted-glass launcher window (`.ultraThinMaterial`, forced dark scheme, `.hiddenTitleBar` with drag-anywhere), centered single-column layout with tracked monospaced wordmark and reserved inline status slot.
- Username field with `@AppStorage` persistence and classic `1–16 [A-Za-z0-9_]` validation; red inline errors for invalid input.
- Version picker fed by a scanner over `~/Library/Application Support/minecraft/versions`: hidden-file filtering, `<id>/<id>.jar` and flat-jar layouts, manifest-release-date ordering with era-bucketed numeric-aware fallback (rd* < alpha < beta < 1.x < snapshots).
- Mojang manifest integration: piston-meta v2 catalog (launchermeta fallback), per-version package parsing, remote section in the picker, install-on-launch for uninstalled versions.
- Concurrent downloader: client jar, rule-filtered libraries with macOS natives classifiers (modern `downloads.artifact/classifiers` and 2013-era `name`+base-URL formats), asset index + objects with `virtual/` and `resources/` mirrors for legacy layouts; sha1-verified, atomic installs, retry with backoff, bounded concurrency (8 libraries / 12 assets), idempotent re-launches.
- Offline identity generator reproducing Java's `UUID.nameUUIDFromBytes("OfflinePlayer:<name>")` byte-for-byte (MD5, version-3 + RFC 4122 variant bits, canonical hyphenation) — cross-verified against known canonical UUIDs.
- Classpath compiler: version-resolved dependency paths first, then the recursive `libraries/` jar sweep, client jar last, colon-joined — safe for multi-version library folders.
- Java auto-detection: `/usr/libexec/java_home`, Homebrew openjdk (Apple Silicon + Intel prefixes), `/Library/Java/JavaVirtualMachines`, `JAVA_HOME`; exact-major preference with version JSON `javaVersion` as authority and a per-era heuristic fallback; memory sized from physical RAM (floor 2 GB, cap 4 GB).
- Natives extraction chain (`unzip` → `ditto` → JDK `jar`) into a per-version directory, refreshed every launch; `-Djava.library.path` wiring.
- Launch pipeline on a background utility queue with full offline arguments (`--accessToken 0 --userType legacy`, asset index selection, legacy virtual assets, pre-1.7.2 `--assetIndex`/`--userProperties` adjustments, Log4Shell kill-switch).
- Async stdout/stderr streaming through readability handlers with guaranteed final partial-line flush; a utility-queue reaper reports non-zero game exit codes into the status slot.
- Hover-animated LAUNCH button (scale + opacity easing), in-progress spinner state, inline cancel.
- 20-test suite (9 suites) covering UUID byte-exactness, scanning/ordering, Java parsing, maven layout, rule engine, classpath assembly, log streaming, and the concurrency gate.
- CLT-friendly build scripts (SDK pinning, Swift Testing plugin paths) and a `.app` bundling script with ad-hoc signing.

### Fixed during development

- `LogStreamer` dropped the game's final log line when it had no trailing newline — `finish()` now always flushes the pending partial line (regression-tested).
- The download concurrency gate is an actor; slots transfer directly from a releasing task to the next waiter, and the slot is released exactly once per exit path including cancellation.
- Beta ids (`b1.7.3`) no longer sort above modern releases in the version picker.
