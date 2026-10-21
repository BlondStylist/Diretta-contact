#!/usr/bin/env bash
# Vergleicht zwei Snapshots (snapshot-*.tar.gz): stabile Berichte per diff, Dateien per Pruefsumme.
# Usage: bash compare.sh vorher.tar.gz nachher.tar.gz
set -uo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 vorher.tar.gz nachher.tar.gz" >&2; exit 2; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir "$t/a" "$t/b"; tar -xzf "$1" -C "$t/a" --strip-components=1; tar -xzf "$2" -C "$t/b" --strip-components=1
echo "=== Berichte (nur Unterschiede) ==="
for f in "$t"/a/report/*.txt; do n="$(basename "$f")"; echo "--- $n"; diff -u "$f" "$t/b/report/$n" | tail -n +3; done
echo "=== Dateien (Pruefsummen) ==="
awk 'NR==FNR{o[substr($0,67)]=substr($0,1,64);next} {p=substr($0,67);n[p]=substr($0,1,64)} END{for(p in o)if(!(p in n))print "REMOVED",p;else if(o[p]!=n[p])print "CHANGED",p;for(p in n)if(!(p in o))print "ADDED  ",p}' "$t/a/manifest.sha256" "$t/b/manifest.sha256" | sort -k2
