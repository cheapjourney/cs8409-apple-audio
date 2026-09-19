#!/usr/bin/env python3
"""
wav-level.py — Pegel einer WAV-Datei messen (RMS und Spitze in dBFS).

Ohne externe Abhaengigkeiten; audioop gibt es in Python 3.13+ nicht mehr,
deshalb wird mit struct gerechnet.

Deutung:
    um -999 dBFS   => absolute Stille, alle Samples null. Kein Signal.
    -80..-40 dBFS  => Grundrauschen, Mikrofon liefert etwas
    ueber -40 dBFS => deutliches Signal

Benutzung:
    python3 tools/wav-level.py aufnahme.wav [weitere.wav ...]
"""
import math
import struct
import sys
import wave

STILLE = -80.0


def db(von, basis=32768.0):
    """Linearer Wert -> dBFS. 0 wird als -999 gemeldet (echte Stille)."""
    return round(20 * math.log10(von / basis), 1) if von > 0 else -999.0


def messen(pfad):
    with wave.open(pfad, "rb") as w:
        kanaele = w.getnchannels()
        breite = w.getsampwidth()
        rate = w.getframerate()
        rahmen = w.getnframes()
        roh = w.readframes(rahmen)
    if breite == 2:
        werte = struct.unpack("<%dh" % (len(roh) // 2), roh)
    elif breite == 4:
        # 32 Bit auf 16 Bit normieren, damit die dBFS vergleichbar sind
        werte = [v >> 16 for v in struct.unpack("<%di" % (len(roh) // 4), roh)]
    else:
        return None
    if not werte:
        return None
    rms = (sum(v * v for v in werte) / len(werte)) ** 0.5
    spitze = max(abs(v) for v in werte)
    return {
        "kanaele": kanaele,
        "rate": rate,
        "sekunden": round(rahmen / rate, 2),
        "rms": db(rms),
        "spitze": db(spitze),
        "veraendert": len(set(werte)) > 1,
        "basis": pfad,
    }


def hauptteil():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    ergebnis = 0
    for datei in sys.argv[1:]:
        m = messen(datei)
        if m is None:
            print(f"{datei}: nicht lesbar oder kein 16/32-Bit-WAV")
            ergebnis = 2
            continue
        print(f"{datei}")
        print(f"   {m['kanaele']} Kanal/Kanaele, {m['rate']} Hz, {m['sekunden']} s")
        print(f"   RMS    : {m['rms']:>7.1f} dBFS")
        print(f"   Spitze : {m['spitze']:>7.1f} dBFS")
        if not m["veraendert"]:
            print("   -> konstanter Wert: kein Signal")
            ergebnis = 1
        elif m["rms"] <= STILLE:
            print("   -> praktisch Stille: kein Signal vom Mikrofon")
            ergebnis = 1
        else:
            print("   -> es kommt Signal an")
    return ergebnis


if __name__ == "__main__":
    sys.exit(hauptteil())
