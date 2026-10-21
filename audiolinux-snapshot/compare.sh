#!/usr/bin/env bash
# Vergleicht zwei Snapshots (snapshot-*.tar.gz): stabile Berichte per diff, Dateien per Pruefsumme.
# Usage: bash compare.sh vorher.tar.gz nachher.tar.gz        Exit: 0 identisch | 1 Unterschiede | 2 Aufruf/Archiv
set -uo pipefail
[[ $# -eq 2 && -f $1 && -f $2 ]] || { echo "Usage: $0 vorher.tar.gz nachher.tar.gz (beide muessen existieren)" >&2; exit 2; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; mkdir "$t/a" "$t/b"
for i in a b; do src="$1"; [[ $i == b ]] && src="$2"
  tar -xzf "$src" -C "$t/$i" --strip-components=1 2>/dev/null && [[ -d $t/$i/report && -f $t/$i/manifest.sha256 ]] || { echo "Kein gueltiger Snapshot: $src" >&2; exit 2; }
done
diffs=0
echo "=== Berichte (nur Unterschiede) ==="
for f in "$t"/a/report/*.txt; do n="$(basename "$f")"; echo "--- $n"
  d="$(diff -u -- "$f" "$t/b/report/$n" 2>&1 | tail -n +3)"; [[ -n $d ]] && { echo "$d"; diffs=1; }
done
echo "=== Dateien (Pruefsummen) ==="
files="$(awk 'NR==FNR{o[substr($0,67)]=substr($0,1,64);next} {p=substr($0,67);n[p]=substr($0,1,64)} END{for(p in o)if(!(p in n))print "REMOVED",p;else if(o[p]!=n[p])print "CHANGED",p;for(p in n)if(!(p in o))print "ADDED  ",p}' "$t/a/manifest.sha256" "$t/b/manifest.sha256" | sort -k2)"
[[ -n $files ]] && { echo "$files"; diffs=1; }
exit "$diffs"
