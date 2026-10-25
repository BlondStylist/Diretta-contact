# Wissensstand Diretta-Projekt (Stand 22.10.2026)

Zusammengeführt aus: Vertiso Memory, Great Arrow, Claude-Sitzungen (07.–21.10.), Firecrawl/Exa (AudioLinux-Release-Notes, Snyder-Guide, Roon-Forum), Audiophile-Style-Thread 55247 (Seiten 147–150, 17.09.–21.10.2026).
Nicht gelesen: Unabyss (Monatslimit erreicht), Notion (nicht autorisiert), Snyder-Appendix 5–10 (Web blockiert, lokal per curl holen), Scry (Thread nicht im Korpus; Seiten stattdessen über Firecrawl).
Alles Gemessene stammt aus den **alten** Images (Kernel 7.1.8-1-rpi). Die neuen Images sind es nicht mehr.

## 1. System
- Zwei Raspberry Pi 5 (AudioLinux): `diretta-host` (RoonBridge, `diretta_alsa`) und `diretta-target` (`diretta_alsa_target`). Direktverbindung `end0`: Host 172.20.0.1, Target 172.20.0.2. LAN am Host über `enu1`.
- Strecke Target → 3 kaskadierte VIA-Hubs → iFi Omni USB-Switch → Audiolab 8300CD. Roon Core 192.168.178.26, Musikspeicher ROCK (SSD).
- Host-IP: .66 → .71 (feste Fritzbox-Zuordnung, 12.09.) → **.75 (neues Image, 20.10.)**. Seit 22.10. ist **192.168.178.75** im Router fest für den Host eingetragen (bestätigt vom Nutzer).
- Target-Netzteil iFi iPower Elite 5 V/5 A. Beide Pis mit Erdungskabel (USB-A → PE über Supra DC Blocker MKII, 04.10.), Brummen am Kupfergehäuse danach weg.

## 2. Aktueller Stand: neue Images = Snyder-Original (live gelesen 13.10. und 20.10.)
| Punkt | Wert im Image |
|---|---|
| Kernel | 6.18.50-2-rpi RT (vorher 7.1.8-1-rpi RT LTO) |
| Host `setting.inf` | ThredMode=16, CycleTime=1500, InfoCycle=150000, FlexCycle=enable, CpuSend=2, CpuOther=3 |
| MTU | 10222 beidseitig; Target EtherMTU=10222, ExtEtherMTU=10236, AlsaLatency=30 |
| qdisc | cake auf `end0` beidseitig |
| Target | `purist-mode-auto` + `purist-mode-revert-on-boot`; `numa=fake=4` (Host) / `=8` (Target) |
| Sudo | `webui-restarts` des Images (u. a. `systemctl restart diretta_alsa.service`) |
| Diretta | Target-Bibliothek 148 (Log: 148_1) |

Entscheidung 21.10.: Ziel nach dem Update ist der **reine Image-Stand**, nicht das alte Profil (ThredMode 17, CycleTime 2000, MTU 9000 …). Das Skill-Dokument `nutzer-setup.md` (Stand 30.09.) ist für die neuen Images veraltet.
Offene Entscheidungen vom 13.10.: ThredMode 17 und Host-Coalescing 0/0 als A/B-Kandidaten, qdisc offen. CycleTime, MTU und Target-IRQ-Pins bleiben wie im Image.

## 3. Verbindliche Regeln und Entscheidungen (aus den Aufzeichnungen)
- Pakete nie deinstallieren; Vorschau- und Lösch-Befehle (`pacman -Rsp`) nie verketten.
- Dauerhafte Einstellungen über systemd-Units, nicht über sysctl (AudioLinux-Updates überschreiben).
- IRQ-Nummern sind flüchtig: dynamisch über `/proc/interrupts` auflösen.
- LAN-Filter/Regeneratoren nur vor dem Host, nie auf der P2P-Strecke. Kein globales IPv6-Disable.
- Während wichtigem Hören kein scp und keine langen ssh-Ausgaben über Host/Target; bei Messungen nicht per `journalctl -f` mitlesen (erzeugte nachweislich Störungen auf Kern 2).
- Alles Weitere erst nach Messung (A/B, blockrandomisiert, exakter Test). Doppelte Offline-Backups mit SHA-256.
- Diretta 148_4 galt als „interessant, nicht dringend“; inzwischen gibt es 148_12 LTS (siehe 5).
- Snyder lässt RoonBridge auf dem Target installiert. Das ersetzt die frühere Absicht, minimserver2/upmpdcli/roonbridge dort per Menü zu entfernen.
- Messgerät-Fragen (Micsig, Analog Discovery, USB-C-Messgerät) sind gestrichen.

## 4. Messbefunde (alte Images, Kernel 7.1.8)
- **Partition `isolated1.slice`** (13.09., 30 Blöcke): Kern 2 Ticks 113,7 → 1,3/s (−98,8 %), SCHED-Softirq auf 0; Mehraufwand auf Kern 0/1 (+137 % Ticks auf einem 99,6 % leeren Kern). Danach auf `member` zurückgestellt für den Hörvergleich; A/B isolated gegen member offen.
- **Störquelle Kern 2** war `journalctl -f` über das P2P-Kabel, kein Systemfehler.
- **cake** (08.10.): 643 Verwürfe stammten aus ssh/scp-Verkehr; in ungestörter Wiedergabe 0 Verwürfe bei 555,6 Frames/s.
- **Latenz** (08.10., Host, 30 min ftrace, je ≈1 Mio. Zyklen): kein Wert über 50 µs. `rtla timerlat/osnoise` nicht möglich (Kernel ohne die Tracer); Kernel-Neubau wird nicht empfohlen.
- **Spannung**: EXT5V Host 4,953–4,964 V, Target 4,981–4,996 V (Mindestwert USB 4,75 V). Unterspannung nur im Hochlauf. 20.10.: Target 5,03 V, `throttled=0x0`.
- **MTU**: 9000 bestätigt, S4 (10222 im Super Purist) ohne Nutzen und nicht durchgeführt (07.10.). Das gilt für die alten Images; die neuen laufen ohnehin mit 10222.
- **Ausfälle**: 20.10. hing der iFi Omni (Target sah keinen DAC mehr, Host keine Soundkarte). Neustart des Omni/Targets behob es. Bei Wiederholung: Omni-Netzteil und USB-Kabel prüfen.

## 5. Upstream-Wissen
**AudioLinux-Release-Notes (Raspberry), relevant für das Update**
- Menü 501 (V5.0.0): Isolated Cores und Realtime-Priorität neu konfigurieren, danach Reboot; aktive Audiodienste werden dabei automatisch deaktiviert.
- Menü 536: Kernel-Pakete (`linux-rpi*`) stehen bei System-Updates „on hold“. Menü 527: Option „Update rpi5 eeprom firmware“ (Reboot nötig).
- Menü 542: Netz-Tweaks `ethtool -C rx-usecs 0 tx-usecs 0` und `-K gro/gso/tso off` im Expert-Menü. Menü 544: `diretta-alsa-daemon-16k` bei 16k-Kernel.
- Kein System- oder Kernel-Update im ramroot-Modus. Menü 439/425/…: Hinweise zu ramroot-Fix für Pi 5.
- Menü 420: neue `setting.inf` liegt als `.pacnew` bereit und muss bewusst verglichen werden. Laut eigener Betriebsnotiz (30.09.) schrieb Menü 545 die `isolated.conf` neu (nicht in den Release-Notes verifiziert).
- Diretta immer über das Menü „Install/update last version“ neu installieren; „0) Install previous stable version“ nur für die Vorversion.

**Snyder-Guide** (validiert mit AudioLinux V5, Image 530, Menü 544)
- Update-Reihenfolge: UPDATE system → UPDATE menu → SELECT/Update kernel → Reboot. Empfehlung: entweder monatlich aktualisieren oder „lock down“ mit Backup-Image.
- Mehrere Host-Profile im Guide (Basis 800/80000, Appendix 7 u. a. 514/51400, ThredMode 16); das Image entspricht dem Jumbo-Profil (MTU 10222, CycleTime 1500 relaxed). Welches Profil wo gilt, steht in den Appendizes 5–10 und ist noch zu lesen.
- Link-Speed per `pm-set-link`: advertise 0x002 = 10 Mb (Super Purist), 0x008 = 100 Mb, 0x03f = 1000 Mb.

**Audiophile-Style-Thread 55247** (Seiten 147–150)
- 17.–18.09.: Kernel 6.18.50-2-rpi mit 16k-Jumbo-Patch; Snyder bestätigt stabil bis MTU 10222. MTU ist eine Obergrenze, kein Tuning-Parameter; bei 10-Mb/s-Strecke sind große CycleTime-Werte riskant.
- 24.09.: **Diretta 148_12 LTS** für Host und Target. Downgrade von 148_12 auf 148_1 nur über den AudioLinux-Support (Paket plus Konsolen-Anleitung).
- 25.09.: Nach System-, Kernel- und Diretta-Update sah Roon Host und Target nicht. Fix laut Entwickler: im Audio-Extra-Menü die **Ethernet-Schnittstelle neu setzen**, Host neu konfigurieren, beide Geräte neu starten. Snyders Prüfung: `aplay -l` auf Target und Host, `Debug` in `/opt/diretta-alsa/setting.inf`, `journalctl -b -u diretta_alsa`.
- 26.09.: Kernel 7.1.8-1-rpi läuft auf 3-Tier-Pi-5; 6.18.53-1 ist der neueste für Pi 4B/CM4. Snyder erwägt eine JSON-Route in der Purist-Mode-Oberfläche.
- 09.10.: Tune Server in alle AudioLinux-Versionen aufgenommen. 19.10.: Bleibt RoonBridge auf 2.60, Update-Menü verlassen und `yay -Sy roonbridge --noconfirm` ausführen, notfalls `/opt/RoonBridge` leeren.
- 18.10./21.10.: Diretta Memory Player (DPDK) nur für Experten, braucht Hugepages und vfio-Module.
- Manuelles Installieren außerhalb der Paketverwaltung kann AudioLinux beschädigen (Entwickler).

## 6. Konsequenzen für das Update
1. Vorher: SD-Image beider Pis, `audiolinux-snapshot/snapshot.sh`, Wiedergabe aus. Installierte Diretta-Version, Kernel und Menü-Version notieren. Appendix 5–10 lokal lesen.
2. Update in Snyders Reihenfolge, Host und Target nacheinander, danach Diretta neu installieren (erwartet 148_12 LTS; Rückweg nur über Support).
3. Danach prüfen: Schnittstelle `Interface=end0`, Dienste aktiviert, Target-Audiokarte gewählt, Lizenz, `aplay -l`, RoonBridge-Version, `isolated.conf`, Realtime-Priorität, `setting.inf` (Purist-Mode-Oberfläche und `.pacnew` überschreiben sie), qdisc, MTU.
4. `snapshot.sh post-update` und `compare.sh`; nur gezielt zurückspielen, was bewusst im Snapshot stand.
5. Vorher sicherstellen, dass die USB-Kette (Omni) stabil ist; ein Hänger mitten im Update würde die Diagnose erschweren.

## 7. Offene Punkte
- Host-IP ist im Router fest eingetragen (erledigt); noch prüfen, dass `/etc/hosts` und die SSH-Aliase am Laptop dieselbe Adresse nutzen.
- `diretta-heal.service` auf dem Host: Herkunft klären. `diretta-nacht.sh` v1.3: `psr`-Spalte reparieren. IPI0-Spitze auf Kern 2 unter Maske 8 untersuchen.
- Erdungs-Messprogramm (diretta-erdung.sh v1.2) und externe Messungen M0–M2 stehen aus. A/B: ThredMode 17, Host-Coalescing 0/0, qdisc, isolated gegen member.
- Aufräumen: Root-Passwort ändern, Laptop-Schlüssel in `authorized_keys`, Skripte und Archive des anderen Fensters auf den Pis.
- Die früheren Messwerkzeuge (`diretta-super.py` v2.0.5 mit 132 Selbsttests, `diretta-qdisc-ab.py`, `diretta-fang/umfeld/core/persist`, `ext5v`) lagen auf den alten Images und mussten auf den neuen neu verteilt werden. Ihre Quellen liegen außerhalb dieses Repos (Laptop `C:\Users\sebor\Claude1\`, Repo `Diretta-Test`).

## 8. Unsicherheiten und Widersprüche
- Snyders Zahlen unterscheiden sich je nach Abschnitt (800/80000, 514/51400, Image 1500/150000). Maßgeblich ist der Image-Stand; der Guide-Abschnitt ist noch zu prüfen.
- Die Release-Notes-Abfrage lieferte keine Datumsangaben und nur Auszüge ab Menü 540; Details zu Menü 545 und neuer sind nicht verifiziert.
- Der Roon-Community-Thread zu Diretta-Einstellungen war nur teilweise lesbar (Diskussion über Nutzen von Diretta bei Async-USB, keine belastbaren Einstellwerte). Kein Messergebnis daraus übernommen.

## 9. Prüfkette ("Super-Skript") – Stand 25.10.2026
- **Fundort:** Repo `BlondStylist/diretta-werkzeuge` (privat): `diretta-super.py` (passive Gesamtaufnahme, 7 Module), `diretta-qdisc-ab.py`, `diretta-latenz.py`, `tests/test_chaos.py`, `tools/mutationstest.py` und die CI `audit.yml` (py_compile, pyflakes, ruff, bandit, mypy, vulture, Selbsttest mit Abdeckung, Chaos-Tests, Preflight, Mutationstests, CodeQL).
- **Ausgangslage (lokal gemessen):** statische Kette sauber; Selbsttests 132 / 83 / 32; Chaos-Tests 31; Mutanten 18 / 20 / 21 erkannt. Abdeckung diretta-super 51 %, qdisc-ab 90 %, latenz 87 %: die Lücke liegt in diretta-super.
- **Ergänzt (PR diretta-werkzeuge#1):** `audit-alles.sh` vereint diese Kette mit den Bash-Werkzeugen (`audiolinux-snapshot`) und wiederholt sie in Runden bis sauber. Die Bash-Suite läuft in einer Overlay-Sandbox. `tools/mutationstest.py` arbeitet jetzt auf einer Kopie. Der Läufer hat eigene Tests (18).
- **Nachweis:** Abschlusslauf über den Endstand: 2 Runden in Folge sauber (statisch, selftest, chaos, preflight, laeufer, bash-statisch, bash-suite, mutation-bash 21/21); davor mutation-py 59/59. CI beider Repos grün (Arch-Container bzw. Audit-Kette inkl. CodeQL).
- **Grenze:** Alles lief ohne Pis. Die Pi-spezifischen Befehle der Snapshot-Werkzeuge (`vcgencmd`, `ethtool`, `pacman`, Cpuset …) sind erst beim ersten Lauf auf dem Pi geprüft; `snapshot.sh --check` zeigt dort in Sekunden, was fehlt.

## 10. Vergleich Original-Image gegen Ist-Zustand (25.10.2026)
Basis: `image-snapshot.sh` auf den Original-Images (Host `diretta-host_v148_5_1-v530-mtu10222-roon`, Target `diretta-target_v148_1_4-v530-mtu10222`, Ordner „mtu900 images 14.09.2026“) gegen `snapshot.sh ist-nach-update` (25.10., Kernel 6.18.53-1-rpi). Ein Vorher-Snapshot der Pis existiert nicht.

- **Vom Menü-Update, behalten:** `cmdline.txt` (neu `isolcpus=2,3 nohz=on workqueue.unbound_cpus=0,1`), `isolated.conf` (tune-server, IRQ-Listen neu: Host `103`, Target `133 128 103`), `rtapp.conf`, `hqplayer_input.service` (ohne Slice/FIFO 80), alle `/opt/scripts/*` (nie zurückspielen), neuere Diretta-Binaries.
- **Absichtlich vom Nutzer entfernt:** Argon-Overlay/-Dienst (Pis ohne Argon-Gehäuse, passive Kühlung, Temperatur unauffällig), IR-Fernbedienung auf dem Host (`gpio-ir`, ir-keymap, roon-ir-remote, Flirc).
- **Bewusster Test, später normalisieren:** Host `setting.inf` `ThredMode=17`, `InfoCycle=180000`, `CycleTime=1800` (Snyder-Original: 16 / 150000 / 1500). Zurücksetzen erst auf Zusage des Nutzers, Dienst-Neustart bei Musik aus.
- **Purist-Modus Target:** `nsswitch.conf` `hosts: files myhostname`, Original als `.purist-bak`.
- **Vom Nutzer gewollt:** `/etc/sudoers.d/zz-audiolinux-noauth` (`Defaults:audiolinux !authenticate`, beide Pis), passwortloses sudo bleibt. Pis in passiven Kupfergehäusen, kein Argon.
- **Versionen (25.10.):** beide Pis Kernel 6.18.53-1-rpi, Diretta 148_21-1 (Host `diretta-alsa-daemon/-dkms`, Target `diretta-alsa-target`/`diretta-direct-dkms`), Host-RoonBridge 2.71.1683-1.
- **`.pacnew` geprüft, nichts übernehmen:** `setting.inf.pacnew` sind generische Paketstandards (`Interface=` leer, `ThredMode=1`, `CycleTime=10000`, `Debug=stdout`); neue Schlüssel `CyclePrio=0`, `DebugTarget=disable`, `disConnectWorkaround=disable` fehlen in der aktiven Datei (Standardwerte, bei Dienst-Warnung nachtragen). `rtapp.conf.pacnew` setzt `APPLICATIONS=""` statt `"syncAlsa RoonBridge"` und würde die RT-Priorität abschalten. `rtirqs.conf.pacnew` nicht beurteilt, irrelevant ohne rtirq.
- **Ergebnis:** Es ist nichts zurückzuspielen; der Ist-Zustand entspricht dem Menü-Update plus den gewollten Änderungen.

## 11. Prüfkette auf dem Laptop (25.10.2026)
`audit-alles.sh --tief` (Branch `audit-mit-latenz` = `claude/audit-alles` + `wip/latenz-v191`) lief auf dem Laptop (Ubuntu/WSL) mit `--extra ~/diretta/selftest-tools.sh` und endete mit „ERGEBNIS: sauber“. Der erste Lauf fand zwei Testfehler (L4 „ohne Root“ scheiterte an den Home-Rechten 0750 von Ubuntu; ein Mutant blieb unbeurteilt, weil die Image-Prüfung ohne `mkfs.vfat` übersprungen wurde). Beides behoben (`72af92e`), `dosfstools` installiert. In der Cloud zusätzlich gefunden und behoben: Lauf 9 hing von der globalen Git-Konfiguration ab (Commit-Signierung).
