#!/usr/bin/env python3
"""mutationstest.py - prueft, ob die Testsuite der Snapshot-Werkzeuge WIRKSAM ist.

Ein gruener Testlauf sagt nur, dass die Tests zum Code passen. Hier wird jeweils ein
Fehler gezielt eingebaut (Mutant); die zustaendigen Testlaeufe muessen ihn bemerken.
Ein ueberlebender Mutant ist eine Testluecke.

Aufruf:  SNAPSHOT_TEST=1 python3 -I tests/mutationstest.py [--lauf lauf6] [--nur NAME]
Rueckgabe: 0 alle erkannt | 1 Mutant ueberlebt | 2 Mutation nicht anwendbar | 77 uebersprungen
Hinweis: Die Testsuite veraendert /etc, /opt und /home (legt Testnutzer an). Nur in einer
Wegwerfumgebung starten (Container, VM oder Sandbox von audit-alles.sh).
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

QUELLE = Path(__file__).resolve().parent.parent

# (Name, Datei, gesuchter Text, Ersatz, zustaendige Testlaeufe). Ersatz kann ein Aufruf sein
# (Regex-Ersetzung), wenn der gesuchte Text mit "re:" beginnt.
M = [
    ("label-ungefiltert", "snapshot.sh", '''label="${label//[^A-Za-z0-9._-]/_}";''', "", ["lauf2"]),
    ("realpath-weg", "restore.sh", '''p="$(realpath -m -- "$arg")"''', '''p="$arg"''', ["lauf3"]),
    ("ssh-ordner-komplett", "snapshot.sh", "/home/audiolinux/.ssh/config", "/home/audiolinux/.ssh", ["lauf2"]),
    ("kernbindung-weg", "snapshot.sh", "taskset -pc 0,1 $$ >/dev/null 2>&1;", "", ["lauf4"]),
    ("platzpruefung-weg", "snapshot.sh",
     '|| { echo "Weniger als 200 MB frei in $OUT_BASE" >&2; exit 7; }', "|| true", ["lauf4"]),
    ("compare-ignoriert-changed", "compare.sh", '''else if(o[p]!=n[p])print "CHANGED",p;''', "", ["lauf2"]),
    ("restore-ohne-force-schutz", "restore.sh", "/etc/fstab|/boot|/boot/*)", "/etc/zz-nie)", ["lauf3"]),
    ("hup-schutz-weg", "snapshot.sh", "trap '' HUP", "true", ["lauf6"]),
    ("sync-weg", "snapshot.sh", "\nsync ", "\ntrue ", ["lauf6"]),
    ("ramroot-warnung-weg", "snapshot.sh", '*) echo "WARNUNG: Root-Dateisystem', '*) true "WARNUNG: Root-Dateisystem', ["lauf6"]),
    ("entpacktes-verzeichnis-bleibt", "snapshot.sh", '; rm -rf -- "$D"      # nur', "; true      # nur", ["lauf6"]),
    ("shadow-nicht-ausgeschlossen", "snapshot.sh", "--exclude='etc/shadow*' ", "", ["lauf7"]),
    ("hostschluessel-nicht-ausgeschlossen", "snapshot.sh", "--exclude='etc/ssh/ssh_host_*' ", "", ["lauf7"]),
    ("symlinks-nicht-im-manifest", "snapshot.sh", r're:  \( cd "\$sx" && find \. -type l.*\n', "", ["lauf7"]),
    ("nur-alte-pfadliste", "snapshot.sh", "paths=(/etc /var/spool", "paths=(/etc/systemd /var/spool", ["lauf7"]),
    ("kopie-als-root", "snapshot.sh",
     'if command -v setpriv >/dev/null 2>&1; then setpriv --reuid=audiolinux --regid=audiolinux --init-groups "$@"; else runuser -u audiolinux -- "$@"; fi',
     '"$@"', ["lauf5"]),
    ("restore-ohne-probeentpacken", "restore.sh",
     'if ! tar -xzpf "$t/files.tar.gz" -C "$t/x" "$rel" 2>"$t/err"; then', "if false; then", ["lauf5"]),
    ("compare-ohne-pacnew-abschnitt", "compare.sh", "pacnew|pacsave", "zzzz", ["lauf7"]),
    ("pflichtwerkzeugpruefung-weg", "snapshot.sh", "(( ${#miss[@]} == 0 )) ||", "true ||", ["lauf4"]),
    ("compare-ohne-diff-pruefung", "compare.sh", "need=(tar gzip diff awk", "need=(tar gzip awk", ["lauf4"]),
    ("config-block-unten", "laptop-setup.sh", '{ config_block; echo; cat "$alt"; }', '{ cat "$alt"; echo; config_block; }', ["lauf9"]),
    ("stash-ohne-untracked", "laptop-setup.sh", "stash push -u -m", "stash push -m", ["lauf9"]),
    ("schluessel-wird-ueberschrieben", "laptop-setup.sh", 'if [ -f "$KEY" ]; then echo "  vorhanden', 'if false; then echo "  vorhanden', ["lauf9"]),
    ("repo-ohne-rueckfrage-stash", "laptop-setup.sh", '[ "$JA" -eq 1 ] && return 0', "return 0", ["lauf9"]),
    ("check-meldet-fehlende-nicht", "snapshot.sh", "exit $(( fehlt ? 3 : 0 ))", "exit 0", ["lauf4"]),
    ("image-rw-gemountet", "image-snapshot.sh", "mount -t ext4 -o ro,noload,loop", "mount -t ext4 -o rw,loop", ["lauf10"]),
    ("image-excl-ohne-shadow", "image-snapshot.sh", "--exclude='etc/shadow*' ", "", ["lauf10"]),
    ("image-pfadliste-abweichend", "image-snapshot.sh", "paths=(/etc /var/spool", "paths=(/etc/systemd /var/spool", ["lauf10"]),
    ("image-name-nicht-eindeutig", "image-snapshot.sh", "while [[ -e \"$OUT_BASE/$name\" ||", "while false &&", ["lauf10"]),
    ("image-suche-ohne-mindestgroesse", "image-snapshot.sh", '-size +"${MIN_KB:-200000}"k', "-size +0k", ["lauf10"]),
    ("compare-ohne-image-toleranz", "compare.sh", "if [[ -d $t/a/report && -d $t/b/report ]]; then", "if true; then", ["lauf10"]),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lauf", help="nur Mutanten, die diesen Testlauf benutzen")
    ap.add_argument("--nur", help="nur den Mutanten mit diesem Namen")
    a = ap.parse_args()
    if os.environ.get("SNAPSHOT_TEST") != "1" or os.geteuid() != 0:
        print("uebersprungen: braucht root und SNAPSHOT_TEST=1 (Wegwerfumgebung)")
        return 77
    wahl = [m for m in M if (not a.lauf or a.lauf in m[4]) and (not a.nur or a.nur == m[0])]
    ueberlebt, unanwendbar = [], []
    with tempfile.TemporaryDirectory(prefix="mutanten-") as tmp:
        for i, (name, datei, alt, neu, laeufe) in enumerate(wahl, 1):
            ziel = Path(tmp) / f"m{i}"
            shutil.copytree(QUELLE, ziel)
            p = ziel / datei
            text = p.read_text()
            if alt.startswith("re:"):
                neu_text, n = re.subn(alt[3:], neu, text, count=1)
            else:
                n = text.count(alt)
                neu_text = text.replace(alt, neu, 1)
            if n == 0 or neu_text == text:
                print(f"[{i}/{len(wahl)}] {name}: NICHT ANWENDBAR (Muster nicht gefunden)")
                unanwendbar.append(name)
                continue
            p.write_text(neu_text)
            fehler = 0
            for lauf in laeufe:
                try:   # nie auf Eingaben warten: kein Terminal, Zeitgrenze; ein haengender Test gilt als Fehlschlag
                    r = subprocess.run(["bash", "tests/run-tests.sh", lauf], cwd=ziel, capture_output=True, text=True,
                                       stdin=subprocess.DEVNULL, env={**os.environ, "SNAPSHOT_TEST": "1"},
                                       timeout=300, check=False)
                    fehler += sum(1 for z in r.stdout.splitlines() if z.startswith("FAIL"))
                except subprocess.TimeoutExpired:
                    fehler += 1
                    print(f"      ({lauf}: Zeitgrenze erreicht, als erkannt gewertet)")
            status = "erkannt" if fehler else "UEBERLEBT"
            print(f"[{i}/{len(wahl)}] {name} ({','.join(laeufe)}): {fehler} Test(s) schlagen an -> {status}", flush=True)
            if not fehler:
                ueberlebt.append(name)
    print(f"\n{len(wahl) - len(ueberlebt) - len(unanwendbar)} erkannt, {len(ueberlebt)} ueberlebt, {len(unanwendbar)} nicht anwendbar")
    if unanwendbar:
        print("nicht anwendbar:", ", ".join(unanwendbar))
        return 2
    if ueberlebt:
        print("ueberlebt:", ", ".join(ueberlebt))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
