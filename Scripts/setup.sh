#!/bin/bash
# Blocky dependency setup — one pass, no Xcode required.
#   ./Scripts/setup.sh          # everything below
# Installs/verifies: Homebrew, Java 25 (Temurin) + legacy JDKs for old
# versions, Rosetta 2 (for pre-1.17 natives on Apple Silicon), and builds
# the Blocky.app bundle. Skips whatever is already satisfied.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

green() { printf "\033[32m✓\033[0m %s\n" "$1"; }
dim()   { printf "  %s\n" "$1"; }
need()  { printf "\033[33m→\033[0m %s\n" "$1"; }

echo "==> Blocky setup"

# ── 1. Homebrew ────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
    need "Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
else
    green "Homebrew present"
fi

# ── 2. Rosetta 2 (old x86_64 natives on Apple Silicon) ─────────
if [ "$(uname -m)" = "arm64" ]; then
    if /usr/bin/pgrep -q oahd >/dev/null 2>&1 || [ -d /Library/Apple/usr/share/rosetta ]; then
        green "Rosetta 2 present"
    else
        need "Rosetta 2 (for Minecraft ≤ 1.12 natives)"
        softwareupdate --install-rosetta --agree-to-license
    fi
fi

# ── 3. Java runtimes ───────────────────────────────────────────
# 26.x needs Java 25; 1.18–1.20.5 needs 17; older builds want 8.
install_openjdk() {
    local formula="$1" label="$2"
    if brew list --formula "$formula" >/dev/null 2>&1; then
        green "$label present"
    else
        need "$label"
        brew install --quiet "$formula"
    fi
    # Make brew JDKs visible to /usr/libexec/java_home (Blocky finds either way)
    local keg opt
    keg="$(brew --prefix)/opt/$formula/libexec/openjdk.jdk"
    opt="/Library/Java/JavaVirtualMachines/$formula.jdk"
    if [ -d "$keg" ] && [ ! -e "$opt" ]; then
        sudo ln -sfn "$keg" "$opt" 2>/dev/null && dim "linked $formula into /Library/Java/JavaVirtualMachines" || true
    fi
}

install_openjdk openjdk@25 "Java 25 (Minecraft 26.x)"
install_openjdk openjdk@17 "Java 17 (Minecraft 1.18–1.20.5)"
install_openjdk openjdk@8  "Java 8 (Minecraft ≤ 1.16)"

# ── 4. Build the app ───────────────────────────────────────────
echo "==> Building Blocky.app"
"$ROOT_DIR/Scripts/bundle.sh" release

green "setup complete — open $ROOT_DIR/Blocky.app"
dim "Java in use: $(/usr/libexec/java_home -v 25 2>/dev/null || echo 'restart terminal first')"
