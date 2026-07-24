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
    * gibt eine sortierte Tabelle (min / median / mittel / p95 / max / Verlust) aus
    * haengt jedes Ergebnis an eine Verlaufsdatei (JSON Lines) an  ->  fuer den
      mehrtaegigen Test, den dns_analyze.py spaeter auswertet

Voraussetzungen: nur Python 3 (Standardbibliothek) — keine Installation noetig.
Aufruf:
    python3 dns_speed_test.py
    python3 dns_speed_test.py --rounds 15 --extra 192.168.1.1=Router
    python3 dns_speed_test.py --rounds 6 --quiet          # fuer geplante Laeufe

Alle Ausgaben (Verlauf, CSV/JSON, Log) landen NEBEN diesem Skript — unabhaengig
vom Arbeitsverzeichnis (wichtig, weil die Windows-Aufgabenplanung in System32 startet).
"""
import argparse, csv, json, os, random, re, socket, statistics, struct, subprocess, sys, time, traceback

# Alle Pfade absolut, relativ zum Skript (NICHT zum Arbeitsverzeichnis!)
SCRIPT_DIR      = os.path.dirname(os.path.abspath(__file__))
DEFAULT_HISTORY = os.path.join(SCRIPT_DIR, "dns_history.jsonl")
RUN_LOG         = os.path.join(SCRIPT_DIR, "dns_runs.log")

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

def log_run(msg):
    """Diagnose-Zeile in dns_runs.log — unabhaengig von der Aufgabenplanung-Historie."""
    try:
        with open(RUN_LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + "  " + msg + "\n")
    except Exception:
        pass

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
        for _ in range(8):                # Obergrenze: kein Endlos-Spin bei Fremd-Paketen
            data, _addr = s.recvfrom(4096)
            if len(data) >= 4 and struct.unpack(">H", data[:2])[0] == qid:
                return (time.perf_counter() - t0) * 1000.0
        return None
    except Exception:
        return None
    finally:
        s.close()

def detect_system_resolver():
    """Aktuellen Resolver ermitteln — Linux/macOS via resolv.conf, Windows via ipconfig."""
    try:  # Linux / macOS
        with open("/etc/resolv.conf") as f:
            for line in f:
                line = line.strip()
                if line.startswith("nameserver"):
                    return line.split()[1]
    except Exception:
        pass
    if os.name == "nt":  # Windows: erste IPv4 auf/nach einer "DNS"-Zeile in `ipconfig /all`
        try:
            out = subprocess.run(["ipconfig", "/all"], capture_output=True,
                                 text=True, timeout=10).stdout
            ip_re = re.compile(r"(\d{1,3}(?:\.\d{1,3}){3})")
            lines = out.splitlines()
            for i, line in enumerate(lines):
                if "DNS" in line and ":" in line:
                    for cont in lines[i:i + 5]:      # Label-Zeile + evtl. Folgezeilen
                        m = ip_re.search(cont)
                        if m and not m.group(1).startswith(("0.", "255.")):
                            return m.group(1)
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

def connectivity_ok():
    """Grober Egress-Check: antwortet mind. ein grosser Resolver auf UDP/53?"""
    for ip in ("8.8.8.8", "1.1.1.1", "9.9.9.9"):
        if query_once(ip, "example.com", timeout=2.0) is not None:
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

def append_history(path, record):
    """Eine JSON-Lines-Zeile atomar anhaengen (ein write inkl. \\n)."""
    try:
        line = json.dumps(record, ensure_ascii=False)
        with open(path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        return True
    except Exception as e:
        log_run("WARN history: " + repr(e))
        return False

def main():
    ap = argparse.ArgumentParser(description="Lokaler DNS-Geschwindigkeitstest")
    ap.add_argument("--rounds", type=int, default=12, help="Messrunden je Domain (Standard 12)")
    ap.add_argument("--timeout", type=float, default=2.0, help="Timeout pro Query in s")
    ap.add_argument("--extra", action="append", default=[],
                    help="Zusaetzlicher Resolver  IP=Name  (mehrfach moeglich)")
    ap.add_argument("--history", default=None,
                    help="Verlaufsdatei (JSON Lines). Standard: dns_history.jsonl neben dem Skript.")
    ap.add_argument("--no-history", action="store_true", help="Nicht an die Verlaufsdatei anhaengen.")
    ap.add_argument("--quiet", action="store_true", help="Weniger Ausgabe (fuer geplante Laeufe).")
    args = ap.parse_args()

    history_path = None if args.no_history else \
        (os.path.abspath(args.history) if args.history else DEFAULT_HISTORY)

    def out(*a, **k):
        if not args.quiet:
            print(*a, **k)

    resolvers = list(RESOLVERS)
    sysr = detect_system_resolver()
    if sysr and not any(sysr == ip for ip, *_ in resolvers):
        resolvers.insert(0, (sysr, "Dein aktueller Resolver", "aktuell"))
    for ex in args.extra:
        if "=" in ex:
            ip, name = ex.split("=", 1)
            resolvers.append((ip.strip(), name.strip(), "custom"))

    out("=" * 78)
    out(" Lokaler DNS-Geschwindigkeitstest".center(78))
    out("=" * 78)
    out(f" Resolver: {len(resolvers)}   Domains: {len(DOMAINS)}   Runden: {args.rounds}"
        f"   Queries gesamt: {len(resolvers) * len(DOMAINS) * args.rounds}")
    if sysr:
        out(f" Dein aktueller Resolver (System): {sysr}")

    now_meta = {"ts_iso": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "hour": int(time.strftime("%H")), "weekday": time.strftime("%a")}

    # --- Egress-Check: ohne UDP/53 hat der Lauf keinen Sinn ---
    if not connectivity_ok():
        msg = "Kein UDP/53-Egress zu oeffentlichen Resolvern (Firewall?) — Lauf uebersprungen."
        out("\n  !!! " + msg)
        log_run("ABBRUCH: " + msg)
        if history_path:
            append_history(history_path, {**now_meta, "hijacked": None, "rounds": args.rounds,
                                          "ok": False, "error": "no_udp53_egress",
                                          "system_resolver": sysr, "per_resolver": []})
        return

    hij = check_hijacking()
    if hij:
        out("\n  !!! WARNUNG: Dein Netzwerk/Router leitet DNS-Anfragen um (DNS-Hijacking).")
        out("      Die Ergebnisse messen dann NICHT die echten Anbieter. Deaktiviere die")
        out("      DNS-Umleitung/Filter im Router oder teste per DoH/DoT-faehigem Client.\n")
    else:
        out(" Kein DNS-Hijacking erkannt — Messung erreicht die echten Anbieter.\n")

    # Warmup (Cache + Netzpfad anwaermen)
    out(" Warmup ...")
    for ip, *_ in resolvers:
        for d in DOMAINS:
            query_once(ip, d, args.timeout)

    timings  = {ip: [] for ip, *_ in resolvers}
    fails    = {ip: 0  for ip, *_ in resolvers}
    attempts = {ip: 0  for ip, *_ in resolvers}
    for rnd in range(args.rounds):
        order = resolvers[rnd % len(resolvers):] + resolvers[:rnd % len(resolvers)]
        for d in DOMAINS:
            for ip, *_ in order:
                attempts[ip] += 1
                t = query_once(ip, d, args.timeout)
                if t is None: fails[ip] += 1
                else: timings[ip].append(t)
        out(f"  Runde {rnd + 1}/{args.rounds} fertig")

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

    if not args.quiet:
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

    # Einzelausgabe (Momentaufnahme) — im Skriptordner
    try:
        with open(os.path.join(SCRIPT_DIR, "dns_speed_results.csv"), "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(ranked)
        with open(os.path.join(SCRIPT_DIR, "dns_speed_results.json"), "w", encoding="utf-8") as f:
            json.dump({"generated": now_meta["ts_iso"], "system_resolver": sysr,
                       "rounds": args.rounds, "hijacked": hij, "domains": DOMAINS,
                       "results": ranked}, f, indent=2, ensure_ascii=False)
    except Exception as e:
        log_run("WARN Einzelausgabe: " + repr(e))

    # Verlauf anhaengen (fuer den mehrtaegigen Test)
    if history_path:
        record = {**now_meta, "hijacked": hij, "rounds": args.rounds,
                  "ok": any(r["samples"] > 0 for r in rows), "system_resolver": sysr,
                  "per_resolver": [{k: r[k] for k in
                        ("ip", "name", "samples", "loss_pct", "min_ms",
                         "median_ms", "mean_ms", "p95_ms", "max_ms", "stdev_ms")} for r in rows]}
        if append_history(history_path, record):
            out(f"\n Verlauf angehaengt: {history_path}")
        log_run(f"OK rounds={args.rounds} hijacked={hij} resolvers={len(resolvers)} "
                f"-> {os.path.basename(history_path)}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAbgebrochen.")
        sys.exit(1)
    except Exception:
        log_run("FEHLER: " + traceback.format_exc().replace("\n", " | "))
        raise
