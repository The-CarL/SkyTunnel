#!/usr/bin/env bash
# SkyTunnel client dependency installer
# Installs iodine, hans, and chisel client binaries.
# Supports macOS (Homebrew + source builds) and Linux (apt, dnf, pacman).

set -euo pipefail

CHISEL_VERSION="1.11.5"
HANS_VERSION="1.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

check_cmd() { command -v "$1" &>/dev/null; }

# Find a command even if it's in a non-standard PATH location (e.g., brew sbin)
find_cmd() {
    command -v "$1" 2>/dev/null && return 0
    # Homebrew on macOS may install to sbin (for tools needing root)
    local brew_sbin
    if check_cmd brew; then
        brew_sbin="$(brew --prefix)/sbin"
        [[ -x "$brew_sbin/$1" ]] && echo "$brew_sbin/$1" && return 0
    fi
    return 1
}

OS="$(uname -s)"
ARCH="$(uname -m)"
NJOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"

# Determine install prefix — /usr/local/bin works on both macOS and Linux
INSTALL_BIN="/usr/local/bin"

case "$ARCH" in
    x86_64)  CHISEL_ARCH="amd64" ;;
    aarch64|arm64) CHISEL_ARCH="arm64" ;;
    *) die "Unsupported architecture: $ARCH" ;;
esac

# --- Detect package manager ---
detect_pkg_manager() {
    if check_cmd brew; then
        PKG="brew"
    elif check_cmd apt-get; then
        PKG="apt"
    elif check_cmd dnf; then
        PKG="dnf"
    elif check_cmd pacman; then
        PKG="pacman"
    else
        PKG="none"
    fi
}

# --- Ensure build tools exist (macOS) ---
ensure_macos_build_tools() {
    if [[ "$OS" != "Darwin" ]]; then return; fi
    if ! xcode-select -p &>/dev/null; then
        info "Installing Xcode Command Line Tools (required for compiling)..."
        xcode-select --install
        die "Xcode CLI tools are installing. Re-run this script after installation completes."
    fi
}

# --- Install iodine ---
install_iodine() {
    local found
    if found=$(find_cmd iodine); then
        info "iodine already installed: $found"
        return 0
    fi

    info "Installing iodine..."
    case "$OS" in
        Darwin)
            if check_cmd brew; then
                brew install iodine
                # Homebrew installs iodine to sbin; ensure it's in PATH
                local brew_sbin
                brew_sbin="$(brew --prefix)/sbin"
                if [[ -x "$brew_sbin/iodine" ]] && ! check_cmd iodine; then
                    warn "iodine installed to $brew_sbin (not in PATH)"
                    warn "Add to your shell profile: export PATH=\"$brew_sbin:\$PATH\""
                fi
            else
                build_iodine
            fi
            ;;
        Linux)
            case "$PKG" in
                apt)    sudo apt-get update && sudo apt-get install -y iodine ;;
                dnf)    sudo dnf install -y iodine 2>/dev/null || build_iodine ;;
                pacman) sudo pacman -S --noconfirm iodine ;;
                *)      build_iodine ;;
            esac
            ;;
        *)
            die "Unsupported OS: $OS"
            ;;
    esac
}

build_iodine() {
    ensure_macos_build_tools
    info "Building iodine from source..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cd "$tmpdir"
    git clone --depth 1 https://github.com/yarrick/iodine.git
    cd iodine
    make -j"$NJOBS"
    sudo make install
    cd /
    rm -rf "$tmpdir"
    info "iodine built and installed"
}

# --- Install hans ---
install_hans() {
    local found
    if found=$(find_cmd hans); then
        info "hans already installed: $found"
        return 0
    fi

    ensure_macos_build_tools
    info "Building hans v${HANS_VERSION} from source..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cd "$tmpdir"
    curl -sSL "https://github.com/friedrich/hans/archive/refs/tags/v${HANS_VERSION}.tar.gz" | tar xz
    cd "hans-${HANS_VERSION}"
    make -j"$NJOBS"
    sudo mkdir -p "$INSTALL_BIN"
    sudo install -m 755 hans "$INSTALL_BIN/hans"
    cd /
    rm -rf "$tmpdir"
    info "hans v${HANS_VERSION} installed to $INSTALL_BIN/hans"
}

# --- Install chisel ---
install_chisel() {
    local found
    if found=$(find_cmd chisel); then
        info "chisel already installed: $found"
        return 0
    fi

    local os_lower
    case "$OS" in
        Darwin) os_lower="darwin" ;;
        Linux)  os_lower="linux" ;;
        *)      die "Unsupported OS: $OS" ;;
    esac

    info "Installing chisel v${CHISEL_VERSION}..."
    local url="https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_${os_lower}_${CHISEL_ARCH}.gz"
    local tmpfile
    tmpfile=$(mktemp)
    curl -sSL "$url" | gunzip > "$tmpfile"
    chmod 755 "$tmpfile"
    sudo mkdir -p "$INSTALL_BIN"
    sudo mv "$tmpfile" "$INSTALL_BIN/chisel"
    info "chisel v${CHISEL_VERSION} installed to $INSTALL_BIN/chisel"
}

# ============================================================
# Main
# ============================================================

echo -e "${BOLD}SkyTunnel Client Dependency Installer${NC}"
echo ""
echo "OS: $OS ($ARCH)"

detect_pkg_manager
echo "Package manager: $PKG"
echo ""

install_iodine
echo ""
install_hans
echo ""
install_chisel
echo ""

# --- Verify ---
echo -e "${BOLD}Verification:${NC}"
ALL_OK=true
for cmd in iodine hans chisel; do
    path=$(find_cmd "$cmd" || true)
    if [[ -n "$path" ]]; then
        echo -e "  ${GREEN}OK${NC}  $cmd ($path)"
    else
        echo -e "  ${RED}FAIL${NC}  $cmd not found in PATH"
        ALL_OK=false
    fi
done
echo ""

# Remind about PATH if brew sbin isn't included
if check_cmd brew; then
    BREW_SBIN="$(brew --prefix)/sbin"
    if [[ -d "$BREW_SBIN" ]] && ! echo "$PATH" | grep -q "$BREW_SBIN"; then
        warn "Homebrew sbin not in PATH. Some tools (e.g., iodine) install there."
        echo -e "  Add to your shell profile: ${BOLD}export PATH=\"$BREW_SBIN:\$PATH\"${NC}"
        echo ""
    fi
fi

if $ALL_OK; then
    info "Done. Run 'skytunnel-client connect auto' to connect."
else
    warn "Some tools were not found. Check the output above."
fi
