# Übergabe an Claude auf dem Laptop (Ubuntu/WSL)

Ziel: AudioLinux-Menü- und Kernel-Update auf Diretta Host und Target, mit Snapshot davor und danach und gezieltem Zurückspielen. Ausgangslage und Entscheidungen: `docs/WISSENSSTAND-2026-10-22.md` (maßgeblich), Werkzeuge: `audiolinux-snapshot/`.

## 1. Einrichtung (einmalig, im Ubuntu-Fenster)
**Automatisch:** `bash ~/Diretta-contact/audiolinux-snapshot/laptop-setup.sh` erledigt Schlüssel, `~/.ssh/config`, Freischalten auf beiden Pis, Verbindungstest und das sichere Aktualisieren der Repos (lokale Änderungen gehen in einen Stash). Direkt am Terminal starten, nicht über Claude: es fragt nach den Passwörtern der Pis. Die folgenden Schritte zeigen, was es im Einzelnen tut.

```bash
git clone https://github.com/BlondStylist/Diretta-contact.git ~/Diretta-contact   # bzw. vorhandenen Klon nutzen
cd ~/Diretta-contact && git fetch origin && git checkout claude/audiolinux-snapshot-tools && git pull
ls audiolinux-snapshot docs                                   # snapshot.sh, compare.sh, restore.sh, README.md, tests/
```
- Claude Code im Klon als normaler Benutzer starten (`claude`), **nicht** als root und nicht mit abgeschalteter Rückfrage. Administratorrechte braucht nur `sudo` auf den Pis; das Passwort tippst du selbst.
- SSH: Schlüssel des Laptops muss in `authorized_keys` von Host und Target stehen. `~/.ssh/config`:
```
Host diretta-host
  HostName 192.168.178.75
  User audiolinux
Host diretta-target
  HostName 172.20.0.2
  User audiolinux
  ProxyJump diretta-host
```
- Die beiden Original-Images (Host, Target) auf dem Laptop prüfen und die Prüfsummen notieren: `sha256sum <image>`. Sie sind der Rückweg per SD-Karte.
- Original-Images finden und als Referenz einlesen (nur lesend): `sudo bash audiolinux-snapshot/image-snapshot.sh --suche`, dann `sudo bash audiolinux-snapshot/image-snapshot.sh PFAD host-original` (und `target-original`). Ergebnis: `~/snapshots/snapshot-image-*.tar.gz`, vergleichbar mit `compare.sh`. Ein Update ist laut Nutzer schon erfolgt (beide Pis Kernel 6.18.53-1-rpi); ein Vorher-Snapshot der Pis existiert nicht, das Original-Image ist deshalb die Vergleichsbasis.

### 1b. Prüfkette vor dem Update (empfohlen)
`audit-alles.sh` aus dem Repo `diretta-werkzeuge` (privat) vereint die Audit-Kette der Python-Werkzeuge mit den Tests dieser Snapshot-Werkzeuge und wiederholt sie in Runden, bis sie sauber ist. Es spricht nie mit den Pis; die Bash-Suite läuft in einer Wegwerf-Sandbox (Overlay-Mount), nichts bleibt im System zurück.
```bash
git clone https://github.com/BlondStylist/diretta-werkzeuge.git ~/diretta-werkzeuge     # privat: Anmeldung per gh oder SSH-Schlüssel
cd ~/diretta-werkzeuge && git fetch origin && git checkout claude/audit-alles && git pull   # bis PR #1 gemergt ist
sudo -v                                       # Passwort einmal eingeben; die Sandbox braucht sudo
./audit-alles.sh --tief --extra '~/diretta/selftest-tools.sh'   # --extra nur, wenn die alten Skripte dort liegen
```
Erwartet: Exit 0 und „ERGEBNIS: sauber“; Dauer mit `--tief` ca. 40 Minuten, ohne `--tief` ca. 10. Bericht und Logs: `~/diretta-werkzeuge/audit-berichte/<zeit>/`. Die Snapshot-Werkzeuge findet das Skript unter `~/Diretta-contact/audiolinux-snapshot`. Anleitung: `~/diretta-werkzeuge/AUDIT-ALLES.md`.

## 2. Startprompt für Claude im Ubuntu-Fenster
> Lies zuerst `docs/UEBERGABE-LAPTOP.md` und `docs/WISSENSSTAND-2026-10-22.md` im Repo. Du übernimmst die Arbeit aus der Cloud-Sitzung. Ziel: AudioLinux-Menü- und Kernel-Update auf meinem Diretta Host (192.168.178.75) und Target (172.20.0.2 über den Host), danach gilt der reine Snyder-Image-Stand. Halte dich an den Phasenplan und die Regeln in der Übergabe, arbeite in Phase 0-2 nur lesend und halte vor Phase 3 an. Sprich Deutsch, kurz und mit copy-paste-fähigen Befehlen.

## 3. Phasenplan (jede Phase endet mit Bericht, Freigabe durch den Nutzer)
- **Phase 0a, Prüfkette:** `./audit-alles.sh` (siehe 1b) einmal laufen lassen; bei Fehlern erst Ursache klären und beheben, dann weiter. Der Bericht gehört in die Übergabe.
- **Phase 0, Laptop prüfen:** Klon aktuell, Skripte vorhanden, `ssh diretta-host hostname` und `ssh diretta-target hostname` funktionieren. Sicherstellen, dass keine Musik läuft. Prüfen, dass die USB-Kette stabil ist (Target: DAC sichtbar, `vcgencmd get_throttled` = `0x0`).
- **Phase 1, Befund lesend:** Auf beiden Pis `uname -r`, Menü- und Diretta-Version, `systemctl --failed`, `setting.inf`. Erwartet laut Aufzeichnung: Stand 25.10.: Kernel 6.18.53-1-rpi, Diretta 148_21-1 (Host und Target), Host-RoonBridge 2.71.1683-1; MTU 10222; Host `setting.inf` derzeit bewusster Test mit ThredMode=17, CycleTime=1800, InfoCycle=180000 (Snyder-Original: 16 / 1500 / 150000, erst auf Zusage des Nutzers zurücksetzen).
- **Phase 1b, Vorabcheck:** `snapshot.sh` per scp auf beide Pis legen und dort `bash snapshot.sh --check` ausführen (kein Root, schreibt nichts). Fehlende Pflicht-Werkzeuge (Exit 3) zuerst klären.
- **Phase 2, Snapshot vor dem Update:** `audiolinux-snapshot/snapshot.sh` per scp auf beide Pis (ohne Wiedergabe), `sudo bash snapshot.sh pre-update` (Passwort tippt der Nutzer), Archive zurückholen nach `~/snapshots/`. Die Zeilen unter „Befehle mit Fehler“ (`fehler.txt`) auswerten und das Skript falls nötig korrigieren (mit Tests). **Stopp: Freigabe einholen.**
- **Phase 3, Update (Nutzer führt am Terminal aus, Claude begleitet):** Das AudioLinux-Menü braucht TTY und Zugangsdaten, die Claude nie bekommt. Reihenfolge nach Snyder: `menu` → INSTALL/UPDATE menu → UPDATE system → UPDATE menu → SELECT/Update kernel → Reboot. Danach Diretta über das Menü neu installieren (Host und Target). Ein Gerät nach dem anderen.
- **Phase 4, Prüfen:** `Interface=end0`, Dienste aktiv, Target-Audiokarte gewählt, Lizenz, `aplay -l` auf beiden, RoonBridge-Version (bleibt sie auf 2.60: `yay -Sy roonbridge --noconfirm`), `isolated.conf`, Realtime-Priorität, `setting.inf`, qdisc, MTU, Roon sieht Host und Target.
- **Phase 5, Vergleich und gezieltes Zurückspielen:** `snapshot.sh post-update`, `compare.sh pre post`, jede Abweichung einordnen (gewollt durch das Update oder zurückspielen). `restore.sh` immer zuerst als Trockenlauf. Keine `.pacnew` blind übernehmen.

## 4. Regeln
- Die Entscheidung gilt: nach dem Update der reine Snyder-Image-Stand, nicht das alte Profil.
- **Widerspruch zum Skill `rpi-audio-tuning`:** Dessen `nutzer-setup.md` und der Hinweis „ThredMode ist 17, nicht auf 16 korrigieren“ gelten für die alten Images. Auf den neuen Images ist ThredMode=16 korrekt; `rt-audit.sh` meldet deshalb eine Abweichung, die hier zu ignorieren ist (`EXPECT_THREDMODE=16` setzen). Die „Eigenlösungen nie entfernen“ betreffen Dienste, die auf den neuen Images nicht mehr existieren.
- Nichts schreiben ohne Freigabe; keine Paketdeinstallation; Änderungen an Netzwerk, Boot oder IRQ nur mit `deadman.sh` und einem zweiten SSH-Fenster.
- Während der Wiedergabe kein scp und keine langen ssh-Ausgaben über Host/Target; bei Messungen nicht per `journalctl -f` mitlesen.
- Passwörter, Schlüssel und Menü-Zugangsdaten nie in Dateien, Commits oder Gedächtnis-Konnektoren ablegen.
- Ergebnisse (Befunde, `fehler.txt`-Auswertung, Korrekturen) als Commits auf dem Branch `claude/audiolinux-snapshot-tools` (PR #5) festhalten und `docs/WISSENSSTAND-2026-10-22.md` fortschreiben.

## 5. Rückweg
SD-Karte des betroffenen Pis mit dem Original-Image neu schreiben (Prüfsumme vorher vergleichen). Danach ist der Zustand wie vor dem Update; die Archive aus Phase 2 bleiben als Vergleich erhalten.
