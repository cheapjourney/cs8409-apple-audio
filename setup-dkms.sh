#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-dkms.sh — CS8409-Apple-Audio als DKMS-Paket einrichten (Omarchy/Arch)
#
# Warum: das Modul passt nur zum Kernel, gegen den es gebaut wurde. Ohne DKMS
# ist nach jedem Kernel-Update ein manueller Neubau fällig. Mit DKMS baut der
# Kernel-Update-Vorgang das Modul selbst neu.
#
# Aufruf:
#   sudo pacman -S --needed dkms          # einmalig, falls dkms fehlt
#   sudo bash setup-dkms.sh               # einrichten
#   sudo bash setup-dkms.sh --remove      # wieder abbauen
#
# Danach neu starten:  sudo reboot
# ---------------------------------------------------------------------------
set -euo pipefail

GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
log()  { echo "${GRN}[ok]${NC}   $*"; }
warn() { echo "${YEL}[!]${NC}    $*"; }
err()  { echo "${RED}[fehler]${NC} $*"; }

PKG="cs8409-apple-audio"
VER="1.0"
MOD="snd-hda-codec-cs8409"
KVER="$(uname -r)"
KDIR="/lib/modules/${KVER}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/usr/src/${PKG}-${VER}"

echo
echo "======================================================"
echo " CS8409 Apple Audio — DKMS einrichten"
echo " Kernel: ${KVER}"
echo "======================================================"
echo

[[ "$(id -u)" == "0" ]] || { err "Bitte als root ausführen:  sudo bash $0"; exit 1; }

# --------------------------------------------------------------- Abbau
if [[ "${1:-}" == "--remove" ]]; then
    if dkms status "${PKG}/${VER}" 2>/dev/null | grep -q .; then
        dkms remove -m "$PKG" -v "$VER" --all
        log "DKMS-Paket entfernt"
    else
        warn "Kein DKMS-Paket ${PKG}/${VER} registriert"
    fi
    depmod -a "$KVER"
    log "Jetzt gilt wieder:"
    modinfo -n "$MOD" || true
    echo
    warn "Damit der Kernel-Treiber greift: neu starten."
    exit 0
fi

# ----------------------------------------------- 1. Voraussetzungen
command -v dkms >/dev/null || {
    err "dkms fehlt.  Einmalig:  pacman -S --needed dkms"
    exit 1
}
log "dkms vorhanden: $(dkms --version 2>/dev/null | head -1)"

[[ -d "${KDIR}/build" ]] || {
    err "Kernel-Header fehlen für ${KVER}.  pacman -S linux-omarchy-headers"
    exit 1
}
log "Kernel-Header vorhanden"

for cmd in gcc make rsync; do
    command -v "$cmd" >/dev/null || { err "Werkzeug fehlt: $cmd"; exit 1; }
done
log "Werkzeuge vorhanden (gcc/make/rsync)"

# ---------------------------------- 2. Manuell installiertes Modul abgeben
# DKMS legt das Modul an derselben Stelle in updates/ ab. Läge dort zusätzlich
# noch die von Hand kopierte Datei, wären zwei identische Module im Suchpfad.
MANUAL="${KDIR}/updates/${MOD}.ko"
if [[ -f "$MANUAL" ]]; then
    rm -f "$MANUAL"
    log "Manuell installiertes Modul entfernt (DKMS übernimmt diesen Platz)"
fi

# ------------------------------------------------- 3. Quellen bereitstellen
install -d "$DEST"
rsync -a --delete \
      --exclude '.git' --exclude '__pycache__' \
      --exclude '*.ko' --exclude '*.o' --exclude '*.mod' --exclude '*.mod.c' \
      --exclude '*.cmd' --exclude '.*.cmd' --exclude 'modules.order' \
      --exclude 'Module.symvers' --exclude '.tmp_versions' --exclude '.module-common.o' \
      "${SRC}/" "${DEST}/"
log "Quellen kopiert nach ${DEST}"

if [[ ! -f "${DEST}/dkms.conf" ]]; then
    err "${DEST}/dkms.conf fehlt — ohne die kann DKMS nichts bauen."
    exit 1
fi
log "dkms.conf vorhanden"

# --------------------------------------------------------- 4. Registrieren
if dkms status "${PKG}/${VER}" 2>/dev/null | grep -q .; then
    dkms remove -m "$PKG" -v "$VER" --all >/dev/null 2>&1 || true
    log "Alte Registrierung entfernt"
fi

dkms add -m "$PKG" -v "$VER"
log "Bei DKMS registriert"

# --------------------------------------------------------------- 5. Bauen
log "Baue für ${KVER} ..."
if ! dkms build -m "$PKG" -v "$VER" -k "$KVER" >/tmp/cs8409-dkms-build.log 2>&1; then
    err "dkms build fehlgeschlagen. Protokoll: /tmp/cs8409-dkms-build.log"
    tail -25 /tmp/cs8409-dkms-build.log
    exit 1
fi
log "Build erfolgreich"

dkms install -m "$PKG" -v "$VER" -k "$KVER"
log "Installiert"

depmod -a "$KVER"

# ---------------------------------------------------------------- 6. Beleg
RESOLVED="$(modinfo -n "$MOD")"
echo
echo "   Auflösung: ${RESOLVED}"
case "$RESOLVED" in
    */updates/*) log "Modul liegt in updates/ — es gewinnt gegen den Kernel-Treiber" ;;
    *)           err "Auflösung zeigt NICHT auf updates/ — depmod prüfen"; exit 1 ;;
esac

dkms status "${PKG}/${VER}"

echo
echo "======================================================"
log "DKMS ist eingerichtet."
echo "======================================================"
echo
echo "  Neu starten:        sudo reboot"
echo "  Prüfen:             bash ${SRC}/verify-omarchy.sh"
echo "  Nach Kernel-Update: passiert automatisch (Kernel-Header vorausgesetzt)"
echo "  Rückgängig:         sudo bash ${SRC}/setup-dkms.sh --remove && sudo reboot"
echo
