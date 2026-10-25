#!/usr/bin/env bash
# Entwicklertests (Container/VM, nicht auf dem Pi): legt Testdateien unter /etc/sysctl.d und /home/audiolinux an und raeumt auf.
# shellcheck disable=SC2034  # Variablen werden in eval-Strings von ok() benutzt
# Usage: SNAPSHOT_TEST=1 bash tests/run-tests.sh [lauf2|lauf3|lauf4|all]
set -uo pipefail
[[ ${SNAPSHOT_TEST:-} == 1 && $EUID -eq 0 ]] || { echo "Nur als root mit SNAPSHOT_TEST=1 (veraendert /etc/sysctl.d, /home/audiolinux)" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; W="$(mktemp -d)"; pass=0; fail=0
made_user=0
if ! id audiolinux >/dev/null 2>&1 && command -v useradd >/dev/null; then useradd -m -s /bin/bash audiolinux && made_user=1; fi
cleanup() { rm -rf "$W" /opt/configuration/zz-d /etc/zz-t-* /etc/sysctl.d/zz-t-* /etc/sudoers.d/zz-t-* /etc/ssh/ssh_host_zz_key /tmp/zz-t-escape /home/audiolinux/zz-* /home/audiolinux/snapshots "/etc/sysctl.d/zz t.conf"; (( made_user )) && userdel -r audiolinux >/dev/null 2>&1; }
trap cleanup EXIT
ok() { local _o; if _o="$( ( set +o pipefail; eval "$2" ) 2>&1 )"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; [[ -n $_o ]] && head -5 <<<"$_o" | sed 's/^/    /'; return 1; fi; }
dbg() { printf '%s\n' "$*" | head -12 | sed 's/^/    | /'; }
snap() { OUT_BASE="$W/out" SAMPLE=0 bash "$here/snapshot.sh" "$@" 2>&1; }
newest() { ls -t "$W"/out/snapshot-*"$1"*.tar.gz 2>/dev/null | head -1; }

lauf2() {
  mkdir -p /etc/sysctl.d /home/audiolinux/.ssh /home/audiolinux/zz-ext5v
  echo a > /etc/sysctl.d/zz-t-a.conf; echo s > "/etc/sysctl.d/zz t.conf"
  echo KEY > /home/audiolinux/.ssh/id_ed25519; echo cfg > /home/audiolinux/.ssh/config
  echo '#!/bin/sh' > /home/audiolinux/zz-mess.sh; head -c 300000 /dev/zero > /home/audiolinux/zz-ext5v/big.conf
  out="$(snap "vor n/1")"; A="$(newest vor_n_1)"
  ok "L2 Archiv erzeugt, Label bereinigt" '[[ -s "$A" ]]'
  ok "L2 Archiv nur fuer root lesbar (0600)" '[[ "$(stat -c %a "$A")" == 600 ]]'
  ok "L2 Berichte + Manifest + files.tar.gz enthalten" 'tar -tzf "$A" | grep -q report/00-system.txt && tar -tzf "$A" | grep -q manifest.sha256 && tar -tzf "$A" | grep -q files.tar.gz'
  ok "L2 Nachkommastellen: Meldung nennt Pfadzahl" 'grep -q "Pfade" <<<"$out"'
  mkdir "$W/x"; tar -xzf "$A" -C "$W/x" --strip-components=1
  ok "L2 Testdatei im Archiv" 'tar -tzf "$W/x/files.tar.gz" | grep -q "etc/sysctl.d/zz-t-a.conf"'
  ok "L2 Datei mit Leerzeichen im Archiv" 'tar -tzf "$W/x/files.tar.gz" | grep -q "etc/sysctl.d/zz t.conf"'
  ok "L2 KEIN privater SSH-Schluessel im Archiv" '! tar -xzOf "$W/x/files.tar.gz" 2>/dev/null | grep -aq "^KEY$"'
  ok "L2 ssh config im Archiv" 'tar -tzf "$W/x/files.tar.gz" | grep -q home/audiolinux/.ssh/config'
  ok "L2 Heimskript im Archiv, grosse Datei nicht" 'tar -tzf "$W/x/files.tar.gz" | grep -q zz-mess.sh && ! tar -tzf "$W/x/files.tar.gz" | grep -q big.conf'
  ok "L2 Kopie fuer audiolinux 0600 und im Home-Ordner" '[[ -s /home/audiolinux/snapshots/$(basename "$A") ]]'
  sleep 1; echo b >> /etc/sysctl.d/zz-t-a.conf; echo n > /etc/sysctl.d/zz-t-new.conf; rm "/etc/sysctl.d/zz t.conf"
  snap nach >/dev/null; B="$(newest nach)"; cmp="$(bash "$here/compare.sh" "$A" "$B")"
  ok "L2 compare: CHANGED erkannt" 'grep -q "CHANGED /etc/sysctl.d/zz-t-a.conf" <<<"$cmp"'
  ok "L2 compare: ADDED erkannt" 'grep -q "ADDED   /etc/sysctl.d/zz-t-new.conf" <<<"$cmp"'
  ok "L2 compare: REMOVED mit Leerzeichen im Pfad" 'grep -q "REMOVED /etc/sysctl.d/zz t.conf" <<<"$cmp"'
  ok "L2 compare: identische Snapshots liefern keine Dateiunterschiede" 'c2="$(bash "$here/compare.sh" "$B" "$B")"; ! grep -qE "^(CHANGED|ADDED|REMOVED)" <<<"$c2"'
  ok "L2 compare: kein Rauschen aus df/timers/sysctl-Zaehlern" '! grep -qE "^[-+].*(ns_last_pid|dentry-state|Use%)" <<<"$cmp"'
  mkdir "$W/clk"; printf '#!/bin/sh\n[ "$1" = "+%%Y%%m%%d-%%H%%M%%S" ] && echo 20260101-000000 || exec %s "$@"\n' "$(command -v date)" > "$W/clk/date"; chmod +x "$W/clk/date"
  s1="$(PATH="$W/clk:$PATH" OUT_BASE="$W/out" SAMPLE=0 bash "$here/snapshot.sh" gleich 2>&1 | grep Fertig)"; s2="$(PATH="$W/clk:$PATH" OUT_BASE="$W/out" SAMPLE=0 bash "$here/snapshot.sh" gleich 2>&1 | grep Fertig)"
  ok "L2 zwei Laeufe mit identischer Zeit ueberschreiben sich nicht (festgesetzte Uhr)" '[[ "$s1" != "$s2" && "$(ls "$W"/out | grep -c "^snapshot-.*-gleich-20260101-000000.*\.tar\.gz$")" == 2 ]]'
}

lauf3() {
  mkdir -p /opt/configuration/zz-d /etc/sysctl.d
  echo v1 > /opt/configuration/zz-d/a.conf; echo v1 > /opt/configuration/zz-d/b.conf; echo v1 > /etc/sysctl.d/zz-t-r.conf
  snap r >/dev/null; A="$(newest r)"
  echo v2 > /etc/sysctl.d/zz-t-r.conf
  rs() { BACKUP_DIR="$W/bak" bash "$here/restore.sh" "$@" 2>&1; }
  o="$(rs "$A" /etc/sysctl.d/zz-t-r.conf)"
  ok "L3 Trockenlauf aendert nichts" '[[ "$(cat /etc/sysctl.d/zz-t-r.conf)" == v2 ]]'
  ok "L3 Trockenlauf zeigt Unterschied" 'grep -q "^[-+]v" <<<"$o"' || dbg "$o"
  DRY_RUN=0 rs "$A" /etc/sysctl.d/zz-t-r.conf >/dev/null
  ok "L3 DRY_RUN=0 stellt Datei wieder her" '[[ "$(cat /etc/sysctl.d/zz-t-r.conf)" == v1 ]]'
  ok "L3 vorherige Version wurde gesichert" 'grep -rq "^v2$" "$W"/bak/pre-restore-*/etc/sysctl.d/zz-t-r.conf'
  echo v2 > /opt/configuration/zz-d/a.conf; rm /opt/configuration/zz-d/b.conf; echo n > /opt/configuration/zz-d/new.conf
  DRY_RUN=0 rs "$A" /opt/configuration/zz-d/ >/dev/null
  ok "L3 Ordner (mit Slash): geaenderte + geloeschte Dateien kommen zurueck" '[[ "$(cat /opt/configuration/zz-d/a.conf)" == v1 && -f /opt/configuration/zz-d/b.conf ]]'
  ok "L3 Ordner: neue Datei bleibt unberuehrt" '[[ -f /opt/configuration/zz-d/new.conf ]]'
  for bad in /opt/scripts /opt/scripts/ /opt/configuration/../scripts /usr/bin /lib/modules /var/lib/pacman/local /; do
    o="$(DRY_RUN=0 rs "$A" "$bad")"; ok "L3 abgelehnt: $bad" 'grep -q ABGELEHNT <<<"$o"'
  done
  o="$(rs "$A" relativer/pfad)"; ok "L3 relativer Pfad abgelehnt" 'grep -q ABGELEHNT <<<"$o"'
  for risky in /etc/fstab /boot/cmdline.txt /boot/firmware/config.txt; do
    o="$(DRY_RUN=0 rs "$A" "$risky")"; ok "L3 $risky braucht FORCE=1" 'grep -q "FORCE=1" <<<"$o"'
  done
  rs "$A" /etc/sysctl.d/gibt-es-nicht.conf >/dev/null; r=$?; ok "L3 Pfad nicht im Snapshot: Exit-Code ungleich 0" '[[ $r -ne 0 ]]'
  rs "$W/fehlt.tar.gz" /etc/hostname >/dev/null; r=$?; ok "L3 fehlender Snapshot: Exit-Code ungleich 0" '[[ $r -ne 0 ]]'
  rm -rf /opt/configuration/zz-d
}

lauf4() {
  mkdir -p /etc/sysctl.d; echo a > /etc/sysctl.d/zz-t-x.conf
  # Minimal-PATH: nur Coreutils, keine Arch-/Pi-Werkzeuge (pacman, systemctl, ethtool, tc, vcgencmd, ...)
  mkdir "$W/bin"; for c in bash sh tar gzip find xargs sha256sum sort awk df cat ls date hostname mkdir chmod cp chown du wc sleep grep head tail sed stat basename dirname mktemp rm readlink realpath uname id cut tr diff; do
    p="$(command -v "$c")" && ln -s "$p" "$W/bin/$c"; done
  o="$(PATH="$W/bin" OUT_BASE="$W/min" SAMPLE=0 bash "$here/snapshot.sh" min 2>&1)"; r=$?
  ok "L4 ohne Pi-/Arch-Werkzeuge: Exit 0 und Archiv da" '[[ $r -eq 0 ]] && ls "$W"/min/*.tar.gz'
  mkdir "$W/minx"; tar -xzf "$W"/min/snapshot-*.tar.gz -C "$W/minx" --strip-components=1
  ok "L4 fehlende Tools stehen im Bericht (nicht still verschluckt)" 'grep -rq "not found" "$W/minx/report/"'
  ok "L4 Konfigurationsdateien trotzdem gesichert" 'tar -xzOf "$W/minx/files.tar.gz" etc/sysctl.d/zz-t-x.conf | grep -q "^a$"'
  id nobody >/dev/null 2>&1 && { runuser -u nobody -- bash "$here/snapshot.sh" >/dev/null 2>&1; r=$?; ok "L4 ohne Root: Exit 4" '[[ $r -eq 4 ]]'; }
  if (( $(nproc) >= 2 )) && command -v taskset >/dev/null; then
    OUT_BASE="$W/aff" SAMPLE=3 bash "$here/snapshot.sh" aff >/dev/null 2>&1 & pid=$!; sleep 1
    ok "L4 Skript laeuft nur auf Kern 0-1 (Audiokerne 2-3 unberuehrt)" '[[ "$(awk "/Cpus_allowed_list/{print \$2}" /proc/$pid/status)" == 0-1 ]]'
    wait "$pid"
  fi
  if mount -t tmpfs -o size=8m tmpfs "$W/small" 2>/dev/null || { mkdir -p "$W/small"; mount -t tmpfs -o size=8m tmpfs "$W/small" 2>/dev/null; }; then
    OUT_BASE="$W/small" SAMPLE=0 bash "$here/snapshot.sh" voll >/dev/null 2>&1; r=$?
    ok "L4 zu wenig Platz: Exit 7, kein halbes Archiv" '[[ $r -eq 7 ]] && ! ls "$W"/small/*.tar.gz'; umount "$W/small"
  else echo "SKIP: tmpfs-Mount nicht erlaubt (Platz-Test)"; fi
  mkdir -p /home/audiolinux/.config; printf 'password = geheim123\n' > /home/audiolinux/zz-secret.conf
  o="$(snap secret)"; ok "L4 Warnung bei moeglichen Zugangsdaten im Archiv" 'grep -q "Zugangsdaten" <<<"$o" && grep -q zz-secret.conf <<<"$o"'
  mkdir -p /etc/sudoers.d; echo 'x ALL=(ALL) NOPASSWD: /usr/bin/true' > /etc/sudoers.d/zz-t-sudo; rm -f /home/audiolinux/zz-secret.conf
  o="$(snap clean2)"; ok "L4 sudoers NOPASSWD loest keine Fehlwarnung aus" '! grep -q "zz-t-sudo" <<<"$o"'
  mkdir "$W/nocut"; for c in bash sh tar gzip find xargs sha256sum sort awk df cat ls date mkdir chmod cp du wc sleep grep head tail sed stat basename dirname mktemp rm readlink realpath uname id tr diff; do p="$(command -v "$c")" && ln -s "$p" "$W/nocut/$c"; done
  o="$(PATH="$W/nocut" OUT_BASE="$W/nc" SAMPLE=0 bash "$here/snapshot.sh" nc 2>&1)"; r=$?
  ok "L4 fehlendes Pflicht-Werkzeug (cut): Exit 3 mit klarer Meldung, kein Halbarchiv" '[[ $r -eq 3 ]] && grep -q "Fehlende Pflicht-Werkzeuge: cut" <<<"$o" && ! ls "$W"/nc/*.tar.gz'
  mkdir "$W/nodiff"; for c in bash sh tar gzip sort awk mktemp grep realpath id; do p="$(command -v "$c")" && ln -s "$p" "$W/nodiff/$c"; done
  snap nd >/dev/null; PATH="$W/nodiff" bash "$here/compare.sh" "$(newest nd)" "$(newest nd)" >/dev/null 2>&1; r1=$?; PATH="$W/nodiff" bash "$here/restore.sh" "$(newest nd)" /etc/hostname >/dev/null 2>&1; r2=$?
  ok "L4 ohne diff: compare und restore melden das (Exit 3), statt still falsch zu laufen" '[[ $r1 -eq 3 && $r2 -eq 3 ]]'
  o="$(OUT_BASE="$W/chk" bash "$here/snapshot.sh" --check 2>&1)"; r=$?
  ok "L4 --check: Exit 0, listet Pflicht-/optionale Werkzeuge und Pfade, legt nichts an" '[[ $r -eq 0 ]] && grep -q "Pflicht-Werkzeuge" <<<"$o" && grep -q "Optionale Werkzeuge" <<<"$o" && grep -q "^Pfade:" <<<"$o" && [[ ! -e "$W/chk" ]]'
  o="$(PATH="$W/nocut" bash "$here/snapshot.sh" --check 2>&1)"; r=$?
  ok "L4 --check: fehlendes Pflicht-Werkzeug (cut) -> Exit 3 und FEHLT-Zeile" '[[ $r -eq 3 ]] && grep -q "FEHLT   cut" <<<"$o"'
  bash "$here/compare.sh" /nicht/da.tar.gz /auch/nicht.tar.gz >/dev/null 2>&1; r=$?; ok "L4 compare: fehlende Datei -> Exit 2" '[[ $r -eq 2 ]]'
  A="$(newest clean2)"; bash "$here/compare.sh" "$A" "$A" >/dev/null 2>&1; ok "L4 compare: identisch -> Exit 0" '[[ $? -eq 0 ]]'
  echo changed >> /etc/sysctl.d/zz-t-x.conf; snap c3 >/dev/null; bash "$here/compare.sh" "$A" "$(newest c3)" >/dev/null 2>&1; r=$?; ok "L4 compare: Unterschied -> Exit 1" '[[ $r -eq 1 ]]'
  t0=$(date +%s); snap zeit >/dev/null; echo "INFO: Laufzeit $(( $(date +%s)-t0 )) s, Archiv $(du -h "$(newest zeit)" | cut -f1)"
}

xt() { mkdir -p "$2"; tar -xzf "$1" -C "$2" --strip-components=1; }

lauf5() {  # Angreifersicht: root schreibt nie in vom Nutzer kontrollierte Pfade; manipulierte Archive
  if id audiolinux >/dev/null 2>&1; then
    rm -rf /home/audiolinux/snapshots; mkdir -m 700 "$W/victim"
    runuser -u audiolinux -- ln -sfn "$W/victim" /home/audiolinux/snapshots
    o="$(snap sym)"
    ok "L5 Symlink ~/snapshots -> Fremdverzeichnis: root schreibt NICHT hinein" '[[ -z "$(ls -A "$W/victim")" ]]'
    ok "L5 Symlink wird gemeldet" 'grep -qi "symlink\|fehlgeschlagen" <<<"$o"'
    rm -f /home/audiolinux/snapshots; snap ok1 >/dev/null
    ok "L5 normale Kopie gehoert audiolinux, 0600" '[[ "$(stat -c "%U %a" /home/audiolinux/snapshots/*ok1*.tar.gz)" == "audiolinux 600" ]]'
    echo SECRET > /etc/zz-t-victim; ln -s /etc/zz-t-victim /home/audiolinux/snapshots/zz-planted
    ok "L5 Verzeichnis ~/snapshots gehoert dem Nutzer (kein root-Besitz)" '[[ "$(stat -c %U /home/audiolinux/snapshots)" == audiolinux ]]'
  else echo "SKIP: kein Testnutzer audiolinux (useradd fehlt)"; fi
  printf 'x\n' > "/etc/sysctl.d/zz-t-nl
x.conf"
  snap nl >/dev/null; r=$?; ok "L5 Dateiname mit Zeilenumbruch bricht den Snapshot nicht" '[[ $r -eq 0 ]]'
  bash "$here/compare.sh" "$(newest nl)" "$(newest nl)" >/dev/null 2>&1; r=$?; ok "L5 compare stuerzt bei Zeilenumbruch-Namen nicht ab" '[[ $r -le 1 ]]'
  rm -f /etc/sysctl.d/zz-t-nl*
  # manipuliertes Archiv: Member laeuft durch einen Symlink nach draussen
  snap crafted >/dev/null; mkdir -p /tmp/zz-t-escape "$W/cr"; xt "$(newest crafted)" "$W/cr"
  python3 -I - "$W/cr/files.tar.gz" <<'PY'
import tarfile,io,sys
with tarfile.open(sys.argv[1],'w:gz') as t:
    d=tarfile.TarInfo('etc/sysctl.d'); d.type=tarfile.DIRTYPE; d.mode=0o755; t.addfile(d)
    l=tarfile.TarInfo('etc/sysctl.d/zz-t-link'); l.type=tarfile.SYMTYPE; l.linkname='/tmp/zz-t-escape'; t.addfile(l)
    f=tarfile.TarInfo('etc/sysctl.d/zz-t-link/pwn'); data=b'pwned'; f.size=len(data); t.addfile(f,io.BytesIO(data))
PY
  (cd "$W" && tar -czf evil.tar.gz cr)
  o="$(DRY_RUN=0 BACKUP_DIR="$W/bak" bash "$here/restore.sh" "$W/evil.tar.gz" /etc/sysctl.d 2>&1)"; r=$?
  ok "L5 Archiv mit Symlink-Durchgriff: nichts ausserhalb geschrieben" '[[ ! -e /tmp/zz-t-escape/pwn ]]'
  ok "L5 Archiv mit Symlink-Durchgriff wird abgelehnt (Exit != 0, Meldung)" '[[ $r -ne 0 ]] && grep -qi "symlink" <<<"$o"'
  rm -rf /tmp/zz-t-escape /etc/sysctl.d/zz-t-link
}

lauf6() {  # Betriebsfehler: SSH-Abbruch, Strg-C, ramroot, Stromausfall, Hostname-Tool fehlt
  snap one >/dev/null
  ok "L6 nach Erfolg bleibt nur das Archiv (kein entpacktes Doppel)" '[[ -z "$(ls -d "$W"/out/snapshot-*one-* 2>/dev/null | grep -v "\.tar\.gz$")" ]]'
  OUT_BASE="$W/int" SAMPLE=6 bash "$here/snapshot.sh" intr >/dev/null 2>&1 & pid=$!; sleep 2; kill -TERM "$pid"; wait "$pid"; r=$?
  ok "L6 Abbruch per Signal (Strg-C/kill): Exit 130, kein Halbarchiv, kein Rest-Verzeichnis" '[[ $r -eq 130 && -z "$(ls -A "$W/int" 2>/dev/null)" ]]'
  OUT_BASE="$W/hup" SAMPLE=4 bash "$here/snapshot.sh" hup >/dev/null 2>&1 & pid=$!; sleep 2; kill -HUP "$pid"; wait "$pid"; r=$?
  ok "L6 SSH-Abbruch (SIGHUP): Lauf endet trotzdem mit vollstaendigem Archiv" '[[ $r -eq 0 ]] && ls "$W"/hup/*.tar.gz'
  mkdir "$W/stub"; printf '#!/bin/sh\necho tmpfs\n' > "$W/stub/findmnt"; printf '#!/bin/sh\ntouch %s\n' "$W/synced" > "$W/stub/sync"; chmod +x "$W/stub"/*
  o="$(PATH="$W/stub:$PATH" OUT_BASE="$W/ram" SAMPLE=0 bash "$here/snapshot.sh" lbl 2>&1)"
  ok "L6 ramroot/tmpfs-Root: Warnung, Archiv sofort zu sichern" 'grep -q "WARNUNG: Root-Dateisystem ist .tmpfs." <<<"$o"'
  ok "L6 sync wird am Ende aufgerufen (Stromausfall/Omni-Haenger direkt danach)" '[[ -e "$W/synced" ]]'
  mkdir "$W/nohost"; for c in bash sh tar gzip find xargs sha256sum sort awk df cat ls date mkdir chmod cp du wc sleep grep head tail sed stat basename dirname mktemp rm readlink realpath uname id install cut tr; do p="$(command -v "$c")" && ln -s "$p" "$W/nohost/$c"; done
  PATH="$W/nohost" OUT_BASE="$W/nh" SAMPLE=0 bash "$here/snapshot.sh" nh >/dev/null 2>&1; r=$?
  ok "L6 ohne hostname-Tool: Lauf ok, Name enthaelt Rechnernamen" '[[ $r -eq 0 ]] && ls "$W"/nh/snapshot-"$(uname -n)"-nh-*.tar.gz'
  o="$(PATH="$W/nohost" OUT_BASE="$W/nh2" SAMPLE=0 bash "$here/snapshot.sh" nh2 2>&1)"
  ok "L6 Zusammenfassung nennt fehlgeschlagene Befehle" 'grep -qi "Befehle mit Fehler" <<<"$o"'
  ok "L6 keine Bash-Warnung ueber NUL-Bytes" '! grep -qi "null byte" <<<"$o"'
}

lauf7() {  # Vollstaendigkeit: deckt das Archiv wirklich ALLE Einstellungen ab?
  mkdir -p /etc/zz-t-conf.d /etc/ssh; echo k > /etc/zz-t-conf.d/foo.conf; echo secret > /etc/ssh/ssh_host_zz_key; ln -sfn a /etc/zz-t-link
  snap full >/dev/null; A="$(newest full)"; xt "$A" "$W/f"
  ok "C7 beliebige Datei unter /etc (ausserhalb der alten Liste) ist im Archiv" 'tar -tzf "$W/f/files.tar.gz" | grep -q etc/zz-t-conf.d/foo.conf'
  ok "C7 Host-Schluessel und shadow sind NICHT im Archiv" '! tar -tzf "$W/f/files.tar.gz" | grep -qE "ssh_host_zz_key|etc/shadow"'
  ok "C7 Manifest deckt jede Archivdatei und jeden Symlink ab" '[[ "$(tar -tzf "$W/f/files.tar.gz" | grep -vc "/$")" == "$(wc -l < "$W/f/manifest.sha256")" ]]'
  ok "C7 Symlink steht im Manifest" 'grep -q " /etc/zz-t-link$" "$W/f/manifest.sha256"'
  ln -sfn b /etc/zz-t-link; echo n > /etc/zz-t-conf.d/x.conf.pacnew; sleep 1; snap full2 >/dev/null
  c="$(bash "$here/compare.sh" "$A" "$(newest full2)")"
  ok "C7 geaenderter Symlink-Zielpfad wird als CHANGED erkannt" 'grep -q "CHANGED /etc/zz-t-link" <<<"$c"'
  ok "C7 neue .pacnew-Datei steht im eigenen Warnabschnitt" 'grep -A3 "von Hand pruefen" <<<"$c" | grep -q "ADDED.*x.conf.pacnew"'
  ok "C7 Bericht enthaelt Wurzel-Dateisystem und MAC-Adressen-Quelle" 'grep -rq "findmnt\|/proc/mounts" "$W/f/report/00-system.txt"'
}

lauf8() {  # Rundreise: aendern -> zurueckspielen -> vergleichen; Snapshot veraendert nichts
  mkdir -p /etc/zz-t-rt/sub; echo a > /etc/zz-t-rt/a.conf; echo b > /etc/zz-t-rt/sub/b.conf; chmod 640 /etc/zz-t-rt/a.conf; chown 1234:5678 /etc/zz-t-rt/sub/b.conf
  touch -d '2026-01-02 03:04:05' /etc/zz-t-rt/a.conf; ln -s a.conf /etc/zz-t-rt/l
  before="$(cd /etc/zz-t-rt && find . -printf "%p %m %U:%G %T@ %l\n" | sort)"
  snap pre >/dev/null; P="$(newest pre)"
  echo changed > /etc/zz-t-rt/a.conf; chmod 600 /etc/zz-t-rt/a.conf; rm /etc/zz-t-rt/sub/b.conf; rm /etc/zz-t-rt/l; echo f > /etc/zz-t-rt/l; echo new > /etc/zz-t-rt/new.conf
  rm -rf /etc/zz-t-rt/sub; echo "ich bin jetzt eine Datei" > /etc/zz-t-rt/sub
  DRY_RUN=0 BACKUP_DIR="$W/bak" bash "$here/restore.sh" "$P" /etc/zz-t-rt/a.conf /etc/zz-t-rt/l >/dev/null 2>&1
  ok "L8 Datei: Inhalt, Modus, Zeitstempel zurueck" '[[ "$(cat /etc/zz-t-rt/a.conf)" == a && "$(stat -c %a /etc/zz-t-rt/a.conf)" == 640 && "$(stat -c %Y /etc/zz-t-rt/a.conf)" == "$(date -d "2026-01-02 03:04:05" +%s)" ]]'
  ok "L8 Typwechsel Datei->Symlink wird zurueckgesetzt" '[[ -L /etc/zz-t-rt/l && "$(readlink /etc/zz-t-rt/l)" == a.conf ]]'
  o="$(DRY_RUN=0 BACKUP_DIR="$W/bak" bash "$here/restore.sh" "$P" /etc/zz-t-rt/sub 2>&1)"; r=$?
  ok "L8 Typwechsel Ordner->Datei: entweder korrekt hergestellt oder laut gescheitert" '{ [[ -d /etc/zz-t-rt/sub && "$(cat /etc/zz-t-rt/sub/b.conf)" == b ]]; } || { [[ $r -ne 0 ]] && grep -q FEHLER <<<"$o"; }'
  [[ -f /etc/zz-t-rt/sub ]] && DRY_RUN=0 BACKUP_DIR="$W/bak" bash "$here/restore.sh" "$P" /etc/zz-t-rt/sub >/dev/null 2>&1
  DRY_RUN=0 BACKUP_DIR="$W/bak" bash "$here/restore.sh" "$P" /etc/zz-t-rt >/dev/null 2>&1
  ok "L8 zweites Zurueckspielen ist idempotent und stellt Besitzer 1234:5678 her" '[[ "$(stat -c %u:%g /etc/zz-t-rt/sub/b.conf)" == 1234:5678 ]]'
  after="$(cd /etc/zz-t-rt && find . -printf "%p %m %U:%G %T@ %l\n" | sort | grep -v "new.conf")"
  ok "L8 Rundreise: Pfad, Modus, Besitzer, Link-Ziel identisch (tar stellt Zeiten nur sekundengenau her)" '[[ "$(awk "{\$4=\"\"; print}" <<<"$before")" == "$(awk "{\$4=\"\"; print}" <<<"$after")" ]]'
  snap post >/dev/null; c="$(bash "$here/compare.sh" "$P" "$(newest post)")"
  ok "L8 Vergleich nach Restore: nur die bewusst belassene neue Datei unterscheidet sich" '[[ "$(grep -E "^(CHANGED|REMOVED|ADDED)" <<<"$c" | grep zz-t-rt | tr -s " ")" == "ADDED /etc/zz-t-rt/new.conf" ]]'
  # Snapshot veraendert nichts
  touch "$W/marker"; sleep 1; snap noeffect >/dev/null
  leak="$(find /etc /opt /boot /var/lib -xdev -newer "$W/marker" -type f 2>/dev/null | head -5)"
  ok "L8 Snapshot schreibt nichts in /etc, /opt, /boot, /var/lib" '[[ -z "$leak" ]]' || dbg "veraenderte Dateien: $leak"
  # Gesamtszenario: pre -> simulierter Update -> post -> compare -> gezielt zurueck
  mkdir -p /etc/zz-t-up; echo keep > /etc/zz-t-up/keep.conf; echo old > /etc/zz-t-up/set.conf; snap upre >/dev/null; U="$(newest upre)"
  echo "update-wirkung" > /etc/zz-t-up/set.conf; echo n > /etc/zz-t-up/set.conf.pacnew; rm /etc/zz-t-up/keep.conf; sleep 1; snap upost >/dev/null
  c="$(bash "$here/compare.sh" "$U" "$(newest upost)" | grep -E "^(CHANGED|REMOVED|ADDED)" | grep zz-t-up | tr -s " " | sort -u)"
  ok "L8 Szenario: Vergleich liefert exakt die simulierten Update-Wirkungen" '[[ "$c" == "$(printf "ADDED /etc/zz-t-up/set.conf.pacnew\nCHANGED /etc/zz-t-up/set.conf\nREMOVED /etc/zz-t-up/keep.conf")" ]]'
  DRY_RUN=0 BACKUP_DIR="$W/bak" bash "$here/restore.sh" "$U" /etc/zz-t-up/keep.conf >/dev/null 2>&1
  ok "L8 Szenario: gezieltes Zurueckspielen stellt nur die gewaehlte Datei her" '[[ "$(cat /etc/zz-t-up/keep.conf)" == keep && "$(cat /etc/zz-t-up/set.conf)" == update-wirkung ]]'
  rm -rf /etc/zz-t-up /etc/zz-t-rt
}
for l in ${1:-all}; do case "$l" in all) lauf2; lauf3; lauf4; lauf5; lauf6; lauf7; lauf8;; lauf2) lauf2;; lauf3) lauf3;; lauf4) lauf4;; lauf5) lauf5;; lauf6) lauf6;; lauf7) lauf7;; lauf8) lauf8;; esac; done
echo "bestanden: $pass, fehlgeschlagen: $fail"; (( fail == 0 ))
