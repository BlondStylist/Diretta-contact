# Messwerkzeuge Pi 5 (Erdung A/B, EXT5V-Logger)

| Datei | Version | Zweck |
|---|---|---|
| `erdung/diretta-erdung.sh` | 1.2 | blockrandomisierte A/B-Messung Erdungskabel (PMIC-Rails, Drossel, Temp, ALSA, Netz, Kernel-Log) |
| `erdung/erdung-auswertung.py` | 1.2 | Auswertung: Vorzeichen-Permutationstest, exaktes Inversions-KI, TOST, Holm |
| `ext5v/ext5v_install.sh` | 2.1 | legt EXT5V-Logger (C), Lauf-Skript und Statistik an, baut und testet sie |

## Reihenfolge auf dem Pi
```
./diretta-erdung.sh selbsttest              # erwartet: 37 ok, 0 Fehler
python3 erdung-auswertung.py --selbsttest   # erwartet: 28 ok, 0 Fehler
sudo ./diretta-erdung.sh probe 30           # echte Hardware: Aufrufdauer, Wiederholrate, Journal lesbar?
bash ext5v_install.sh                       # Selbsttest + E2E-Test + Probe (Exit 0 nur bei 20/20 gueltigen Lesungen)
```
Vorher den DC/AC-Strom im Erdungskabel messen (siehe Audit, Abschnitt 5): < 1 mA DC → PMIC-Effekt physikalisch ausgeschlossen.

## Gegenüber dem Audit-Stand (v1.1 / v2.0) korrigiert und verifiziert
**erdung-auswertung.py 1.2**
- **KI-Fehler behoben:** Die Bisektion über den zweiseitigen p(μ) war falsch, weil p(μ) nicht monoton ist. In 18 von 40 Zufallsfällen wich der Annahmebereich vom ausgegebenen KI ab. Neu: exakte Konstruktion nach Hartigan (Ordnungsstatistiken der Teilmengen-Mittel). Geprüft gegen Brute-Force-Enumeration (Abweichung 0), Konvexität auf einem 3001-Punkte-Gitter, Überdeckung 94,95 % (Soll 95 %, 2000 Simulationen). Etwa 40-mal schneller.
- Befund „EFFEKT < SESOI (irrelevant)“, wenn der Unterschied signifikant ist, das 90 %-KI aber innerhalb der SESOI liegt.
- `P_PMIC_W` wird nur aus vollständigen Zeilen berechnet (vorher Teilsummen bei fehlenden Schienen).
- Tests P25–P28 neu. Mutationstests: Jede eingebaute Verfälschung wird erkannt.

**diretta-erdung.sh 1.2**
- Timeout für `vcgencmd` (`ERD_VCG_TIMEOUT`, Standard 5 s): Hängt die Mailbox, wird die Probe als Fehlprobe gezählt, statt den Lauf zu blockieren.
- Prüfung auf Bash ≥ 5 (EPOCHREALTIME).
- T23 prüft jetzt die tatsächliche Zahl der Fehleingaben (der Mutant „Limit 500“ blieb vorher unentdeckt). Neue Tests T36 und T37.
- Ende-zu-Ende über `main` mit simulierter Hardware: Pinning, flock (zweite Instanz → Exit 3), de_DE-Locale. Unter de_DE ist das Komma in `$EPOCHREALTIME` real belegt (`1791118965,088757`) und wird korrekt behandelt.

**ext5v_install.sh 2.1**
- C: Schreibfehler werden der Reihe nach geprüft. Vorher lief `rename` auch nach einem fehlgeschlagenen `fclose` (bitweises `|`), und eine defekte CSV konnte unter dem Zielnamen landen.
- C: `EXT5V_SCHED=other` (SCHED_OTHER, nice 19) als Alternative, falls SCHED_IDLE verhungert. `--probe` endet nur bei 20/20 gültigen Lesungen mit Exit 0.
- Statistik: Das Drossel-Gate scheiterte bisher an Sticky-Bits seit dem Boot (z. B. `0x50000`). Jetzt wird nur aktive Drosselung oder ein **neues** Sticky-Bit als FAIL gewertet.
- Statistik: LSB-Schätzung über den häufigsten Schritt. 1,34 mV ist durch öffentliche Ausgaben belegt (5,06788 V = 3782 × 1,34 mV).
- `meta.txt` enthält `hz=`, `dur=` usw. als eigene Zeilen; das alte Format wird weiter erkannt. Prüfung `SEKUNDEN ≥ 1`, `LC_ALL=C`.
- Neuer End-to-End-Test im Installer: echter Logger-Code, nur der Mailbox-Transport ist simuliert. Geprüft werden Rate, Mittelwert, Firmware-Fehlertext, SIGINT-Sicherung, Parameterprüfung, Scheduling und Referenzlauf.

## Nur auf echter Hardware prüfbar
`/dev/vcio`-ioctl, Aktualisierungsrate und Caching von `pmic_read_adc`, ALSA-Kartenname der Diretta-Karte, Wirkung von nice 19 bzw. SCHED_IDLE unter PREEMPT_RT. `probe` bzw. `--probe` messen das; die Selbsttests decken nur die Logik ab.
