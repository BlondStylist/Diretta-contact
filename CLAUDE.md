# CLAUDE.md

## Was dieses Repository ist

Ein reines **Übergabe-/Kontakt-Repository** für die **deutsche Übersetzung** des Leitfadens
`translations/Diretta-de.md` aus dem Upstream-Projekt
[`dsnyder0pc/rpi-for-roon`](https://github.com/dsnyder0pc/rpi-for-roon)
(Aufbau einer dedizierten Diretta-Verbindung mit AudioLinux auf dem Raspberry Pi).

Hier liegt **kein Code**, kein Build, keine Tests. Der Inhalt besteht aus ZIP-Archiven,
die als Anhang an den Upstream-Maintainer weitergegeben werden.

## Inhalt

| Datei | Inhalt |
|---|---|
| `Diretta-de.zip` | `Diretta-de.md` – korrigierte deutsche Fassung (2.957 Zeilen) |
| `Diretta-de-translation-fixes-2026-06-21.zip` | `README.md` (Review-/PR-Text), `Diretta-de.patch` (Git-Patch gegen `translations/Diretta-de.md`), `Diretta-de.md` (identisch mit dem aus `Diretta-de.zip`) |
| `TRANSLATION-REVIEW-de.zip` | `TRANSLATION-REVIEW-de.md` – identisch mit dem `README.md` des Fixes-Archivs |

Die drei Archive überschneiden sich also bewusst; sie sind unterschiedlich geschnürte
Versandpakete desselben Stands (Stand 2026-06-21).

## Regeln für Änderungen an der Übersetzung

Diese Zusagen sind im Review-Dokument dokumentiert und müssen bei jeder weiteren
Korrektur eingehalten werden:

- **Code-Blöcke bleiben unangetastet** – jeder ` ``` `-Block ist byteweise identisch mit
  dem englischen Original. Nur Fließtext, Überschriften und Markdown-Linkziele ändern.
- **Zeilenanzahl bleibt konstant** (2.957 Zeilen), damit Zeilennummern im Review-Dokument
  weiter stimmen. Keine Zeilen hinzufügen oder entfernen.
- **Interne Anker müssen aufgelöst werden** – Links auf Abschnitte zeigen auf die
  deutschen Anker (z. B. `#52-das-diretta-target-vorkonfigurieren`), nicht auf die
  englischen Anker im Upstream-Repo.
- **Konsistente Terminologie**: „Schritt N“ (nicht „Step N“), „Teil N“ (nicht „Part N“),
  „Diretta-Host“ / „Diretta-Target“ bleiben unübersetzt als Eigennamen.
  Der Anglizismus „Copy-and-Paste“ ist bewusst beibehalten.
- Jede Änderung wird im Review-Dokument (`TRANSLATION-REVIEW-de.md` bzw. das
  gleichlautende `README.md`) mit Zeilennummer, Vorher und Nachher nachgetragen.

## Übliche Arbeitsschritte

```bash
# Archive zur Bearbeitung auspacken (außerhalb des Repos, z. B. im Scratchpad)
unzip -q Diretta-de.zip -d /tmp/work

# Patch gegen ein Checkout des Upstream-Repos prüfen/anwenden
git apply --check Diretta-de.patch
git apply Diretta-de.patch

# Nach Änderungen neu schnüren (Verzeichnisname = Archivname ohne .zip)
zip -qr Diretta-de.zip Diretta-de/
```

Wenn der Inhalt eines Archivs geändert wird, müssen die überlappenden Kopien in den
anderen Archiven mitgezogen werden (siehe Tabelle oben), sonst laufen die Pakete auseinander.

## Sprache

Kommunikation, Commit-Messages und Dokumentation auf **Deutsch**.
