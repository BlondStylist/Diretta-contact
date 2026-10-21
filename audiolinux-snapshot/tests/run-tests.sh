#!/usr/bin/env bash
# Entwicklertests (Container/VM, nicht auf dem Pi): legt Testdateien unter /etc/sysctl.d und /home/audiolinux an und raeumt auf.
# shellcheck disable=SC2034  # Variablen werden in eval-Strings von ok() benutzt
# Usage: SNAPSHOT_TEST=1 bash tests/run-tests.sh [lauf2|lauf3|lauf4|all]
set -uo pipefail
[[ ${SNAPSHOT_TEST:-} == 1 && $EUID -eq 0 ]] || { echo "Nur als root mit SNAPSHOT_TEST=1 (veraendert /etc/sysctl.d, /home/audiolinux)" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; W="$(mktemp -d)"; pass=0; fail=0
had_home=0; [[ -d /home/audiolinux ]] && had_home=1
cleanup() { rm -rf "$W" /opt/configuration/zz-d /etc/sysctl.d/zz-t-* /etc/sudoers.d/zz-t-* /home/audiolinux/zz-* "/etc/sysctl.d/zz t.conf"; (( had_home )) || rm -rf /home/audiolinux; }
trap cleanup EXIT
ok() { if ( set +o pipefail; eval "$2" ) >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
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
  s1="$(snap gleich | grep Fertig)"; s2="$(snap gleich | grep Fertig)"
  ok "L2 zwei Laeufe in derselben Sekunde vermischen sich nicht" '[[ "$s1" != "$s2" ]] && [[ "$(ls "$W"/out | grep -c "^snapshot-.*gleich.*[0-9]$")" == 2 ]]'
}

lauf3() {
  mkdir -p /opt/configuration/zz-d /etc/sysctl.d
  echo v1 > /opt/configuration/zz-d/a.conf; echo v1 > /opt/configuration/zz-d/b.conf; echo v1 > /etc/sysctl.d/zz-t-r.conf
  snap r >/dev/null; A="$(newest r)"
  echo v2 > /etc/sysctl.d/zz-t-r.conf
  rs() { BACKUP_DIR="$W/bak" bash "$here/restore.sh" "$@" 2>&1; }
  o="$(rs "$A" /etc/sysctl.d/zz-t-r.conf)"
  ok "L3 Trockenlauf aendert nichts" '[[ "$(cat /etc/sysctl.d/zz-t-r.conf)" == v2 ]]'
  ok "L3 Trockenlauf zeigt Unterschied" 'grep -q "^[-+]v" <<<"$o"'
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
  mkdir "$W/bin"; for c in bash sh tar gzip find xargs sha256sum sort awk df cat ls date hostname mkdir chmod cp chown du wc sleep grep head tail sed stat basename dirname mktemp rm readlink realpath uname id; do
    p="$(command -v "$c")" && ln -s "$p" "$W/bin/$c"; done
  o="$(PATH="$W/bin" OUT_BASE="$W/min" SAMPLE=0 bash "$here/snapshot.sh" min 2>&1)"; r=$?
  ok "L4 ohne Pi-/Arch-Werkzeuge: Exit 0 und Archiv da" '[[ $r -eq 0 ]] && ls "$W"/min/*.tar.gz'
  ok "L4 fehlende Tools stehen im Bericht (nicht still verschluckt)" 'grep -rq "not found" "$W"/min/snapshot-*/report/'
  ok "L4 Konfigurationsdateien trotzdem gesichert" 'tar -xzOf "$W"/min/snapshot-*/files.tar.gz etc/sysctl.d/zz-t-x.conf | grep -q "^a$"'
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
  bash "$here/compare.sh" /nicht/da.tar.gz /auch/nicht.tar.gz >/dev/null 2>&1; r=$?; ok "L4 compare: fehlende Datei -> Exit 2" '[[ $r -eq 2 ]]'
  A="$(newest clean2)"; bash "$here/compare.sh" "$A" "$A" >/dev/null 2>&1; ok "L4 compare: identisch -> Exit 0" '[[ $? -eq 0 ]]'
  echo changed >> /etc/sysctl.d/zz-t-x.conf; snap c3 >/dev/null; bash "$here/compare.sh" "$A" "$(newest c3)" >/dev/null 2>&1; r=$?; ok "L4 compare: Unterschied -> Exit 1" '[[ $r -eq 1 ]]'
  t0=$(date +%s); snap zeit >/dev/null; echo "INFO: Laufzeit $(( $(date +%s)-t0 )) s, Archiv $(du -h "$(newest zeit)" | cut -f1)"
}
for l in ${1:-all}; do case "$l" in all) lauf2; lauf3; lauf4;; lauf2) lauf2;; lauf3) lauf3;; lauf4) lauf4;; esac; done
echo "bestanden: $pass, fehlgeschlagen: $fail"; (( fail == 0 ))
