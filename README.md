# Blocky

opensource minecraft launcher. enjoy!

<img src="https://img.shields.io/badge/price-free-34C759?style=flat-square" alt="Free">

![Blocky](screenshot.png)

<details>
<summary>backdrops — real block textures from your own game files</summary>

Minecraft block textures extracted live from your game's client jar — the actual in-game art, first frame of animated strips, biome-tinted grass crown included. Press a swatch to see the full window:

| | | | |
|:---:|:---:|:---:|:---:|
| [![Grass](docs/backdrops/tex/grass.png)](docs/backdrops/grass.png) | [![Dirt](docs/backdrops/tex/dirt.png)](docs/backdrops/dirt.png) | [![Stone](docs/backdrops/tex/stone.png)](docs/backdrops/stone.png) | [![Cobblestone](docs/backdrops/tex/cobblestone.png)](docs/backdrops/cobblestone.png) |
| [![Mossy Cobble](docs/backdrops/tex/mossyCobblestone.png)](docs/backdrops/mossyCobblestone.png) | [![Oak Planks](docs/backdrops/tex/planks.png)](docs/backdrops/planks.png) | [![Dark Oak](docs/backdrops/tex/darkOak.png)](docs/backdrops/darkOak.png) | [![Sandstone](docs/backdrops/tex/sandstone.png)](docs/backdrops/sandstone.png) |
| [![Netherrack](docs/backdrops/tex/netherrack.png)](docs/backdrops/netherrack.png) | [![End Stone](docs/backdrops/tex/endstone.png)](docs/backdrops/endstone.png) | [![Deepslate](docs/backdrops/tex/deepslate.png)](docs/backdrops/deepslate.png) | [![Sculk](docs/backdrops/tex/sculk.png)](docs/backdrops/sculk.png) |
| [![Amethyst](docs/backdrops/tex/amethyst.png)](docs/backdrops/amethyst.png) | [![Tuff](docs/backdrops/tex/tuff.png)](docs/backdrops/tuff.png) | [![Copper](docs/backdrops/tex/copper.png)](docs/backdrops/copper.png) | [![Obsidian](docs/backdrops/tex/obsidian.png)](docs/backdrops/obsidian.png) |

</details>

<details>
<summary>see it move — the fold + the backdrop carousel</summary>

![The fold](hero.gif)

*the fold: backdrop pixels dissolve one by one into true transparency — no slides, no black box*

![Backdrops](backdrops.gif)

</details>

<details>
<summary>more info</summary>

## run

    git clone https://github.com/Jasonilization/blocky.git
    cd blocky
    ./Scripts/setup.sh        # brew + java + Rosetta + Blocky.app
    open Blocky.app

or build directly: `./Scripts/bundle.sh release` (Command Line Tools are enough — no Xcode needed). `./Scripts/dmg.sh` builds the drag-to-Applications installer.

## what's inside

- offline launch — no accounts, no telemetry; standard offline UUID (`UUID.nameUUIDFromBytes`-exact)
- picks up every version in `~/Library/Application Support/minecraft`, fetches missing ones (client + libraries + assets, sha1-verified) straight from Mojang
- auto Java detection (`java_home`, Homebrew openjdk, system JVMs) and the flags the game actually needs on macOS — `-XstartOnFirstThread` first among them; MoltenVK runs in low-latency IMMEDIATE present mode
- **mods**: Fabric / NeoForge profiles launch through `inheritsFrom` merging — drop `.jar`s in `mods/`, shader packs in `shaderpacks/`; both folders open straight from Settings
- pixel-dissolve fold-out panel: settings (heap slider, Java, backdrops, snapshots, game dir), version manager (sizes + delete), and a live log terminal with a focus mode
- version management with on-disk footprints and two-tap confirmed deletion; dual-launch protection
- idle cost: 0.0% CPU, ~42 MB, no timers, no polling (water backdrop ticks only while visible)

## for developers

    ./Scripts/swift-build.sh   # SDK pinning handled for CLT-only machines
    ./Scripts/swift-test.sh    # 25 tests / 9 suites

MIT — see [LICENSE](LICENSE). Made by [Jasonilization](https://github.com/Jasonilization).

</details>
