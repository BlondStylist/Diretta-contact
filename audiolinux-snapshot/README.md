# AudioLinux-Snapshot (Host + Target)

Nur lesend. Ausgabe: `/root/config-archiv/snapshot-<host>-<label>-<zeit>.tar.gz` (+ Kopie in `/home/audiolinux/snapshots/`).

```bash
sudo bash snapshot.sh pre-update          # vor dem Update, auf Host UND Target, ohne Wiedergabe
sudo bash snapshot.sh post-update         # nach Update + Reboot + Diretta-Neuinstallation
bash compare.sh vorher.tar.gz nachher.tar.gz            # Unterschiede
sudo bash restore.sh vorher.tar.gz /pfad/datei          # Trockenlauf; DRY_RUN=0 zum Schreiben
```

`restore.sh` lehnt `/opt/scripts`, `/usr`, `/lib`, `/var/lib/pacman` ab (Menü-/Paketcode nie zurückspielen).
Der Snapshot enthält IPs, Seriennummer und Sudo-Regeln, aber keine privaten SSH-Schlüssel. Nicht öffentlich ablegen.
