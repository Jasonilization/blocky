#!/usr/bin/env python3
"""Writes the Finder window layout for the Blocky DMG — without Finder.

Why not AppleScript: on current macOS `set background picture` is refused
outright (Finder error -10006), so every DMG built the old way shipped
plain grey with the artwork sitting unused inside .background/. This writes
the same .DS_Store records directly (bwsp window geometry, icvp icon-view
options with the background alias, Iloc icon positions), which Finder reads
exactly as if it had styled the window itself.

The record writers are vendored ds_store + mac_alias (MIT licensed — the
same libraries behind `pip install dmgbuild`). See
Scripts/dmg-vendor/MIT-ds_store-LICENSE.txt and
Scripts/dmg-vendor/MIT-mac_alias-LICENSE.txt.

Usage: dmg-layout.py <stage-dir>
"""

import datetime
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "dmg-vendor"))

from ds_store import DSStore  # noqa: E402
from mac_alias import (  # noqa: E402
    Alias,
    TargetInfo,
    VolumeInfo,
    ALIAS_FIXED_DISK,
    ALIAS_KIND_FILE,
)

# Icon slots in the 660×400 window (Finder top-left origin), matching the
# layout the dmg-background art was drawn for.
BLOCKY = (165, 180)
APPLICATIONS = (495, 180)

def _background_alias(stage: str) -> bytes:
    """Build an Alias record for .background/background.png inside the volume.

    Uses mac_alias.Alias.for_file() which creates a proper Alias record that
    Finder can resolve by volume name + posix path at mount time. Falls back
    to a hand-built record if CNID packing fails on large APFS IDs.
    """
    background_path = os.path.join(stage, ".background", "background.png")

    # Try the proper Alias.for_file() first — it builds a complete alias
    # record with volume info, CNIDs, carbon/posix paths that Finder can
    # resolve reliably.
    try:
        alias = Alias.for_file(background_path)
        return alias.to_bytes()
    except (struct.error, OSError, ValueError):
        # CNID too large for 32-bit pack or other mac_alias error — fall back
        # to a hand-built record with dummy CNIDs. Finder resolves aliases
        # primarily by volume name + posix path, so dummy CNIDs are fine.
        now = datetime.datetime.now(datetime.timezone.utc)
        volume = VolumeInfo(
            b"Blocky", now, b"H+", ALIAS_FIXED_DISK, 0, b"\0\0"
        )
        target = TargetInfo(
            ALIAS_KIND_FILE,
            b"background.png",
            1,          # folder_cnid: parent (volume root)
            1,          # cnid of the file
            now,
            b"\0\0\0\0",
            b"\0\0\0\0",
        )
        target.folder_name = b".background"
        target.posix_path = b"/.background/background.png"
        target.cnid_path = [1]
        return Alias(volume=volume, target=target).to_bytes()


def main() -> int:
    stage = os.path.abspath(sys.argv[1])
    ds_store = os.path.join(stage, ".DS_Store")

    with DSStore.open(ds_store, "w+") as store:
        # Window geometry and chrome.
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = {
            "ShowStatusBar": False,
            "WindowBounds": "{{120, 120}, {780, 520}}",
            "ContainerShowSidebar": False,
            "PreviewPaneVisibility": False,
            "SidebarWidth": 0,
            "ShowTabView": False,
            "ShowToolbar": False,
            "ShowPathbar": False,
            "ShowSidebar": False,
        }

        # Icon-view options: 96pt icons, 11pt labels, no auto-arrange, and
        # the meadow background.
        background = os.path.join(stage, ".background", "background.png")
        store["."]["icvp"] = {
            "viewOptionsVersion": 1,
            "backgroundType": 2,
            "showIconPreview": True,
            "iconSize": 96.0,
            "textSize": 11.0,
            "labelOnBottom": True,
            "gridSpacing": 100.0,
            "arrangeBy": "none",
            "backgroundImageAlias": _background_alias(stage),
        }

        # Icon positions.
        store["Blocky.app"]["Iloc"] = BLOCKY
        store["Applications"]["Iloc"] = APPLICATIONS

    print("DMG layout written (no Finder automation needed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
