#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-omarchy.sh — Cirrus CS8409 Apple Audio für Omarchy / Arch Linux
#
# Hardware : Apple iMac18,3 mit Cirrus Logic CS8409
# Kernel   : linux-omarchy 7.2.5-3 (Arch-Pakete, nicht Ubuntu)
#
# Was anders ist als unter Ubuntu:
#   * Kernel-Header kommen aus linux-omarchy-headers (pacman), nicht apt
#   * Module liegen komprimiert: kernel/sound/hda/codecs/cirrus/*.ko.zst
#   * /lib ist ein Symlink auf /usr/lib
#   * Es gibt keine DKMS-Pakete von Haus aus -> dieses Skript baut direkt
#
# Aufruf:
#   sudo bash install-omarchy.sh              # bauen + installieren
#   sudo bash install-omarchy.sh --rollback   # wieder entfernen
# ---------------------------------------------------------------------------
set -euo pipefail

GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
log()  { echo "${GRN}[ok]${NC}   $*"; }
warn() { echo "${YEL}[!]${NC}    $*"; }
err()  { echo "${RED}[fehler]${NC} $*"; }

KVER="$(uname -r)"
KDIR="/lib/modules/${KVER}"
BUILD="${KDIR}/build"
UPDATES="${KDIR}/updates"
MOD="snd-hda-codec-cs8409"
STOCK="${KDIR}/kernel/sound/hda/codecs/cirrus/${MOD}.ko.zst"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo
echo "======================================================"
echo " CS8409 Apple Audio — Installation für Omarchy"
echo " Kernel: ${KVER}"
echo "======================================================"
echo

[[ "$(id -u)" == "0" ]] || { err "Bitte als root ausführen:  sudo bash $0"; exit 1; }

# ------------------------------------------------------------------ Rollback
if [[ "${1:-}" == "--rollback" ]]; then
    log "Entferne das eigene Modul aus ${UPDATES}"
    rm -f "${UPDATES}/${MOD}.ko"
    depmod -a "${KVER}"
    log "Jetzt gilt wieder das Kernel-Modul:"
    modinfo -n "${MOD}" || true
    echo
    warn "Damit der Original-Treiber wieder greift: neu starten."
    exit 0
fi

# --------------------------------------------------------- 1. Voraussetzungen
if [[ ! -d "${BUILD}" ]]; then
    err "Kernel-Header fehlen für ${KVER}."
    echo "     sudo pacman -S linux-omarchy-headers"
    exit 1
fi
log "Kernel-Header vorhanden: ${BUILD}"

for cmd in gcc make ld; do
    command -v "$cmd" >/dev/null || { err "Werkzeug fehlt: $cmd (pacman -S base-devel)"; exit 1; }
done
log "Werkzeuge vorhanden (gcc/make/ld)"

[[ -f "${STOCK}" ]] && log "Original-Modul gefunden: ${STOCK}" \
                   || warn "Original-Modul nicht unter dem erwarteten Pfad — prüfen mit: modinfo -n ${MOD}"

# --------------------------------------------------------------------- 2. Bau
cd "${SRC}"
log "Baue Modul gegen ${KVER} ..."
make KVER="${KVER}" clean >/dev/null 2>&1 || true
if ! make KVER="${KVER}" >/tmp/cs8409-build.log 2>&1; then
    err "Build fehlgeschlagen. Protokoll: /tmp/cs8409-build.log"
    tail -20 /tmp/cs8409-build.log
    exit 1
fi
[[ -f "${MOD}.ko" ]] || { err "Build lieferte kein ${MOD}.ko"; exit 1; }
log "Build erfolgreich: ${MOD}.ko ($(stat -c%s "${MOD}.ko") Byte)"

# ------------------------------------------- 3. Vermagic gegen den Kernel prüfen
VM_MOD="$(modinfo -F vermagic "${MOD}.ko")"
if [[ "${VM_MOD}" != "${KVER}"* ]]; then
    err "vermagic passt nicht: Modul='${VM_MOD}' Kernel='${KVER}'"
    exit 1
fi
log "vermagic passt: ${VM_MOD}"

# --------------------------------------------------------------- 4. Installieren
mkdir -p "${UPDATES}"
install -m 644 "${MOD}.ko" "${UPDATES}/${MOD}.ko"
log "Installiert nach ${UPDATES}/${MOD}.ko"

depmod -a "${KVER}"
log "depmod gelaufen"

RESOLVED="$(modinfo -n "${MOD}")"
if [[ "${RESOLVED}" == "${UPDATES}/${MOD}.ko" ]]; then
    log "Modulauflösung zeigt jetzt auf unser Modul:"
    echo "        ${RESOLVED}"
else
    err "Auflösung zeigt NICHT auf unser Modul, sondern auf:"
    echo "        ${RESOLVED}"
    echo "     Prüfen: depmod -a ${KVER}  und  ls ${UPDATES}/"
    exit 1
fi

# ---------------------------------------------------------------- 5. Hinweise
echo
echo "======================================================"
log "Installation fertig."
echo "======================================================"
echo
warn "Das Modul ist geladen erst nach einem Neustart aktiv, weil es"
warn "den bereits geladenen Codec-Treiber ersetzen muss."
echo
echo "  1) Neu starten:            sudo reboot"
echo "  2) Danach prüfen:          bash ${SRC}/verify-omarchy.sh"
echo
echo "Rückgängig machen jederzeit mit:"
echo "        sudo bash ${SRC}/install-omarchy.sh --rollback"
echo
