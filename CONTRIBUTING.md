# Contributing to Blocky

Thanks for wanting to help!

## Getting set up

```bash
git clone https://github.com/Jasonilization/blocky.git
cd blocky
./Scripts/swift-build.sh
./Scripts/swift-test.sh
```

Command Line Tools are enough — no Xcode project exists or is needed. The
build scripts handle CLT-specific quirks automatically (SDK pinning and Swift
Testing plugin paths); with full Xcode installed they stay out of the way.

## Before you submit

- `./Scripts/swift-test.sh` passes (25 tests / 9 suites).
- New behavior comes with tests where practical — the launch pipeline in
  `BlockyKit` is the part worth locking down.
- No new warnings if avoidable.
- Keep the UI honest and minimal: one window, one column, one button. If a
  feature needs a settings panel, it probably belongs somewhere else.
- Keep Blocky offline: no analytics, no accounts, no network outside Mojang's
  public manifest endpoints, and no Microsoft-auth code paths. It is an
  offline launcher for people who own the game — never a piracy tool.

## For bigger changes

Open an issue first describing what you want to build — especially anything
that touches process spawning, the classpath compiler, Java detection, or
the downloader's rule engine. Those areas are deliberately conservative:
correctness on real Mojang data beats features.
