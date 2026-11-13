# Blocky

opensource minecraft launcher for mac. one window, no account, offline.

**[Blocky 1.3.0](https://github.com/Jasonilization/blocky/releases/tag/v1.3.0)** — download `Blocky-1.3.0-macOS.dmg`, open it, drag Blocky to Applications. First launch is right-click → Open. The build is ad-hoc signed, not notarized. macOS 13+.

The first run checks the game folder, your versions, Homebrew, and Java, and installs the two that usually break: Homebrew (one administrator approval) and `openjdk@N`. Rerun it any time from Settings → Setup.

Tap a server and the game joins it as soon as it opens, on 1.20 and newer (including 26.x). Drop a `.jar` on the window and it lands in `mods/`. A `.zip` lands in `shaderpacks/`.

<img src="https://img.shields.io/badge/price-free-34C759?style=flat-square" alt="Free">

![Blocky](screenshot.png)

<details>
<summary>backdrops — the block faces the window tiles</summary>

Sixteen faces, the same art as the swatches below, tiled upright across the whole window. Press a swatch to see it full size:

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

*the fold: backdrop pixels dissolve one by one — no slides, no black box*

![Backdrops](backdrops.gif)

</details>

<details>
<summary>more info</summary>

## play

Pick a username and a version. Missing versions are fetched from Mojang (client, libraries, assets, sha1-checked). Fabric and NeoForge profiles launch through `inheritsFrom`.

Sessions are offline on purpose: no account, no telemetry, the standard offline UUID, byte-exact with Java's `nameUUIDFromBytes`.

## servers

These are the ones that accept an offline username. Blocky pings each with a real Server List Ping, so the tile shows players, latency, and the MOTD. Tap one, or type an address under **see all**.

On 1.20+, snapshots from 23w13a, and 26.x, Minecraft joins that server as the title screen appears (`--quickPlayMultiplayer`). Older versions open at the menu with the server saved at the top of the multiplayer list.

| Server | Address | What it is |
| --- | --- | --- |
| MineBerry | `mc.mineberry.org` | Skyblock, Survival, Towny |
| Herobrine.org | `herobrine.org` | The classic cracked server |
| BlocksMC | `blocksmc.com` | SkyBlock and EggWars |
| PvP Legacy | `play.pvplegacy.net` | Factions and SkyBlock |
| OPBlocks | `mc.opblocks.com` | OP survival and skyblock |

## mods

Drop a `.jar` on the window. It is copied into `mods/`. Drop a shader pack `.zip` and it goes to `shaderpacks/`. Settings → Folders still opens either folder.

## what's inside

- Java is picked for the version (`java_home`, Homebrew openjdk, or a runtime you pin). The game gets `-XstartOnFirstThread` and MoltenVK in IMMEDIATE present mode.
- Heap slider, backdrop picker, snapshots toggle, custom game directory.
- Version list with on-disk size and two-tap delete. A second launch is blocked while a game is already running.
- The side panel folds out. The backdrop is the block face you picked, one continuous tile, no seam down the middle.

## from source

    git clone https://github.com/Jasonilization/blocky.git
    cd blocky
    ./Scripts/setup.sh
    open Blocky.app

Command Line Tools are enough. `./Scripts/bundle.sh release` builds the app. `./Scripts/dmg.sh` rebuilds the installer. `./Scripts/swift-test.sh` runs the tests.

MIT — see [LICENSE](LICENSE). Made by [Jasonilization](https://github.com/Jasonilization). Partially vibe coded.

</details>
