# Blocky

opensource minecraft launcher. enjoy!

<img src="https://img.shields.io/badge/price-free-34C759?style=flat-square" alt="Free">

![Blocky](screenshot.png)

<details>
<summary>more info</summary>

## run

    git clone https://github.com/Jasonilization/blocky.git
    cd blocky
    ./Scripts/setup.sh        # brew + java + Rosetta + Blocky.app
    open Blocky.app

or build directly: `./Scripts/bundle.sh release` (Command Line Tools are enough — no Xcode needed).

## what's inside

- offline launch — no accounts, no telemetry; standard offline UUID (`UUID.nameUUIDFromBytes`-exact)
- picks up every version in `~/Library/Application Support/minecraft`, fetches missing ones (client + libraries + assets, sha1-verified) straight from Mojang
- auto Java detection (`java_home`, Homebrew openjdk, system JVMs) and the flags the game actually needs on macOS — `-XstartOnFirstThread` first among them
- **mods**: Fabric / NeoForge profiles launch through `inheritsFrom` merging — drop `.jar`s in `mods/`, shader packs in `shaderpacks/`; both folders open straight from Settings
- pixel-dissolve fold-out panel: settings (heap slider, Java, backdrops, snapshots, game dir), version manager (sizes + delete), and a live log terminal
- backdrops: frosted glass or Minecraft block textures read straight from your own game files (nothing bundled)
- dual-launch protection, version management, offline UUIDs byte-exact with Java

## for developers

    ./Scripts/swift-build.sh   # SDK pinning handled for CLT-only machines
    ./Scripts/swift-test.sh    # 25 tests / 9 suites

MIT — see [LICENSE](LICENSE). Made by [Jasonilization](https://github.com/Jasonilization).

</details>
