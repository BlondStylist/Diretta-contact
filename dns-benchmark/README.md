# DNS-Anbieter-Test: Sicherheit & Geschwindigkeit (für zuhause)

Aktiver Vergleich von 15 öffentlichen DNS-Resolvern auf **Sicherheit** (DNSSEC-Validierung,
Malware-/Werbe-/Jugendschutz-Filter, kein NXDOMAIN-Hijacking, verschlüsselter Transport) und
**Geschwindigkeit**.

> **Interaktives Dashboard:** [`report.html`](./report.html) (Tabelle + Grafiken, Light/Dark).

---

## ⚠️ Ehrlicher Mess-Hinweis — bitte zuerst lesen

Dieser Test wurde in einer **Cloud-Umgebung (Google, Columbus/Ohio, USA)** ausgeführt, **nicht**
an deinem Standort. Zwei **nachgewiesene** Gründe machen eine _Geschwindigkeits_-Messung für dein
Zuhause von dort aus unmöglich:

1. **Transparentes DNS-Hijacking:** Die Umgebung fängt **allen** klassischen DNS-Verkehr (UDP/53)
   ab und beantwortet ihn selbst. Belegt dadurch, dass sogar Anfragen an `1.2.3.4` und reservierte
   TEST-NET-Adressen (die keine DNS-Server sind) „Antworten" lieferten. Alle Provider sahen dadurch
   identisch aus.
2. **Falscher Standort:** DNS-Latenz ist praktisch nur die Netz-Entfernung zwischen **dir** und dem
   Resolver. Eine Messung aus Ohio sagt nichts über deine Leitung.

**Konsequenz & Lösung:**
- **Sicherheit** = Anbieter-Eigenschaft, **standortunabhängig** → hier **real gemessen** (via
  DNS-over-HTTPS, das die echten Anbieter erreicht) und **auch für dich gültig**.
- **Geschwindigkeit** = **lokal** zu messen → dafür liegt [`dns_speed_test.py`](./dns_speed_test.py)
  bei (nur Python 3, keine Installation). Es erkennt sogar, ob **dein** Router DNS umleitet.

Warum die Sicherheitsmessung trotz Hijacking valide ist: Anfragen liefen über **DoH** zu den echten
Anbieter-Hostnamen. Beleg: `whoami.cloudflare` lieferte den Cloudflare-Node `iad19`, und die Filter
reagierten anbieter-korrekt (z. B. Cloudflare Family → `pornhub.com = 0.0.0.0`, AdGuard →
`doubleclick.net = 0.0.0.0`).

---

## 🏆 Empfehlung für zuhause (DACH)

| Bedarf | Anbieter | IPv4 | Warum |
|---|---|---|---|
| **Sicherheit + Datenschutz (EU)** | **Quad9** | `9.9.9.9` · `149.112.112.112` | Gemessen stärkster Malware-/Phishing-Schutz, DNSSEC, DoH/DoT, Schweizer Non-Profit, GDPR, kein Overblocking |
| **Speed + Malware-Schutz** | **Cloudflare** | `1.1.1.2` | Schnellste Anycast-Infrastruktur (DACH meist top), DNSSEC, DoH/DoT, kein Datenverkauf |
| Reiner Speed, ohne Filter | Cloudflare | `1.1.1.1` · `1.0.0.1` | Wie oben, ohne Filterung |
| Werbung/Tracker blocken | AdGuard / Mullvad | `94.140.14.14` / `194.242.2.3` | Gemessen stärkstes Ad-Blocking (Mullvad 3/3) |
| Familie / Jugendschutz | Cloudflare Family / CleanBrowsing | `1.1.1.3` / `185.228.168.168` | Gemessen zuverlässige Adult-Sperre + Malware |

**Kurzfassung:** Nimm **Quad9 (9.9.9.9)** für maximale Sicherheit mit EU-Datenschutz **oder**
**Cloudflare (1.1.1.2)** für Top-Speed mit Malware-Schutz. Beide validieren DNSSEC und fälschen keine
Antworten — entscheide per lokalem Speed-Test, welcher auf deiner Leitung schneller ist.

---

## 🔒 Sicherheits- & Filter-Matrix (real gemessen via DoH)

Legende: ✓ = gemessen aktiv · – = nicht aktiv/offen · `doc` = laut Anbieter-Doku (hier nicht
auslösbar) · Pips `●●○` = geblockte Testdomains je Kategorie.

| Anbieter | IPv4 | DNSSEC | DoH | DoT | kein NX-Hijack | Malware/Phishing | Werbung/Tracker | Jugendschutz | Sitz · Datenschutz |
|---|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|---|
| Cloudflare | `1.1.1.1` | ✓ | ✓ | doc | ✓ | – | – | – | 🇺🇸 US · kein Verkauf, KPMG-Audit |
| Cloudflare Malware | `1.1.1.2` | ✓ | ✓ | doc | ✓ | doc¹ | – | – | 🇺🇸 US |
| Cloudflare Family | `1.1.1.3` | ✓ | ✓ | doc | ✓ | doc¹ | – | ✓ `●●` | 🇺🇸 US |
| Google | `8.8.8.8` | ✓ | ✓ | doc | ✓ | – | – | – | 🇺🇸 US · anonym. Logs ~24–48 h |
| **Quad9** | `9.9.9.9` | ✓ | ✓ | doc | ✓ | **✓ `●●`** | – | – | 🇨🇭 CH · Non-Profit, keine PII, GDPR |
| OpenDNS Home | `208.67.222.222` | ✓ | ✓ | doc | ✓ | ✓ `●○` | – | – | 🇺🇸 US · Cisco, loggt |
| OpenDNS FamilyShield | `208.67.222.123` | ✓ | ✓ | doc | ✓ | ✓ `●○` | – | ✓ `●●` | 🇺🇸 US · Cisco, loggt |
| AdGuard | `94.140.14.14` | ✓ | ✓ | doc | ✓ | – | **✓ `●●○`** | – | 🇨🇾 Zypern (EU) · keine PII |
| AdGuard Family | `94.140.14.15` | ✓ | ✓ | doc | ✓ | – | ✓ `●●○` | ✓ `●●` | 🇨🇾 Zypern (EU) |
| CleanBrowsing Security | `185.228.168.9` | ✓ | ✓ | doc | ✓ | **✓ `●●`** | – | – | 🇺🇸 US · minimale Logs |
| CleanBrowsing Family | `185.228.168.168` | ✓ | ✓ | doc | ✓ | **✓ `●●`** | – | ✓ `●●` | 🇺🇸 US |
| Mullvad | `194.242.2.2` | ✓ | ✓ | doc | ✓ | – | – | – | 🇸🇪 Schweden (EU) · no-log, kein ECS |
| Mullvad AdBlock | `194.242.2.3` | ✓ | ✓ | doc | ✓ | – | **✓ `●●●`** | – | 🇸🇪 Schweden (EU) |

¹ Cloudflare 1.1.1.2/1.1.1.3 filtern laut Anbieter Malware/Phishing; meine (Cisco/OpenDNS-orientierten)
Testdomains lösten es nicht aus, und Cloudflare hat keine offizielle öffentliche Test-Malware-Domain →
daher `doc` statt gemessenem ✓. DoT (Port 853) war aus der Cloud gesperrt und wird von allen Anbietern
laut Doku unterstützt.

### Gemessene Filterstärke (Anteil geblockter Testdomains)

**Werbung/Tracker** (3 Domains: doubleclick, googleadservices, pubmatic)
- Mullvad AdBlock — **3/3**
- AdGuard / AdGuard Family — **2/3**
- alle übrigen — 0/3

**Malware/Phishing** (2 valide Domains: internetbadguys, examplemalwaredomain)
- Quad9, CleanBrowsing (Security & Family) — **2/2**
- OpenDNS (Home & FamilyShield) — **1/2**
- Cloudflare 1.1.1.2/1.1.1.3 — laut Doku aktiv, Testdomains nicht ausgelöst

> Kontroll-Domain `examplephishingdomain.com` wurde von *allen* „geblockt" → autoritativ nicht
> existent, kein echtes Filtersignal, deshalb aus der Wertung genommen.

---

## 🧪 Methodik

| Aspekt | Details |
|---|---|
| Werkzeuge | `dnspython` (UDP/53), `curl --http2` (DNS-over-HTTPS) |
| Sicherheit | DNSSEC (`dnssec-failed.org` → SERVFAIL = validiert), AD-Flag, Filter-Verhalten je Kategorie, NXDOMAIN-Handling, DoH-Erreichbarkeit |
| Testabfragen | > 2.400 (Latenzversuch + Sicherheit) |
| Messpunkt | GCP Columbus/Ohio → echte Anbieter via DoH |
| Rohdaten | [`results/security_real.json`](./results/security_real.json) |

Skripte:
- [`security_doh.py`](./security_doh.py) — reproduziert die Sicherheitsmessung (via DoH).
- [`dns_speed_test.py`](./dns_speed_test.py) — **lokaler** Geschwindigkeitstest für deinen Standort.

---

## ⚡ Geschwindigkeit lokal messen

```bash
# nur Python 3 nötig, keine Installation
python3 dns_speed_test.py

# stabiler + eigenen Router mittesten:
python3 dns_speed_test.py --rounds 15 --extra 192.168.1.1=Router
```

Ausgabe: sortierte Tabelle (min / median / mittel / p95 / max / Verlustrate) je Anbieter, plus
`dns_speed_results.csv` und `.json`. Das Tool warnt automatisch, falls **dein** Netz DNS umleitet
(dann wäre die Messung verfälscht — genau das ist in der Cloud passiert).

**Worauf achten:** nicht der Bestwert zählt, sondern **Median + p95 + Ausfallrate**. In Mitteleuropa
liegen Cloudflare/Google/Quad9 dank lokaler Knoten (Frankfurt/Amsterdam/Zürich) meist unter 20 ms.
