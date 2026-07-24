#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dns_speed_test.py  —  Lokaler DNS-Geschwindigkeits- und Zuverlaessigkeitstest.

WARUM lokal ausfuehren?
    DNS-Latenz haengt fast vollstaendig von der Entfernung/Netzstrecke zwischen
    DIR und dem Resolver ab. Sie MUSS daher an deinem Standort, in deinem Netz
    gemessen werden. Eine Messung aus einem Rechenzentrum (z. B. Cloud) ist fuer
    deinen Standort nicht repraesentativ.

Was das Tool macht:
    * misst pro Resolver echte Query-Zeiten (UDP/53) ueber viele Iterationen
    * nutzt eine Mischung populaerer + deutschsprachiger Domains
    * erkennt, ob dein Netz/Router DNS-Anfragen umleitet ("DNS-Hijacking")
    * gibt eine sortierte Tabelle (min / median / mittel / p95 / max / Verlust)
      sowie CSV + JSON aus

Voraussetzungen: nur Python 3 (Standardbibliothek) — keine Installation noetig.
Aufruf:
    python3 dns_speed_test.py
    python3 dns_speed_test.py --rounds 15 --extra 1.2.3.4=MeinRouter
"""
import argparse, csv, json, random, socket, statistics, struct, sys, time

# ---------------------------------------------------------------------------
# Zu testende Resolver:  IP -> (Anzeigename, Kategorie)
# ---------------------------------------------------------------------------
RESOLVERS = [
    ("1.1.1.1",         "Cloudflare",             "Speed/Privacy"),
    ("1.0.0.1",         "Cloudflare #2",          "Speed/Privacy"),
    ("1.1.1.2",         "Cloudflare Malware",     "Filter: Malware"),
    ("1.1.1.3",         "Cloudflare Family",      "Filter: Malware+Adult"),
    ("8.8.8.8",         "Google",                 "Speed"),
    ("8.8.4.4",         "Google #2",              "Speed"),
    ("9.9.9.9",         "Quad9",                  "Filter: Malware+DNSSEC"),
    ("149.112.112.112", "Quad9 #2",               "Filter: Malware+DNSSEC"),
    ("208.67.222.222",  "OpenDNS",                "Filter: Security"),
    ("208.67.222.123",  "OpenDNS FamilyShield",   "Filter: Adult"),
    ("94.140.14.14",    "AdGuard",                "Filter: Ads+Tracker"),
    ("94.140.14.15",    "AdGuard Family",         "Filter: Ads+Adult"),
    ("185.228.168.9",   "CleanBrowsing Security", "Filter: Security"),
    ("76.76.2.0",       "ControlD",               "Privacy/Filter"),
    ("194.242.2.2",     "Mullvad",                "Privacy (EU)"),
    ("84.200.69.80",    "DNS.WATCH (DE)",         "Privacy/Kein Filter"),
    ("4.2.2.2",         "Level3",                 "Kein Filter"),
]

# Domain-Mix: populaer international + deutschsprachig (Standort DACH)
DOMAINS = [
    "google.com", "youtube.com", "wikipedia.org", "amazon.de", "microsoft.com",
    "apple.com", "github.com", "cloudflare.com", "netflix.com", "spiegel.de",
    "bild.de", "gmx.net", "web.de", "t-online.de", "ard.de",
]

def build_query(qname, qid, rd=True):
    """Minimales DNS-A-Query-Paket (RFC 1035) — reine Standardbibliothek."""
    header = struct.pack(">HHHHHH", qid, 0x0100 if rd else 0, 1, 0, 0, 0)
    q = b"".join(bytes([len(p)]) + p.encode() for p in qname.split("."))
    return header + q + b"\x00" + struct.pack(">HH", 1, 1)  # QTYPE=A, QCLASS=IN

def query_once(server, qname, timeout=2.0):
    """Eine UDP-Query. Rueckgabe: Zeit in ms oder None (Fehler/Timeout)."""
    qid = random.randint(0, 0xFFFF)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        pkt = build_query(qname, qid)
        t0 = time.perf_counter()
        s.sendto(pkt, (server, 53))
        while True:                       # passe Antwort-ID abwarten
            data, _ = s.recvfrom(4096)
            if len(data) >= 4 and struct.unpack(">H", data[:2])[0] == qid:
                return (time.perf_counter() - t0) * 1000.0
    except Exception:
        return None
    finally:
        s.close()

def detect_system_resolver():
    """Aktuellen Resolver ermitteln (Linux/macOS via /etc/resolv.conf)."""
    try:
        with open("/etc/resolv.conf") as f:
            for line in f:
                line = line.strip()
                if line.startswith("nameserver"):
                    return line.split()[1]
    except Exception:
        pass
    return None

def check_hijacking():
    """
    Prueft, ob das lokale Netz DNS umleitet: Eine Anfrage an eine IP, die KEIN
    DNS-Server ist (RFC-5737-Testnetz), darf NIE beantwortet werden.
    Antwortet sie doch -> transparentes DNS-Hijacking durch Router/ISP.
    """
    for bogus in ("203.0.113.5", "198.51.100.7"):
        if query_once(bogus, "example.com", timeout=2.0) is not None:
            return True
    return False

def pctl(sorted_vals, p):
    if not sorted_vals: return None
    k = min(len(sorted_vals) - 1, int(round(p * (len(sorted_vals) - 1))))
    return sorted_vals[k]

def bar(value, vmax, width=22):
    if value is None or vmax <= 0: return ""
    n = int(round(width * value / vmax))
    return "#" * max(0, min(width, n))

def main():
    ap = argparse.ArgumentParser(description="Lokaler DNS-Geschwindigkeitstest")
    ap.add_argument("--rounds", type=int, default=12, help="Messrunden je Domain (Standard 12)")
    ap.add_argument("--timeout", type=float, default=2.0, help="Timeout pro Query in s")
    ap.add_argument("--extra", action="append", default=[],
                    help="Zusaetzlicher Resolver  IP=Name  (mehrfach moeglich)")
    args = ap.parse_args()

    resolvers = list(RESOLVERS)
    sysr = detect_system_resolver()
    if sysr and not any(sysr == ip for ip, *_ in resolvers):
        resolvers.insert(0, (sysr, "Dein aktueller Resolver", "aktuell"))
    for ex in args.extra:
        if "=" in ex:
            ip, name = ex.split("=", 1); resolvers.append((ip, name, "custom"))

    print("=" * 78)
    print(" Lokaler DNS-Geschwindigkeitstest".center(78))
    print("=" * 78)
    print(f" Resolver: {len(resolvers)}   Domains: {len(DOMAINS)}   Runden: {args.rounds}"
          f"   Queries gesamt: {len(resolvers)*len(DOMAINS)*args.rounds}")
    if sysr: print(f" Dein aktueller Resolver (System): {sysr}")

    if check_hijacking():
        print("\n  !!! WARNUNG: Dein Netzwerk/Router leitet DNS-Anfragen um "
              "(DNS-Hijacking).")
        print("      Die Ergebnisse messen dann NICHT die echten Anbieter. "
              "Deaktiviere\n      DNS-Umleitung/Filter im Router oder teste per "
              "DoH/DoT-faehigem Client.\n")
    else:
        print(" Kein DNS-Hijacking erkannt — Messung erreicht die echten Anbieter.\n")

    # Warmup (Cache + Netzpfad anwaermen)
    print(" Warmup ...", flush=True)
    for ip, *_ in resolvers:
        for d in DOMAINS:
            query_once(ip, d, args.timeout)

    timings = {ip: [] for ip, *_ in resolvers}
    fails   = {ip: 0  for ip, *_ in resolvers}
    attempts= {ip: 0  for ip, *_ in resolvers}
    for rnd in range(args.rounds):
        order = resolvers[rnd % len(resolvers):] + resolvers[:rnd % len(resolvers)]
        for d in DOMAINS:
            for ip, *_ in order:
                attempts[ip] += 1
                t = query_once(ip, d, args.timeout)
                if t is None: fails[ip] += 1
                else: timings[ip].append(t)
        print(f"  Runde {rnd+1}/{args.rounds} fertig", flush=True)

    rows = []
    for ip, name, cat in resolvers:
        ts = sorted(timings[ip]); n = len(ts)
        loss = 100.0 * fails[ip] / attempts[ip] if attempts[ip] else 100.0
        rows.append({
            "ip": ip, "name": name, "category": cat, "samples": n,
            "loss_pct": round(loss, 1),
            "min_ms":    round(ts[0], 2) if n else None,
            "median_ms": round(statistics.median(ts), 2) if n else None,
            "mean_ms":   round(statistics.fmean(ts), 2) if n else None,
            "p95_ms":    round(pctl(ts, 0.95), 2) if n else None,
            "max_ms":    round(ts[-1], 2) if n else None,
            "stdev_ms":  round(statistics.pstdev(ts), 2) if n > 1 else 0.0,
        })
    ranked = sorted(rows, key=lambda r: (r["median_ms"] is None, r["median_ms"] or 9e9))
    vmax = max((r["median_ms"] or 0) for r in ranked) or 1

    print("\n" + "=" * 108)
    print(f'{"#":>2}  {"Anbieter":24}{"IP":17}{"min":>7}{"median":>8}{"mittel":>8}'
          f'{"p95":>8}{"max":>8}{"Verl%":>7}  Median')
    print("-" * 108)
    for i, r in enumerate(ranked, 1):
        if r["median_ms"] is None:
            print(f'{i:>2}  {r["name"]:24}{r["ip"]:17}{"—":>7}{"AUSFALL":>8}')
            continue
        print(f'{i:>2}  {r["name"]:24}{r["ip"]:17}'
              f'{r["min_ms"]:7.1f}{r["median_ms"]:8.1f}{r["mean_ms"]:8.1f}'
              f'{r["p95_ms"]:8.1f}{r["max_ms"]:8.1f}{r["loss_pct"]:7.1f}  '
              f'{bar(r["median_ms"], vmax)}')
    print("=" * 108)
    print(" Alle Zeiten in Millisekunden (kleiner = besser). Sortiert nach Median.")

    with open("dns_speed_results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(ranked)
    with open("dns_speed_results.json", "w") as f:
        json.dump({"generated": time.strftime("%Y-%m-%d %H:%M:%S"),
                   "system_resolver": sysr, "rounds": args.rounds,
                   "domains": DOMAINS, "results": ranked}, f, indent=2)
    print(" Gespeichert: dns_speed_results.csv  /  dns_speed_results.json")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAbgebrochen.")
        sys.exit(1)
