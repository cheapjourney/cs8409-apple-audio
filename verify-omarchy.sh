#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-omarchy.sh — prüft, ob der CS8409-Apple-Treiber wirklich arbeitet.
#
# Läuft als normaler Nutzer (kein root nötig).
#
# Alle Kriterien sind belegbar, nicht behauptet. Zwei frühere Kriterien waren
# unbrauchbar und wurden ersetzt — siehe README-omarchy.md, Abschnitt
# "Woran man erkennt, dass es läuft":
#
#   * "Patching for CS8409 Apple" im Kernel-Log  -> läuft über myprintk, ein
#     Debug-Makro, das im Normalbuild verschwindet. Unbrauchbar.
#   * Speaker-/Headphone-Regler im Mixer         -> die legt der Apple-Pfad
#     gar nicht an (im Quelltext auskommentiert). Unbrauchbar.
#
# Jetzt geprüft:
#   1. Herkunft des Moduls
#   2. Ob wirklich UNSER Modul im Speicher liegt (srcversion-Vergleich)
#   3. Ob der Apple-Pfad genommen wurde (Logmarke, die nur unser Modul kennt)
#   4. Ob der CS42L83-Untercodec angebunden ist
#   5. Ob ein Ton tatsächlich bis zur Hardware durchläuft (hw_ptr)
#   6. Ob das interne Mikrofon Signal liefert (4 s Aufnahme, Pegel gemessen)
# ---------------------------------------------------------------------------
set -uo pipefail

GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
MOD="snd-hda-codec-cs8409"
MODU="snd_hda_codec_cs8409"
KVER="$(uname -r)"
pass=0; fail=0

ja() { [[ "$1" == "$2" ]] && { echo "  OK    $3"; pass=$((pass+1)); } \
                          || { echo "  ${RED}FEHL${NC}  $3 (ist: $2)"; fail=$((fail+1)); }; }
# Hinweis ohne Wirkung auf das Ergebnis (zaehlt weder als bestanden noch als Fehler)
warn() { echo "  ${YEL}HINWEIS${NC} $*"; }

echo
echo "======================================================"
echo " CS8409 Apple Audio — Prüfung"
echo " Kernel: ${KVER}"
echo "======================================================"
echo

# ------------------------------------------------------ 1. Herkunft des Moduls
echo "1) Herkunft"
RESOLVED="$(modinfo -n "$MOD" 2>/dev/null)"
echo "   aufgelöst auf: ${RESOLVED:-nichts gefunden}"
# Der Pfad darf nicht fest verdrahtet werden: von Hand installiert liegt das
# Modul unter updates/, per DKMS unter updates/dkms/ und dann zstd-komprimiert
# als .ko.zst. Beides ist richtig.
ja updates "$([[ "$RESOLVED" == *"/updates/"* ]] && echo updates || echo kernel)" \
   "Modul kommt aus updates/, nicht aus dem Kernelbaum"

# ------------------------------------------- 2. Liegt UNSER Modul im Speicher?
echo
echo "2) Ist der laufende Treiber wirklich unser Build?"
LIVE_SRC="$(cat /sys/module/${MODU}/srcversion 2>/dev/null)"
FILE_SRC="$(modinfo -F srcversion "$RESOLVED" 2>/dev/null)"
echo "   im Speicher : ${LIVE_SRC:-nicht geladen}"
echo "   in der Datei: ${FILE_SRC:-keine Datei}"
ja ja "$([[ -n "$LIVE_SRC" ]] && echo ja || echo nein)" "Modul ist geladen"
ja file "$([[ -n "$LIVE_SRC" && "$LIVE_SRC" == "$FILE_SRC" ]] && echo file || echo anders)" \
   "identisch mit der aufgelösten Moduldatei (nicht der Kernel-Treiber)"

# --------------------------------------------- 3. Wurde der Apple-Pfad genommen?
echo
echo "3) Apple-Pfad im Kernel-Log"
# Diese Zeile stammt aus unserem Quelltext (printk, nicht Debug-Makro).
# Im Kernel-Treiber existiert der Apple-Zweig überhaupt nicht.
NO_APPLE=0
STOCK="$(modinfo -n "$MOD" 2>/dev/null)"
if [[ -f /usr/lib/modules/${KVER}/kernel/sound/hda/codecs/cirrus/${MOD}.ko.zst ]]; then
    NO_APPLE="$(zstd -dc "/usr/lib/modules/${KVER}/kernel/sound/hda/codecs/cirrus/${MOD}.ko.zst" 2>/dev/null \
                | strings | grep -ciE 'trying APPLE|cs_8409_apple')"
    echo "   Apple-Code im Kernel-Treiber: ${NO_APPLE} Treffer (0 = er hat keinen)"
fi
APPLED="$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -c 'Primary patch_cs8409 NOT FOUND trying APPLE')"
ja 1 "$APPLED" "Logmarke 'NOT FOUND trying APPLE' vorhanden (nur unser Modul kennt sie)"
if [[ "$APPLED" -gt 0 ]]; then
    journalctl -k -b 0 --no-pager 2>/dev/null \
      | grep 'Primary patch_cs8409 NOT FOUND trying APPLE' | tail -1 | sed 's/^/   /'
fi

# ------------------------------------------------ 4. CS42L83-Untercodec dran?
echo
echo "4) CS42L83-Untercodec"
SINKNAME="$(pactl list sinks 2>/dev/null | grep -m1 -iE 'CS8409.*Analog' )"
if [[ -n "$SINKNAME" ]]; then
    echo "   ${SINKNAME##*: }" | sed 's/^ *//' | sed 's/^/   /'
    ja ja "$(echo "$SINKNAME" | grep -qi 'CS42L83' && echo ja || echo nein)" \
       "Senke nennt CS8409/CS42L83 (Apple-Pfad bindet den Untercodec an)"
else
    ja ja nein "Senke nennt CS8409/CS42L83"
fi

# ---------------------------------------- 5. Läuft ein Ton bis zur Hardware?
echo
echo "5) Tonweg: läuft der PCM-Strom wirklich zur Hardware?"
CARD="$(aplay -l 2>/dev/null | awk '/CS8409/{gsub(":","",$2); print $2; exit}')"
if [[ -z "$CARD" ]]; then
    ja ja nein "Analogkarte mit CS8409 gefunden"
else
    ja ja ja "Analogkarte gefunden (card ${CARD})"
    PCM="/proc/asound/card${CARD}/pcm0p/sub0/status"
    command -v speaker-test >/dev/null 2>&1 || echo "   (speaker-test fehlt: pacman -S alsa-utils)"
    if command -v speaker-test >/dev/null 2>&1; then
        speaker-test -t sine -f 440 -c 2 -l 6 >/dev/null 2>&1 &
        ST_PID=$!
        sleep 2
        S1="$(awk '/^state:/{print $2}' "$PCM" 2>/dev/null)"
        P1="$(awk '/^hw_ptr/{print $3}' "$PCM" 2>/dev/null)"
        sleep 1
        P2="$(awk '/^hw_ptr/{print $3}' "$PCM" 2>/dev/null)"
        kill "$ST_PID" 2>/dev/null; wait "$ST_PID" 2>/dev/null
        echo "   Zustand während des Tons: ${S1:-unbekannt}"
        echo "   hw_ptr: ${P1:-?} -> ${P2:-?}"
        ja RUNNING "$S1" "PCM-Strom war aktiv (state RUNNING)"
        ja steigend "$([[ -n "$P1" && -n "$P2" && "$P2" -gt "$P1" ]] && echo steigend || echo steht)" \
           "hw_ptr ist weitergelaufen (Daten erreichen die Hardware)"
    fi
fi

echo
echo "6) Mikrofon (internes Mikrofon, 4 s Aufnahme)"
if command -v parecord >/dev/null 2>&1; then
    PEGEL_TOOL="$(dirname "${BASH_SOURCE[0]}")/tools/wav-level.py"
    rm -f /tmp/mikrofon-pruefung.wav
    timeout -s INT 4 parecord --format=s16le --rate=48000 --channels=1 \
            /tmp/mikrofon-pruefung.wav >/dev/null 2>&1
    if [[ -s /tmp/mikrofon-pruefung.wav && -f "$PEGEL_TOOL" ]]; then
        python3 "$PEGEL_TOOL" /tmp/mikrofon-pruefung.wav | sed 's/^/   /'
        PEGEL="$(python3 "$PEGEL_TOOL" /tmp/mikrofon-pruefung.wav 2>/dev/null \
                 | awk '/RMS/{print $3}')"
        SPITZE="$(python3 "$PEGEL_TOOL" /tmp/mikrofon-pruefung.wav 2>/dev/null \
                 | awk '/Spitze/{print $3}')"
        if awk -v p="${PEGEL:--999}" 'BEGIN{exit !(p > -80)}'; then
            ja ja ja "Mikrofon liefert Signal (ueber -80 dBFS)"
        else
            ja ja nein "Mikrofon liefert Signal (ueber -80 dBFS)"
        fi
        # Hinweis, keine Pruefung: Wand-nahe Spitze heisst Vollaussteuerung.
        if awk -v s="${SPITZE:--999}" 'BEGIN{exit !(s > -1.0)}'; then
            warn "Spitze ${SPITZE} dBFS = Vollaussteuerung, die Aufnahme klirrt."
            warn "Pegel ueber den Soundserver setzen:  wpctl status  ->  wpctl set-volume <id> 0.4"
            warn "(amixer-Werte werden von WirePlumber wieder ueberschrieben)"
        fi
        rm -f /tmp/mikrofon-pruefung.wav
    else
        ja ja nein "Aufnahme konnte erzeugt werden"
    fi
else
    echo "   parecord nicht vorhanden — Aufnahme nicht pruefbar"
fi

echo
echo "======================================================"
printf ' Ergebnis: %d bestanden, %d fehlgeschlagen\n' "$pass" "$fail"
echo "======================================================"
if [[ "$fail" -eq 0 ]]; then
    echo " Der Apple-Treiber ist aktiv und Ton läuft bis zur Hardware."
else
    echo " Offene Punkte siehe oben. Nach einer Änderung neu starten."
fi
echo
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
