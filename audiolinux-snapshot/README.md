# AudioLinux-Snapshot (Host + Target)

Nur lesend (außer der Ausgabe). Läuft auf Kern 0-1 mit niedriger Priorität, damit die Audiokerne 2-3 nicht gestört werden.
Ausgabe: `/root/config-archiv/snapshot-<host>-<label>-<zeit>.tar.gz` (0600) und Kopie in `/home/audiolinux/snapshots/`.

```bash
bash snapshot.sh --check               # Vorabcheck in Sekunden: Werkzeuge und Pfade vorhanden? (ohne Root, schreibt nichts)
sudo bash snapshot.sh pre-update          # vor dem Update, auf Host UND Target, ohne Wiedergabe
sudo bash snapshot.sh post-update         # nach Update + Reboot + Diretta-Neuinstallation
bash compare.sh vorher.tar.gz nachher.tar.gz            # Exit 0 identisch, 1 Unterschiede, 2 Fehler
sudo bash restore.sh vorher.tar.gz /pfad/datei          # Trockenlauf; DRY_RUN=0 schreibt, FORCE=1 für /boot und /etc/fstab
```

- `restore.sh` lehnt `/opt/scripts`, `/usr`, `/lib`, `/var/lib/pacman` und relative/`..`-Pfade ab (Menü-/Paketcode nie zurückspielen) und sichert die aktuelle Fassung vorher.
- Der Snapshot enthält IPs, Seriennummer und Sudo-Regeln, aber keine privaten SSH-Schlüssel. Findet `snapshot.sh` mögliche Zugangsdaten in gesicherten Dateien, warnt es und listet sie in `WARNUNG-zugangsdaten.txt`. Archiv nie öffentlich ablegen.
- Berichte in `report/` werden verglichen, Messwerte in `volatile/` (Uptime, Spannung, IRQ-Zähler, Threads) nicht.

## Laptop einrichten (Ubuntu/WSL)
```bash
bash audiolinux-snapshot/laptop-setup.sh          # Schluessel, ~/.ssh/config, Freischalten auf beiden Pis, Test, Repos aktualisieren
bash audiolinux-snapshot/laptop-setup.sh --verteilen   # optional: Skripte auf die Pis kopieren + Vorabcheck (Musik aus!)
```
Es fragt nur nach Passwoertern der Pis (einmal je Geraet, ssh-copy-id) und optional einer Passphrase fuer den neuen Schluessel. Lokale Aenderungen in den Repos legt es in einen Stash (nichts geht verloren).

## Tests (nur Entwicklung, nicht auf dem Pi)
```bash
SNAPSHOT_TEST=1 bash tests/run-tests.sh [lauf2|lauf3|lauf4|all]   # als root im Container
```
Lauf 2 Snapshot/Compare, Lauf 3 Restore-Sicherheit, Lauf 4 Realitätsfälle (fehlende Tools, kein Root, zu wenig Platz, Kernbindung, Zugangsdaten).
