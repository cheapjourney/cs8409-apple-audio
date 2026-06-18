#!/usr/bin/env bash
# install.sh — Cirrus CS8409 Apple Audio Driver
# Builds and installs the kernel module for Apple Macs with Cirrus Logic CS8409.
# Tested on: iMac18,3 / iMac19,1 / MacBook Pro 2016-2019 / Ubuntu 24.04–26.04
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

echo ""
echo "======================================"
echo " Cirrus CS8409 Apple Audio Driver"
echo "======================================"
echo ""

# ── Check root ─────────────────────────────────────────────────────
if [[ "$(id -u)" != "0" ]]; then
    err "This script must be run as root (sudo)."
    echo "   sudo ./install.sh"
    exit 1
fi

# ── Check kernel headers ───────────────────────────────────────────
KVER=$(uname -r)
HEADER_DIR="/lib/modules/${KVER}/build"

if [[ ! -d "$HEADER_DIR" ]]; then
    err "Kernel headers not found for ${KVER}."
    echo "   Install with: sudo apt install linux-headers-${KVER}"
    exit 1
fi
log "Kernel headers: ${KVER}"

# ── Check build tools ──────────────────────────────────────────────
for cmd in gcc make; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Missing: $cmd"
        echo "   Install with: sudo apt install build-essential"
        exit 1
    fi
done
log "Build tools OK"

# ── Build ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log "Building module..."
make clean > /dev/null 2>&1 || true
if ! make > /dev/null 2>&1; then
    err "Build failed. See output above."
    exit 1
fi
log "Module built successfully"

# ── Install ─────────────────────────────────────────────────────────
MODULE_PATH="/lib/modules/${KVER}/updates/snd-hda-codec-cs8409.ko"

log "Installing to ${MODULE_PATH}..."
mkdir -p "$(dirname "$MODULE_PATH")"
cp snd-hda-codec-cs8409.ko "$MODULE_PATH"
depmod -a
log "Module installed"

# ── Backup stock module (optional) ──────────────────────────────────
STOCK_MODULE="/lib/modules/${KVER}/kernel/sound/pci/hda/snd-hda-codec-cs8409.ko"
if [[ -f "$STOCK_MODULE" ]] && [[ ! -f "${STOCK_MODULE}.stock" ]]; then
    cp "$STOCK_MODULE" "${STOCK_MODULE}.stock"
    log "Stock module backed up to ${STOCK_MODULE}.stock"
fi

# ── Reload ──────────────────────────────────────────────────────────
log "Reloading audio driver..."

# Remove old module stack
rmmod snd-hda-codec-cs8409 2>/dev/null || true
rmmod snd-hda-codec-generic 2>/dev/null || true
rmmod snd-hda-codec 2>/dev/null || true
sleep 1

# Reload
modprobe snd-hda-codec-cs8409 2>/dev/null || true
modprobe snd-hda-intel 2>/dev/null || true
sleep 2

# ── Verify ──────────────────────────────────────────────────────────
if lsmod | grep -q cs8409; then
    log "Module loaded: snd-hda-codec-cs8409"
else
    warn "Module may not have loaded. A reboot may be required."
    warn "Run: sudo reboot"
fi

echo ""
echo "======================================"
echo " Installation complete!"
echo "======================================"
echo ""
echo "After reboot, audio should work."
echo ""
echo "To verify:"
echo "  lsmod | grep cs8409"
echo "  aplay -l"
echo "  speaker-test -t wav -c 2"
echo ""
echo "To restore the stock driver:"
echo "  sudo cp ${STOCK_MODULE}.stock ${STOCK_MODULE}"
echo "  sudo depmod -a"
echo "  sudo reboot"
