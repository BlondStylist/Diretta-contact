#!/usr/bin/env bash
# Spielt einzelne Dateien/Ordner aus einem Snapshot zurueck. Standard ist Trockenlauf; aktuelle Datei wird vorher gesichert.
# Usage: [DRY_RUN=0] sudo bash restore.sh snapshot-*.tar.gz /abs/pfad [/abs/pfad ...]
set -uo pipefail
[[ $EUID -eq 0 && $# -ge 2 ]] || { echo "Usage: sudo [DRY_RUN=0] bash $0 snapshot.tar.gz /abs/pfad..." >&2; exit 2; }
snap="$(readlink -f "$1")"; shift; t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
tar -xzf "$snap" -C "$t" --strip-components=1 --wildcards '*/files.tar.gz' || exit 3
bak="/root/config-archiv/pre-restore-$(date +%Y%m%d-%H%M%S)"
for p in "$@"; do
  case "$p" in /opt/scripts*|/usr*|/var/lib/pacman*|/lib*) echo "ABGELEHNT: $p (Menue-/Paketcode nie zurueckspielen)"; continue;; esac
  if ! tar -tzf "$t/files.tar.gz" "${p#/}" >/dev/null 2>&1; then echo "nicht im Snapshot: $p"; continue; fi
  if [[ ${DRY_RUN:-1} == 1 ]]; then echo "[Trockenlauf] wuerde zuruecksetzen: $p"; diff -ru <(tar -xzOf "$t/files.tar.gz" "${p#/}" 2>/dev/null) "$p" 2>/dev/null | head -20; continue; fi
  mkdir -p "$bak$(dirname "$p")"; cp -a "$p" "$bak$p" 2>/dev/null
  tar -xzpf "$t/files.tar.gz" -C / "${p#/}" && echo "zurueckgespielt: $p (Sicherung: $bak$p)"
done
echo "Danach: systemctl daemon-reload; betroffene Dienste NICHT waehrend der Wiedergabe neu starten."
