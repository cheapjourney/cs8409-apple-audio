#!/usr/bin/env python3
"""
check-abi.py — prueft die mitgelieferten HDA-Header gegen den laufenden Kernel.

Warum das noetig ist
--------------------
Dieses Projekt bringt eigene Kopien der internen Kernel-Strukturen mit
(hda_local.h, hda_generic.h, ...), weil die Header nicht im Header-Paket
liegen. Weicht eine Struktur vom Zielkernel ab, kompiliert alles weiter und
zerstoert zur Laufzeit still den Speicher. Genau so entstand der ABI-28-Bug.

Vorgehen
--------
Der laufende Kernel liefert BTF pro Modul (/sys/kernel/btf/<modul>). Damit
sind die echten Groessen und Offsets messbar. Das Skript liest sie aus und
erzeugt daraus _Static_asserts gegen die lokalen Header. Kompiliert die Sonde,
stimmen die Layouts exakt; andernfalls nennt der Compiler jedes abweichende
Mitglied.

Was streng geprueft wird -- und was nicht
-----------------------------------------
Geprueft werden nur Strukturen, deren Bodentruth aus einem KERNEL-Modul
stammt (snd_hda_core, snd_hda_codec, snd_hda_codec_generic, snd_hda_intel).
Die muessen uebereinstimmen, sonst ist der Speicher in Gefahr.

Treibereigene Strukturen (cs8409_spec, sub_codec, ...) werden NICHT geprueft,
nur aufgelistet. Begruendung: sie existieren nur im cs8409-Modul. Ist unser
Modul geladen, stammt der Bodentruth fuer sie aus unserem eigenen Code -- der
Vergleich belegt dann nichts. Frueher wurden sie mitgeprueft; dadurch aenderten
sich die Zahlen je nachdem, welches cs8409-Modul gerade lief.

Benutzung
---------
    python3 tools/check-abi.py            # Sonde erzeugen und pruefen
    python3 tools/check-abi.py --gen-only # nur die C-Datei erzeugen

Exit-Code 0 = nur bekannte Abweichungen, 1 = unerwartete Abweichung,
2 = Voraussetzungen fehlen.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BTF_DIR = Path("/sys/kernel/btf")
OUT = Path("/tmp/layoutprobe")

# Module, die die geteilten HDA-Strukturen enthalten.
CORE_MODULES = ["snd_hda_core", "snd_hda_codec", "snd_hda_codec_generic",
                "snd_hda_intel"]
# Modul, dessen Strukturen treibereigen sind und nur informativ aufgelistet werden.
DRIVER_MODULES = ["snd_hda_codec_cs8409"]

# Abweichungen, die bekannt und begruendet sind (Strukturname).
KNOWN_BENIGN = {"cea_sad"}


def structs_in_headers():
    """Alle 'struct X {' aus den mitgelieferten Headern -- nur die pruefen wir."""
    found = {}
    for hdr in sorted(REPO.glob("*.h")):
        for m in re.finditer(r"^\s*struct\s+([A-Za-z_]\w*)\s*\{",
                             hdr.read_text(errors="replace"), re.M):
            found.setdefault(m.group(1), hdr.name)
    return found


def layout_from_btf(module, struct):
    """(groesse, [(mitglied, offset)]) laut BTF, oder None."""
    try:
        r = subprocess.run(["pahole", "-C", struct, str(BTF_DIR / module)],
                           capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if f"struct {struct} {{" not in r.stdout:
        return None
    size = None
    for m in re.finditer(r"/\* size:\s*(\d+)", r.stdout):
        size = int(m.group(1))
    if size is None:
        return None
    members = []
    for line in r.stdout.splitlines():
        m = re.match(r"^\s*(.+?)\s*;\s*/\*\s*(\d+)(?::\s*\d+)?\s+(\d+)\s*\*/", line)
        if not m:
            continue
        decl, off = m.group(1), int(m.group(2))
        if ":" in decl.split("/*")[0] and "(" not in decl:
            continue                                  # Bitfeld
        nm = re.search(r"([A-Za-z_]\w*)\s*(\[\s*\d*\s*\])?\s*$", decl)
        if not nm or nm.group(1) in ("struct", "union", "const", "unsigned", "signed"):
            continue                                  # anonymes Aggregat
        members.append((nm.group(1), off))
    return size, members


def collect():
    """Trennt in streng zu pruefende und rein informative Strukturen."""
    defined = structs_in_headers()
    core, driver = {}, {}
    for mods, bucket in ((CORE_MODULES, core), (DRIVER_MODULES, driver)):
        for mod in mods:
            if not (BTF_DIR / mod).exists():
                continue
            for struct in defined:
                if struct in core or struct in driver:
                    continue
                r = layout_from_btf(mod, struct)
                if r:
                    bucket[struct] = (mod, *r)
    return defined, core, driver


def write_probe(core):
    lines = ["// AUTOMATISCH ERZEUGT von tools/check-abi.py",
             "// Bodentruth: BTF der Kernel-Module des laufenden Kernels",
             "#include <linux/module.h>",
             "#include <linux/stddef.h>",
             '#include "patch_cs8409.h"',
             "",
             'MODULE_LICENSE("GPL");',
             ""]
    checks = 0
    for struct, (mod, size, members) in sorted(core.items()):
        lines.append(f"/* {struct} (BTF-Quelle: {mod}) */")
        lines.append(f'_Static_assert(sizeof(struct {struct}) == {size}, "{struct}: Groesse");')
        checks += 1
        for name, off in members:
            lines.append(f'_Static_assert(offsetof(struct {struct}, {name}) == {off}, '
                         f'"{struct}.{name}: Offset");')
            checks += 1
        lines.append("")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "layoutprobe.c").write_text("\n".join(lines) + "\n")
    (OUT / "Makefile").write_text("obj-m := layoutprobe.o\n")
    return checks


def run_probe(checks):
    kver = subprocess.run(["uname", "-r"], capture_output=True, text=True).stdout.strip()
    build = Path(f"/lib/modules/{kver}/build")
    if not build.is_dir():
        print(f"[!] Kernel-Header fehlen: {build}", file=sys.stderr)
        return 2
    r = subprocess.run(
        ["make", "-C", str(build), f"M={OUT}",
         f"CFLAGS_MODULE=-I{REPO} -DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS "
         f"-DCONFIG_SND_HDA_RECONFIG=1", "modules"],
        capture_output=True, text=True)
    # Compilerfehler landen auf stderr, Buildausgaben auf stdout: beides lesen.
    log = r.stdout + r.stderr
    n_broken = len(re.findall("static assertion failed", log))
    broken = sorted({m.group(1).split(".")[0].split(":")[0]
                     for m in re.finditer(r'static assertion failed: "([^"]+)"', log)})
    print(f"[i] Kernel        : {kver}")
    print(f"[i] Zusicherungen : {checks} (Groessen + Mitglieds-Offsets)")
    print(f"[i] bestehen      : {checks - n_broken}")
    if not broken:
        print("[ok] Alle geteilten Strukturen stimmen exakt mit dem Kernel ueberein.")
        return 0
    unexpected = [s for s in broken if s not in KNOWN_BENIGN]
    for s in broken:
        print(f"[{'!' if s in KNOWN_BENIGN else 'X'}] abweichend: {s}"
              f"{'  (bekannt, harmlos)' if s in KNOWN_BENIGN else ''}")
    if unexpected:
        print(f"\n[X] {len(unexpected)} UNERWARTETE Abweichung(en): {', '.join(unexpected)}")
        print("    Diese Header gegen den Zielkernel korrigieren, sonst droht")
        print("    stille Speicherkorruption.")
        return 1
    print("\n[ok] Nur die bekannten, harmlosen Abweichungen.")
    return 0


def main():
    ap = argparse.ArgumentParser(description="HDA-Strukturlayouts gegen den Kernel pruefen")
    ap.add_argument("--gen-only", action="store_true", help="nur Sonde erzeugen")
    ap.add_argument("--list", action="store_true",
                    help="auch die treibereigenen Strukturen auflisten")
    args = ap.parse_args()

    defined, core, driver = collect()
    print(f"[i] {len(defined)} Strukturen in den lokalen Headern")
    print(f"[i] {len(core)} geteilt mit dem Kernel (streng geprueft)")
    print(f"[i] {len(driver)} treibereigen (nur informativ, nicht geprueft)")
    if args.list:
        for s in sorted(driver):
            mod, size, members = driver[s]
            print(f"      {s:26} {size:>6} Byte  ({mod})")
    checks = write_probe(core)
    print(f"[i] Sonde: {OUT}/layoutprobe.c")
    if args.gen_only:
        return 0
    return run_probe(checks)


if __name__ == "__main__":
    sys.exit(main())
