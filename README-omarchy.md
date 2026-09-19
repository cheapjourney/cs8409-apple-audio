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
| 6 | Pegel einer 4-s-Aufnahme vom internen Mikrofon         | RMS deutlich über -80 dBFS          |

Kriterium 2 ist der scharfe Test: die `srcversion` wird aus dem Modulcode
berechnet. Stimmen Speicher und Datei überein, läuft wirklich dieser Build und
nicht der Kernel-Treiber. Kriterium 3 ist zulässig, weil die Zeichenkette im
Kernel-Modul nicht existiert (siehe oben: 0 Treffer).

Kriterium 5 ist der funktionale Beweis: das Skript spielt einen 440-Hz-Ton und
liest zweimal `hw_ptr` aus `/proc/asound/card0/pcm0p/sub0/status`. Läuft der
Wert weiter, erreichen die Daten die Hardware. Beim Bau dieses Dokuments
gemessen: `78124 -> 122388` bei `state RUNNING`.

Gesamtbild auf einem funktionierenden System: **9 bestanden, 0 fehlgeschlagen**.

## Mikrofon (internes Mikrofon)

Das interne Mikrofon war der zweite Fehler und lag nicht an der Hardware.

**Symptom:** Eine Aufnahme liefert absolute Stille. Über PipeWire kommt eine
Datei voller Nullsamples heraus (`-999 dBFS`), direkt an der Hardware bricht
`arecord` mit `Input/output error` ab. Der Mixer hat keinen `Mic`-Regler.

**Ursache:** In `patch_cirrus_apple.h` steht der gesamte Aufbau der
Aufnahmesteuerung zwischen

    #if LINUX_VERSION_CODE < KERNEL_VERSION(5, 13, 0)
        ... cs_8409_apple_parse_capture_source ...
        ... cs_8409_apple_create_input_ctls ...
    #endif

und die Aufrufstelle ruft im `#else`-Zweig (also ab Kernel 5.13, damit auch
7.2.5) **nichts** auf. Die Eingänge wurden auf modernen Kernels schlicht nie
eingerichtet.

Zusätzlich fehlte die Korrektur der ADC-Liste. `check_dyn_adc_switch` in
`hda_generic.c` soll die `adc_nids`-Liste auf die tatsächlich verbundenen ADCs
zusammenziehen, tut das aber nicht: es nimmt eine Null-terminierte Liste an,
während der 8409 einen zufälligen Non-Null-Eintrag in einer ansonsten leeren
Liste hat. Der Aufnahmestrom landete dadurch auf einem falschen ADC.

**Lösung:** Übernommen aus
[davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro),
Datei `patch_cirrus/cirrus_apple.h`:

- neue `cs_8409_apple_create_input_ctls`, die die ADC-Liste korrekt
  zusammenzieht (die alte bleibt als `_old` für Kernel < 5.13 erhalten)
- Aufruf im `>= 5.13`-Zweig
- `spec->gen.suppress_auto_mic = 1` aktiviert

**Beleg, dass es greift:** Die neue Funktion protokolliert mit `printk` (nicht
mit dem Debug-Makro `myprintk`) und ist deshalb im Kernel-Log sichtbar:

    snd_hda_intel: hda_generic_check_dyn_adc_switch shrinking

Dazu kehrt der `Mic`-Regler in den Mixer zurück, und die Messung liefert Signal:

| Messung                          | RMS       | Spitze    | Ergebnis        |
|----------------------------------|-----------|-----------|-----------------|
| vorher (max. Verstärkung)        | -17,0 dBFS | -0,0 dBFS | Signal, klirrt  |
| nach Justierung, ruhiger Raum    | -37,7 dBFS | -22,9 dBFS | Signal, sauber  |

⚠ **Den Aufnahmepegel nicht mit `amixer` einstellen.** Der Wert `-0,0 dBFS` ist
Vollaussteuerung, also klirrende Aufnahme — und genau das ist der Zustand direkt
nach der Installation: WirePlumber setzt beim ersten Initialisieren des Geräts den
kompletten Aufnahmepfad auf Maximum (`Internal Mic Capture` 100 % / +12 dB **und**
`Internal Mic Boost` 2 / +20 dB). Nachgemessen: nach `systemctl --user restart
wireplumber` standen die Regler wieder auf Maximum — solange der Soundserver noch
keinen eigenen Wert für das Gerät hat.

`amixer`-Werte sind bei laufendem WirePlumber also nur ein **Abbild**, keine
Einstellung. Der richtige Weg ist der Soundserver selbst:

```bash
wpctl status                # im Abschnitt Sources die ID der Analog-Quelle
wpctl set-volume <id> 0.3
```

WirePlumber bildet das auf die Hardware ab und räumt dabei den Boost auf 0:

| Zustand                          | Capture        | Boost      |
|----------------------------------|----------------|------------|
| ohne eigenen Wert (Vorgabe)      | 100 % / +12 dB | 2 / +20 dB |
| nach `wpctl set-volume <id> 0.4` | 94 % / +8 dB   | 0 / 0 dB   |
| nach `wpctl set-volume <id> 0.3` | 81 % / 0 dB    | 0 / 0 dB   |

**Der Wert bleibt.** Nach einem erneuten Neustart des Dienstes kam er unverändert
zurück (0,30), die Hardware blieb auf 81 % / 0 dB. Das Maximum ist also nur ein
Erstzustand. Dasselbe bewirkt der Lautstärkeregler des Desktops.

⚠ Kalibrieren lässt sich der Pegel nur in ruhiger Umgebung: ist es laut, erreicht
die Spitze auch bei kleinerem Hardware-Pegel die Vollskala — das sagt dann nichts
über Klirren aus (gemessen: Spitze -1,4 dBFS bei 94 %, aber -0,4 dBFS bei 81 %).
Faustregel: Spitze unter etwa -6 dBFS.

**Nicht behoben:** Aufnahme über ein Headset-Mikrofon. Dafür gibt es den offenen
Pull Request
[#197](https://github.com/davidjo/snd_hda_macbookpro/pull/197).

## Pegel kalibrieren (Wiedergabe und Aufnahme)

Auf Omarchy steuert **WirePlumber** beide Richtungen und bildet die Lautstärke auf
die Hardware-Regler ab. Gemessen (Kernel 7.2.5-3) mit einem Tonträger von 1 kHz /
-18 dBFS, aufgenommen über das interne Mikrofon:

Wiedergabe — Sink-Lautstärke → ALSA-Regler → gemessener Schallpegel:

| Sink (`wpctl`)  | ALSA `PCM`      | Mikrofon RMS | Mikrofon Spitze |
|-----------------|-----------------|--------------|-----------------|
| 0,4             | 53 % / -23,8 dB | -33,2 dBFS   | -28,4 dBFS      |
| 0,6             | 74 % / -13,2 dB | -22,6 dBFS   | -18,5 dBFS      |
| 0,8             | 89 % /  -5,8 dB | -15,2 dBFS   | -11,9 dBFS      |
| 1,0             | 100 % /   0,0 dB |  -9,6 dBFS   |  -6,4 dBFS      |

**1,0 ist der richtige Ruhewert**, denn dann greift keine Absenkung. Stand der Sink
auf 0,4, fehlen gegenüber Vollaussteuerung 23,8 dB — das klingt „leise", ist aber
kein Treiberproblem, sondern eine Einstellung.

Aufnahme — Quelle auf 0,3:

| Größe                  | Wert            |
|------------------------|-----------------|
| `Internal Mic Capture` | 81 % / 0,00 dB  |
| `Internal Mic Boost`   | 0 / 0,00 dB     |

Das ist die Einstellung **ohne Zusatzverstärkung**. Beide Werte bleiben erhalten:
nach `systemctl --user restart wireplumber` kamen Sink 1,00 und Quelle 0,30
unverändert zurück.

### Gleichzeitige Wiedergabe und Aufnahme

Geprüft, weil es für Anrufe entscheidend ist: **funktioniert.**

| Versuch                                        | Ergebnis                  |
|------------------------------------------------|---------------------------|
| Aufnahme allein über PipeWire                  | 131.116 Byte              |
| Aufnahme **während** Wiedergabe über PipeWire  | 196.652 Byte              |
| Aufnahme während Wiedergabe direkt `hw:0,0`    | `Device or resource busy` |
| Zustand beider Ströme danach                   | `pcm0p`/`pcm0c` RUNNING   |

Das „busy" ist kein Defekt: PipeWire hält das Gerät. Direktzugriff klappt nur,
wenn die Nutzerdienste vorher gestoppt sind.

### ⚠ Eine zu kurze Aufnahme sieht aus wie der alte Treiberfehler

`parecord` braucht rund eine Sekunde, bis der Strom wirklich Daten liefert. Wird
das Messfenster zu kurz gewählt (`timeout 1.5`), entsteht eine **44-Byte-Datei** —
genau das Bild, das weiter oben den defekten Aufnahmepfad kennzeichnete.
Nachgemessen: mit 1,5 s kam nichts, mit 3 s kamen 131 KB. **Vor dem Urteil
„Treiber kaputt" also immer mit mindestens 3 Sekunden messen.** Zu unterscheiden
ist das am direkten Hardware-Zugriff: `arecord -D hw:0,0` liefert bei intaktem
Treiber Daten, während PipeWire noch gar nichts schreibt.

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

Zwei Wege. **Empfohlen ist DKMS — danach ist nichts mehr zu tun.**

```bash
sudo pacman -S --needed dkms      # einmalig
sudo bash setup-dkms.sh
sudo reboot
```

`setup-dkms.sh` kopiert die Quellen nach `/usr/src/cs8409-apple-audio-1.0/`,
registriert sie bei DKMS, baut für den laufenden Kernel und belegt am Ende, dass
die Modulauflösung wirklich auf `updates/` zeigt. Bei Kernel-Updates übersetzt
DKMS das Modul selbst neu; Voraussetzung sind die passenden Kernel-Header, die
`linux-omarchy-headers` mitbringt. Rückgängig: `sudo bash setup-dkms.sh --remove`.

⚠ Das Skript entfernt dabei das von Hand installierte Modul aus `updates/`, damit
dort nicht zwei identische Module im Suchpfad liegen. Ab dann gehört die Datei
DKMS — also **nicht** mehr `install-omarchy.sh --rollback` benutzen.

Alternativ ohne DKMS, nach jedem Kernelwechsel von Hand:

```bash
sudo bash install-omarchy.sh
sudo reboot
```

## Beobachtungen, die noch offen sind

- Der Mixer hat jetzt vier Regler (`PCM`, `Mic`, `Internal Mic`,
  `Internal Mic Boost`). Vor dem Mikrofon-Fix fehlte `Mic` — das war dasselbe
  Symptom und ist damit erklärt, kein eigener Fehler.
- Headset-Mikrofon: nicht behoben, siehe Abschnitt „Mikrofon".
- Das Modul ist nicht signiert und markiert den Kernel als „tainted"
  (`module verification failed`). Das ist bei Out-of-Tree-Modulen normal,
  Secure Boot wäre damit aber nicht möglich.

## Was es sonst zu wissen gibt

- Nur das Codec-Modul wird ersetzt, nicht das Soundsystem. Kein Eingriff an
  PipeWire/WirePlumber, kein GRUB-Parameter, kein `modprobe.d`.
- Auf Systemen ohne Polkit-Agenten kann `sudo` nicht durch `pkexec` ersetzt
  werden. Omarchy liefert keinen mit; `extra/hyprpolkitagent` nachinstallieren,
  sonst fragt kein Programm auf dem Desktop nach Rechten.
