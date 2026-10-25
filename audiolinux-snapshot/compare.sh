#!/usr/bin/env bash
# Vergleicht zwei Snapshots (snapshot-*.tar.gz): stabile Berichte per diff, Dateien per Pruefsumme.
# Usage: bash compare.sh vorher.tar.gz nachher.tar.gz        Exit: 0 identisch | 1 Unterschiede | 2 Aufruf/Archiv | 3 Werkzeug fehlt
set -uo pipefail
need=(tar gzip diff awk sort mktemp grep); for c in "${need[@]}"; do command -v "$c" >/dev/null 2>&1 || { echo "Fehlendes Werkzeug: $c (Arch: pacman -S diffutils coreutils tar gzip gawk)" >&2; exit 3; }; done
[[ $# -eq 2 && -f $1 && -f $2 ]] || { echo "Usage: $0 vorher.tar.gz nachher.tar.gz (beide muessen existieren)" >&2; exit 2; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; mkdir "$t/a" "$t/b"
for i in a b; do src="$1"; [[ $i == b ]] && src="$2"
  tar -xzf "$src" -C "$t/$i" --strip-components=1 2>/dev/null && [[ -f $t/$i/manifest.sha256 ]] || { echo "Kein gueltiger Snapshot: $src" >&2; exit 2; }
done
diffs=0
if [[ -d $t/a/report && -d $t/b/report ]]; then
  echo "=== Berichte (nur Unterschiede) ==="
  for f in "$t"/a/report/*.txt; do n="$(basename "$f")"; echo "--- $n"
    d="$(diff -u -- "$f" "$t/b/report/$n" 2>&1 | tail -n +3)"; [[ -n $d ]] && { echo "$d"; diffs=1; }
  done
else
  echo "=== Berichte: uebersprungen (ein Archiv stammt von image-snapshot.sh und hat keinen Laufzeitbericht) ==="
fi
echo "=== Dateien (Pruefsummen) ==="
files="$(awk 'NR==FNR{o[substr($0,67)]=substr($0,1,64);next} {p=substr($0,67);n[p]=substr($0,1,64)} END{for(p in o)if(!(p in n))print "REMOVED",p;else if(o[p]!=n[p])print "CHANGED",p;for(p in n)if(!(p in o))print "ADDED  ",p}' "$t/a/manifest.sha256" "$t/b/manifest.sha256" | sort -k2)"
[[ -n $files ]] && { echo "$files"; diffs=1; }
pn="$(grep -E '^(ADDED|CHANGED) .*\.(pacnew|pacsave)$' <<<"$files")"
[[ -n $pn ]] && { echo "=== .pacnew/.pacsave: von Hand pruefen, nie blind uebernehmen ==="; echo "$pn"; }
exit "$diffs"
