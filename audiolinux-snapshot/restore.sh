#!/usr/bin/env bash
# Spielt einzelne Dateien/Ordner aus einem Snapshot zurueck. Standard ist Trockenlauf; die aktuelle Fassung wird vorher gesichert.
# Neue Dateien in einem Ordner bleiben bestehen (es wird nichts geloescht).
# Usage: [DRY_RUN=0] [FORCE=1] sudo bash restore.sh snapshot-*.tar.gz /abs/pfad [/abs/pfad ...]
# Exit: 0 alles ok | 1 mindestens ein Pfad abgelehnt/nicht gefunden | 2 Aufruf/Snapshot
set -uo pipefail
[[ $EUID -eq 0 && $# -ge 2 ]] || { echo "Usage: sudo [DRY_RUN=0] [FORCE=1] bash $0 snapshot.tar.gz /abs/pfad..." >&2; exit 2; }
snap="$(readlink -f -- "$1")"; shift
[[ -f $snap ]] || { echo "Snapshot nicht gefunden: $snap" >&2; exit 2; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
tar -xzf "$snap" -C "$t" --strip-components=1 --wildcards '*/files.tar.gz' 2>/dev/null && [[ -f $t/files.tar.gz ]] || { echo "Kein files.tar.gz im Snapshot" >&2; exit 2; }
bak="${BACKUP_DIR:-/root/config-archiv}/pre-restore-$(date +%Y%m%d-%H%M%S)"; rc=0
for arg in "$@"; do
  if [[ $arg != /* ]]; then echo "ABGELEHNT: $arg (nur absolute Pfade)"; rc=1; continue; fi
  p="$(realpath -m -- "$arg")"                                   # loest .. und // auf, bevor geprueft wird
  case "$p" in
    /|/opt/scripts|/opt/scripts/*|/usr|/usr/*|/lib|/lib/*|/var/lib/pacman|/var/lib/pacman/*|/bin|/bin/*|/sbin|/sbin/*)
      echo "ABGELEHNT: $arg (Menue-/Paketcode oder Systemwurzel nie zurueckspielen)"; rc=1; continue;;
    /etc/fstab|/boot|/boot/*)
      if [[ ${FORCE:-0} != 1 ]]; then echo "ABGELEHNT: $arg (bootrelevant; mit FORCE=1 und SD-Image-Backup)"; rc=1; continue; fi;;
    /etc/systemd/network|/etc/systemd/network/*) echo "HINWEIS: $p aendert das Netzwerk, vorher deadman/zweites SSH-Fenster bereithalten";;
  esac
  rel="${p#/}"
  if ! tar -tzf "$t/files.tar.gz" "$rel" >/dev/null 2>&1; then echo "nicht im Snapshot: $p"; rc=1; continue; fi
  rm -rf "$t/x"; mkdir "$t/x"                                    # erst probeweise entpacken: unsichere/kaputte Archive fallen hier auf
  if ! tar -xzpf "$t/files.tar.gz" -C "$t/x" "$rel" 2>"$t/err"; then
    echo "FEHLER: $p: Entpacken in Temp fehlgeschlagen (inkonsistentes Archiv oder Symlink-Durchgriff?): $(head -c 200 "$t/err")"; rc=1; continue
  fi
  if [[ ${DRY_RUN:-1} != 0 ]]; then
    echo "[Trockenlauf] wuerde zuruecksetzen: $p"
    d="$(diff -ru -- "$t/x/$rel" "$p" 2>&1 | grep -vE '^(diff |--- |\+\+\+ )' | head -20)"; echo "${d:-  (keine Unterschiede)}"; continue
  fi
  mkdir -p "$bak$(dirname "$p")"; cp -a -- "$p" "$bak$p" 2>/dev/null
  if tar -xzpf "$t/files.tar.gz" -C / "$rel"; then echo "zurueckgespielt: $p (vorherige Fassung: $bak$p)"; else echo "FEHLER beim Zurueckspielen: $p"; rc=1; fi
done
echo "Danach: systemctl daemon-reload; betroffene Dienste NICHT waehrend der Wiedergabe neu starten."
exit "$rc"
