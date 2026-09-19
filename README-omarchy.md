# CS8409 Apple Audio — Omarchy / Arch Linux

Dieses Dokument ergänzt die Haupt-README. Es beschreibt, was auf **Omarchy**
(Arch-basiert, Kernel `linux-omarchy`) anders ist als unter Ubuntu, wie man
prüft, dass der Treiber wirklich arbeitet, und wie man die Struktur-Layouts
gegen einen neuen Kernel abgleicht.

Getestet auf: iMac18,3, Cirrus CS8409, Omarchy, Kernel **7.2.5-3-omarchy**.
Ton läuft dort nachweislich über die internen Lautsprecher.

## Warum der Kernel-Treiber auf Apple nicht reicht

Der Kernel bringt `snd_hda_codec_cs8409` mit, der Fixup deckt aber nur
Dell-Hardware ab. Nachgemessen: im Kernel-Modul
(`kernel/sound/hda/codecs/cirrus/snd-hda-codec-cs8409.ko.zst`) findet sich
**keine einzige** Codestelle für den Apple-Pfad, im Projektmodul 21.

Konsequenz auf Apple: `snd_hda_pick_fixup` findet keinen Fixup, der Codec
fällt auf den generischen Parser zurück. Im Kernel-Log steht dann:

    snd_hda_intel: Primary patch_cs8409 NOT FOUND trying APPLE
    snd_hda_codec_cs8409 hdaudioC0D0: autoconfig for CS8409: line_outs=2 ... type:speaker

Die zweite Zeile kommt auch mit dem Projektmodul, denn der Apple-Pfad ruft den
Autoparser ebenfalls auf. Sie ist **kein** Fehlerzeichen.

Wichtig für die Erwartungshaltung: die Lautsprecher-Pins (0x24, 0x25) sind im
BIOS bereits als `[Fixed] Speaker` hinterlegt, deshalb kommt auch mit dem
generischen Parser Ton heraus. Das Projektmodul ist trotzdem nötig, weil es
den Verstärker (MAX98706, Vendor-Knoten 0x47) über I²C initialisiert und den
CS42L83-Untercodec anbindet. Erkennbar ist das am Namen der PipeWire-Senke:
sie heißt mit dem Projektmodul `CS8409/CS42L83 Analog`.

## Was auf Arch anders ist als im Ubuntu-Installationspfad

| Ubuntu                        | Omarchy / Arch                                      |
|-------------------------------|-----------------------------------------------------|
| `apt install linux-headers-…` | `pacman -S linux-omarchy-headers` (meist schon da)   |
| Module unkomprimiert          | Kernel-Module liegen als `.ko.zst`                   |
| `kernel/sound/pci/hda/`       | `kernel/sound/hda/codecs/cirrus/`                    |
| `/lib` eigenes Verzeichnis    | `/lib` ist ein Symlink auf `/usr/lib`                |
| DKMS aus den Ubuntu-Quellen   | `dkms` liegt in `extra`, muss zuerst installiert werden |

Das Projektmodul landet in `updates/` und hat dort Vorrang vor dem
Kernel-Modul: `/usr/lib/modules/<kernel>/updates/`.

## Installation

```bash
sudo bash install-omarchy.sh     # bauen, prüfen, einspielen
sudo reboot                      # der Codec-Treiber wird beim Start gebunden
bash verify-omarchy.sh           # messen statt behaupten
```

`install-omarchy.sh` prüft Header und Werkzeuge, baut, vergleicht die
`vermagic` mit dem laufenden Kernel, installiert nach `updates/`, läuft
`depmod` und belegt am Ende, dass die Modulauflösung wirklich auf das
Projektmodul zeigt. Bricht es irgendwo ab, wird nichts eingespielt.

Rückgängig machen:

```bash
sudo bash install-omarchy.sh --rollback
sudo reboot
```

Es wurde nichts am Kernel-Modul verändert, nur eine Datei in `updates/`
entfernt. Danach gilt wieder der Kernel-Treiber.

## Woran man erkennt, dass es läuft — und woran nicht

`verify-omarchy.sh` prüft fünf Dinge, alle belegbar. Zwei naheliegende
Kriterien sind **unbrauchbar**; sie haben bei der Entwicklung dieses Dokuments
zu einer falschen Fehlermeldung geführt und sind hier festgehalten, damit sie
niemand erneut benutzt:

- ❌ **„`Patching for CS8409 Apple` im Kernel-Log"** — diese Ausgabe läuft über
  `myprintk`, ein Debug-Makro, das im Normalbuild wegkompiliert wird (siehe
  die Build-Flags im Makefile: kein `MYSOUNDDEBUGFULL`). Fehlt im Log, obwohl
  der Pfad läuft.
- ❌ **Speaker-/Headphone-Regler im Mixer** — die legt der Apple-Pfad gar nicht
  an; die entsprechenden `snd_hda_gen_add_kctl`-Aufrufe sind im Quelltext
  auskommentiert. Ein Mixer ohne diese Regler ist kein Fehler.

✅ Was stattdessen gemessen wird:

| # | Kriterium                                              | gemessener Wert                     |
|---|--------------------------------------------------------|-------------------------------------|
| 1 | `modinfo -n` zeigt auf `updates/`                      | `/…/updates/snd-hda-codec-cs8409.ko` |
| 2 | `srcversion` im Speicher == die der Datei in `updates/` | `E4FC97F118467811117610C`           |
| 3 | Logmarke `NOT FOUND trying APPLE` vorhanden            | vorhanden                           |
| 4 | PipeWire-Senke nennt `CS8409/CS42L83`                  | `CS8409/CS42L83 Analog`             |
| 5 | PCM-Strom während eines Tons                           | `state RUNNING`, `hw_ptr` steigend  |

Kriterium 2 ist der scharfe Test: die `srcversion` wird aus dem Modulcode
berechnet. Stimmen Speicher und Datei überein, läuft wirklich dieser Build und
nicht der Kernel-Treiber. Kriterium 3 ist zulässig, weil die Zeichenkette im
Kernel-Modul nicht existiert (siehe oben: 0 Treffer).

Kriterium 5 ist der funktionale Beweis: das Skript spielt einen 440-Hz-Ton und
liest zweimal `hw_ptr` aus `/proc/asound/card0/pcm0p/sub0/status`. Läuft der
Wert weiter, erreichen die Daten die Hardware. Beim Bau dieses Dokuments
gemessen: `78124 -> 122388` bei `state RUNNING`.

Gesamtbild auf einem funktionierenden System: **8 bestanden, 0 fehlgeschlagen**.

## Die Struktur-Layouts prüfen (`tools/check-abi.py`)

Das ist der wichtigste Punkt für die Zukunft.

Dieses Projekt kann die internen HDA-Header nicht aus dem Header-Paket nehmen,
weil Arch sie dort nicht mitliefert (`sound/hda/` fehlt in
`linux-omarchy-headers`). Deshalb liegen Kopien im Repo. Weicht eine Struktur
vom Zielkernel ab, **kompiliert alles weiter** — und zerstört zur Laufzeit
still den Speicher. Genau so entstand der ABI-28-Bug, und aus demselben Grund
bricht das Modul bei Kernel-Updates gelegentlich.

Deshalb wird nicht geraten, sondern gemessen. Der laufende Kernel liefert BTF
pro Modul (`/sys/kernel/btf/<modul>`, siehe `CONFIG_DEBUG_INFO_BTF`). Werkzeug
dafür ist `pahole` (`pacman -S pahole`).

```bash
python3 tools/check-abi.py
```

Das Skript liest die echten Größen und Mitglieds-Offsets aus dem BTF, erzeugt
daraus `_Static_assert`-Prüfungen gegen die lokalen Header und kompiliert sie.
Es prüft **jedes einzelne Mitglied**, nicht nur die Gesamtgröße — eine
Umordnung bei gleicher Größe würde sonst durchrutschen.

Ergebnis auf 7.2.5-3-omarchy:

    24 mit dem Kernel geteilte Strukturen, 210 Einzelzusicherungen
    207 bestehen
    1 abweichend: cea_sad (bekannt, harmlos)

Streng geprüft wird nur, was das Projekt mit dem **Kernel** teilt. Treibereigene
Strukturen (`cs8409_spec`, `sub_codec`, `hda_coef`, …) werden lediglich
aufgelistet (`--list`), nicht zugesichert: sie existieren ausschließlich im
cs8409-Modul. Ist das Projektmodul geladen, stammt ihr Bodentruth aus dem
eigenen Code — der Vergleich belegt dann nichts. Vorher wurden sie mitgeprüft;
dadurch schwankten die Zahlen je nachdem, welches cs8409-Modul gerade lief
(28 Strukturen / 243 Zusicherungen mit dem Kernel-Treiber, 31 / 297 mit dem
Projektmodul).

Die eine Abweichung:

- **`cea_sad`** — veraltete ELD-Deklaration in `hda_local.h`. Der Kernel hat
  den Typ inzwischen nach `drm/drm_edid.h` verschoben und dort völlig anders
  definiert (4 Byte: `format`, `channels`, `freq`, `byte2`). Im Projektheader
  steht noch die alte, aufgeblähte Fassung. Der Treiber ruft davon nichts auf,
  die Deklaration ist tot. Harmlos, aber bei Gelegenheit aufräumen.

Alle mit dem Kernel **geteilten** Strukturen stimmen exakt, unter anderem:
`hda_gen_spec` (6000 Byte), `hda_multi_out` (104 Byte, `share_spdif_kctl` auf
Offset 96), `hda_codec` (1688), `hda_bus` (1408), `auto_pin_cfg` (368),
`hda_pcm` (240), `hda_input_mux` (1300), `nid_path` (60).

Meldet das Skript eine **unerwartete** Abweichung, ist das Modul so nicht
einzusetzen: den betroffenen Header an den Zielkernel anpassen und erneut
prüfen. Exit-Code 1, damit es sich in Skripte einhängen lässt.

## Nach einem Kernel-Update

Derzeit muss nach jedem Kernel-Update mit passenden Headern neu gebaut werden:

```bash
sudo bash install-omarchy.sh
sudo reboot
```

Dauerhaft löst das ein DKMS-Paket (`dkms` in `extra`), das sich beim
Kernelwechsel automatisch neu übersetzt. Steht noch aus.

## Beobachtungen, die noch offen sind

- Der Mixer hat mit dem Projektmodul drei Regler (`PCM`, `Internal Mic`,
  `Internal Mic Boost`), mit dem Kernel-Treiber waren es vier (zusätzlich
  `Mic`). Das ist kein Fehler, aber noch nicht bewertet — die Aufnahme über
  das eingebaute Mikrofon sollte bei Gelegenheit gegengehört werden.
- Das Modul ist nicht signiert und markiert den Kernel als „tainted"
  (`module verification failed`). Das ist bei Out-of-Tree-Modulen normal,
  Secure Boot wäre damit aber nicht möglich.

## Was es sonst zu wissen gibt

- Nur das Codec-Modul wird ersetzt, nicht das Soundsystem. Kein Eingriff an
  PipeWire/WirePlumber, kein GRUB-Parameter, kein `modprobe.d`.
- Auf Systemen ohne Polkit-Agenten kann `sudo` nicht durch `pkexec` ersetzt
  werden. Omarchy liefert keinen mit; `extra/hyprpolkitagent` nachinstallieren,
  sonst fragt kein Programm auf dem Desktop nach Rechten.
