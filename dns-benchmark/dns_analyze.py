#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dns_analyze.py  —  Wertet den mehrtaegigen DNS-Test aus und kuert den Sieger.

Liest die Verlaufsdatei dns_history.jsonl (von dns_speed_test.py ueber Tage
befuellt), aggregiert alle Laeufe je Anbieter und bestimmt den Sieger nach
GESCHWINDIGKEIT + ZUVERLAESSIGKEIT.

Sieger-Score (kleiner = besser):
    score = median_der_lauf_mediane
          + 0.3 * (typ_p95 - median)      # Ausreisser-Aufschlag
          + 0.5 * stdev_der_lauf_mediane  # Instabilitaet ueber die Tage
          + 5.0 * mittlere_ausfallrate_%  # Zuverlaessigkeit (ms je % Verlust)

Absicherungen: statistischer Gleichstand, Hijack-Gate (kein Schein-Sieger aus
gekaperten Daten), Wenig-Daten-Hinweis.

Ausgabe: Konsolen-Rangliste + Sieger, dns_winner.csv/json und die Grafik
dns_trend.html (Median-Verlauf + Endwertung, Light/Dark, selbst-enthalten).

Nur Python 3 (Standardbibliothek). Aufruf:
    python3 dns_analyze.py
    python3 dns_analyze.py --history <pfad>
"""
import argparse, csv, html, json, os, statistics, sys

SCRIPT_DIR      = os.path.dirname(os.path.abspath(__file__))
DEFAULT_HISTORY = os.path.join(SCRIPT_DIR, "dns_history.jsonl")
SECURITY_JSON   = os.path.join(SCRIPT_DIR, "results", "security_real.json")

# Score-Gewichte (dokumentiert & anpassbar)
W_SPREAD, W_STAB, W_LOSS = 0.3, 0.5, 5.0
MIN_PRESENT_FRAC = 0.30     # Anbieter muss in >=30% der Laeufe Daten haben
TIE_MS, TIE_SCORE = 1.0, 1.0
PRELIM_RUNS = 10            # < 10 Laeufe -> "vorlaeufig"

# 5 gut unterscheidbare Farben fuer die Top-5 im Trend-Chart (Rest grau)
TOP_COLORS = ["#1364D2", "#137a52", "#C77A0A", "#B23A48", "#6D4AA8"]

def pctl(sorted_vals, p):
    if not sorted_vals: return None
    k = min(len(sorted_vals) - 1, int(round(p * (len(sorted_vals) - 1))))
    return sorted_vals[k]

def load_runs(path):
    """JSON-Lines zeilentolerant lesen (halbe letzte Zeile beim Lesen-waehrend-Schreiben wird ignoriert)."""
    runs = []
    if not os.path.exists(path):
        return runs
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                runs.append(json.loads(line))
            except Exception:
                continue   # kaputte/halbe Zeile ueberspringen
    return runs

def load_security():
    """IP -> kurze Sicherheits-Zusammenfassung (optional, nur als Kontext)."""
    out = {}
    try:
        data = json.load(open(SECURITY_JSON, encoding="utf-8"))
        for name, e in data.get("providers", {}).items():
            tags = []
            if e.get("dnssec_validates"): tags.append("DNSSEC")
            if e.get("malware") == "blocked": tags.append("Malware-Filter")
            if e.get("ads") in ("blocked", "partial"): tags.append("Ad-Filter")
            if e.get("adult") == "blocked": tags.append("Jugendschutz")
            out[e.get("ip")] = ", ".join(tags) if tags else "keine Filter"
    except Exception:
        pass
    return out

def aggregate(valid):
    """valid: Liste gueltiger Laeufe (chronologisch). -> (agg, run_labels)."""
    valid = sorted(valid, key=lambda r: r.get("ts_iso", ""))
    run_labels = [r.get("ts_iso", "") for r in valid]
    agg = {}
    for idx, r in enumerate(valid):
        for e in r.get("per_resolver", []):
            ip = e.get("ip")
            if not ip:
                continue
            d = agg.setdefault(ip, {"ip": ip, "name": e.get("name", ip),
                                    "medians": [], "p95s": [], "losses": [],
                                    "by_hour": [], "idx_median": {}})
            d["name"] = e.get("name", d["name"])
            d["losses"].append(e.get("loss_pct", 100.0))
            m = e.get("median_ms")
            if m is not None and e.get("samples", 0) > 0:
                d["medians"].append(m)
                d["p95s"].append(e.get("p95_ms") or m)
                d["by_hour"].append((r.get("hour"), m))
                d["idx_median"][idx] = m
    return agg, run_labels

def score_entry(d, total_runs):
    n = len(d["medians"])
    if n == 0:
        return None
    med   = statistics.median(d["medians"])
    p95t  = statistics.median(d["p95s"]) if d["p95s"] else med
    spread = max(0.0, p95t - med)
    stab  = statistics.pstdev(d["medians"]) if n > 1 else 0.0
    loss  = statistics.fmean(d["losses"]) if d["losses"] else 0.0
    return {
        "ip": d["ip"], "name": d["name"], "runs": n,
        "present_frac": n / total_runs if total_runs else 0.0,
        "median": round(med, 2), "best": round(min(d["medians"]), 2),
        "worst": round(max(d["medians"]), 2), "p95": round(p95t, 2),
        "stability": round(stab, 2), "avg_loss": round(loss, 2),
        "score": round(med + W_SPREAD * spread + W_STAB * stab + W_LOSS * loss, 2),
    }

def day_night(d):
    day   = [m for h, m in d["by_hour"] if h is not None and 8 <= h <= 21]
    night = [m for h, m in d["by_hour"] if h is not None and (h >= 22 or h <= 7)]
    return (round(statistics.median(day), 1) if day else None,
            round(statistics.median(night), 1) if night else None)

# ---------------------------------------------------------------------------
# Konsolenausgabe
# ---------------------------------------------------------------------------
def print_report(ranked, agg, total, hij_runs, preliminary, hijack_gate, tie, sec):
    print("=" * 100)
    print(" DNS-Mehrtagestest — Auswertung".center(100))
    print("=" * 100)
    print(f" Laeufe gesamt: {total}   davon gehijackt: {hij_runs}   "
          f"gewertete Anbieter: {len(ranked)}")
    if preliminary:
        print(f" HINWEIS: nur {total} Laeufe (< {PRELIM_RUNS}) — Ergebnis VORLAEUFIG, laenger messen lassen.")
    if hijack_gate:
        print("\n  !!! ACHTUNG: Die Mehrheit der Laeufe war DNS-gehijackt (Router/ISP leitet um).")
        print("      Es wird KEIN Sieger gekuert — die Zahlen messen den abfangenden Resolver,")
        print("      nicht die Anbieter. Deaktiviere DNS-Umleitung im Router und miss erneut.\n")

    print("\n" + "-" * 100)
    print(f'{"#":>2}  {"Anbieter":24}{"IP":17}{"Laeufe":>7}{"Median":>8}{"best":>7}'
          f'{"p95":>8}{"Stab":>7}{"Verl%":>7}{"Score":>8}')
    print("-" * 100)
    for i, r in enumerate(ranked, 1):
        print(f'{i:>2}  {r["name"]:24}{r["ip"]:17}{r["runs"]:>7}'
              f'{r["median"]:8.1f}{r["best"]:7.1f}{r["p95"]:8.1f}'
              f'{r["stability"]:7.1f}{r["avg_loss"]:7.1f}{r["score"]:8.1f}')
    print("-" * 100)
    print(" Median = Median der Lauf-Mediane (ms).  Stab = Schwankung ueber die Tage.")
    print(" Score = Speed + Ausreisser + Instabilitaet + Verlust (kleiner = besser).")

    if hijack_gate or not ranked:
        return

    print("\n" + "=" * 100)
    if tie:
        a, b = ranked[0], ranked[1]
        print(f" STATISTISCHES UNENTSCHIEDEN: {a['name']} und {b['name']} sind praktisch gleich schnell.")
        print(f" Tie-Break (Zuverlaessigkeit): 🏆 Sieger = {a['name']}  ({a['ip']})")
    else:
        w = ranked[0]
        print(f" 🏆 SIEGER: {w['name']}  ({w['ip']})")
        print(f"    Median {w['median']} ms · p95 {w['p95']} ms · Verlust {w['avg_loss']} % "
              f"· ueber {w['runs']} Laeufe")
    win = ranked[0]
    if sec.get(win["ip"]):
        print(f"    Sicherheitsprofil (gemessen): {sec[win['ip']]}")
    print("=" * 100)

    print("\n Tageszeit-Check der Top-3 (Median Tag 08–21 / Nacht 22–07):")
    for r in ranked[:3]:
        dm, nm = day_night(agg[r["ip"]])
        print(f"   {r['name']:24} Tag {dm if dm is not None else '—':>6}   Nacht {nm if nm is not None else '—':>6}")

# ---------------------------------------------------------------------------
# HTML-Grafik (Trend + Endwertung), selbst-enthalten, Light/Dark
# ---------------------------------------------------------------------------
def svg_linechart(ranked, agg, run_labels, width=920, height=340):
    pad_l, pad_r, pad_t, pad_b = 48, 120, 16, 34
    n = len(run_labels)
    if n < 1:
        return "<p>Zu wenig Daten fuer den Verlauf.</p>"
    plot_w, plot_h = width - pad_l - pad_r, height - pad_t - pad_b

    all_y = [m for r in ranked for m in agg[r["ip"]]["medians"]]
    ycap = pctl(sorted(all_y), 0.95) or 1.0
    ycap = max(ycap, 1.0) * 1.1

    def X(i): return pad_l + (plot_w * (i / (n - 1)) if n > 1 else plot_w / 2)
    def Y(v): return pad_t + plot_h * (1 - min(v, ycap) / ycap)

    parts = [f'<svg viewBox="0 0 {width} {height}" width="100%" '
             f'role="img" aria-label="Median-Antwortzeit je Anbieter ueber die Messzeit" '
             f'font-family="ui-monospace,monospace" font-size="11">']
    # Y-Gitter + Ticks
    steps = 4
    for s in range(steps + 1):
        val = ycap * s / steps
        y = Y(val)
        parts.append(f'<line x1="{pad_l}" y1="{y:.1f}" x2="{pad_l+plot_w}" y2="{y:.1f}" '
                     f'stroke="var(--grid)" stroke-width="1"/>')
        parts.append(f'<text x="{pad_l-6}" y="{y+3:.1f}" text-anchor="end" '
                     f'fill="var(--muted)">{val:.0f}</text>')
    parts.append(f'<text x="{pad_l-6}" y="{pad_t-4}" text-anchor="end" fill="var(--muted)">ms</text>')
    # X-Ticks (bis zu 6)
    ticks = min(6, n)
    for t in range(ticks):
        i = round(t * (n - 1) / max(1, ticks - 1))
        lbl = run_labels[i][5:16].replace("T", " ") if run_labels[i] else str(i)
        x = X(i)
        parts.append(f'<text x="{x:.1f}" y="{height-10}" text-anchor="middle" '
                     f'fill="var(--muted)">{html.escape(lbl)}</text>')

    top_ips = {r["ip"] for r in ranked[:5]}
    color_of = {r["ip"]: TOP_COLORS[i] for i, r in enumerate(ranked[:5])}
    # Zuerst die grauen (nicht-Top) Linien, dann Top-5 darueber
    def polyline(ip, color, w, opacity):
        pts = sorted(agg[ip]["idx_median"].items())
        if len(pts) < 1: return ""
        pstr = " ".join(f"{X(i):.1f},{Y(v):.1f}" for i, v in pts)
        return (f'<polyline points="{pstr}" fill="none" stroke="{color}" '
                f'stroke-width="{w}" opacity="{opacity}" '
                f'stroke-linejoin="round" stroke-linecap="round"/>')
    for r in ranked:
        if r["ip"] not in top_ips:
            parts.append(polyline(r["ip"], "var(--muted)", 1, 0.28))
    for r in ranked[:5]:
        parts.append(polyline(r["ip"], color_of[r["ip"]], 2, 0.95))
        # Endpunkt-Label (Identitaet nicht nur ueber Farbe)
        pts = sorted(agg[r["ip"]]["idx_median"].items())
        if pts:
            i, v = pts[-1]
            parts.append(f'<circle cx="{X(i):.1f}" cy="{Y(v):.1f}" r="3" fill="{color_of[r["ip"]]}"/>')
            parts.append(f'<text x="{pad_l+plot_w+8}" y="{Y(v)+3:.1f}" fill="{color_of[r["ip"]]}">'
                         f'{html.escape(r["name"][:16])}</text>')
    parts.append("</svg>")
    return "".join(parts)

def build_html(ranked, agg, run_labels, total, hij_runs, preliminary, hijack_gate, tie, sec, path):
    vmax = max((r["median"] for r in ranked), default=1) or 1
    rows_html = []
    for i, r in enumerate(ranked, 1):
        w = 100.0 * r["median"] / vmax
        top = i <= 5
        color = TOP_COLORS[i-1] if top else "var(--muted)"
        rows_html.append(f"""
        <div class="row">
          <div class="rank">{i}</div>
          <div class="who"><span class="dot" style="background:{color}"></span>{html.escape(r['name'])}
            <span class="ip">{r['ip']}</span></div>
          <div class="track"><div class="fill" style="width:{w:.1f}%;background:{color}"></div>
            <span class="val">{r['median']:.1f} ms</span></div>
          <div class="meta">p95 {r['p95']:.0f} · Verl {r['avg_loss']:.1f}% · {r['runs']} L.</div>
        </div>""")

    if hijack_gate or not ranked:
        verdict = ('<div class="verdict warn"><h2>Kein Sieger — DNS-Hijacking</h2>'
                   '<p>Die Mehrheit der Laeufe war gekapert; die Zahlen messen den abfangenden '
                   'Resolver, nicht die Anbieter. Router-DNS-Umleitung deaktivieren und neu messen.</p></div>')
    else:
        w = ranked[0]
        secline = f' · <span class="sec">{html.escape(sec.get(w["ip"],""))}</span>' if sec.get(w["ip"]) else ""
        tie_note = (f' (statistisches Unentschieden mit {html.escape(ranked[1]["name"])} — '
                    f'Tie-Break Zuverlaessigkeit)') if tie else ""
        verdict = (f'<div class="verdict"><div class="crown">🏆 Sieger</div>'
                   f'<h2>{html.escape(w["name"])} <span class="wip">{w["ip"]}</span></h2>'
                   f'<p>Median <b>{w["median"]:.1f} ms</b> · p95 {w["p95"]:.0f} ms · '
                   f'Verlust {w["avg_loss"]:.1f}% · ueber {w["runs"]} Laeufe{tie_note}{secline}</p></div>')

    dn_rows = []
    for r in ranked[:3]:
        dm, nm = day_night(agg[r["ip"]])
        dn_rows.append(f'<tr><td>{html.escape(r["name"])}</td>'
                       f'<td>{dm if dm is not None else "—"}</td>'
                       f'<td>{nm if nm is not None else "—"}</td></tr>')

    prelim = (f'<div class="banner">Vorlaeufig — nur {total} Laeufe (&lt; {PRELIM_RUNS}). '
              f'Laenger messen fuer ein belastbares Ergebnis.</div>') if preliminary and not hijack_gate else ""

    chart = svg_linechart(ranked, agg, run_labels)
    doc = f"""<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DNS-Mehrtagestest — Auswertung</title>
<style>
:root{{--bg:#f4f7fa;--surface:#fff;--surface2:#eaeff5;--ink:#101923;--muted:#5b6b7e;
--line:#d6dee8;--grid:#e3e9f1;--accent:#1364d2;--ok:#137a52;--warn:#9a5b00;--warnbg:#f8ebd2}}
@media(prefers-color-scheme:dark){{:root{{--bg:#0b111a;--surface:#111b26;--surface2:#17232f;
--ink:#e7eef6;--muted:#8ba0b4;--line:#243342;--grid:#1e2b38;--accent:#4f9bff;--ok:#3fce90;
--warn:#e6ac57;--warnbg:#2a2113}}}}
:root[data-theme="dark"]{{--bg:#0b111a;--surface:#111b26;--surface2:#17232f;--ink:#e7eef6;
--muted:#8ba0b4;--line:#243342;--grid:#1e2b38;--accent:#4f9bff;--ok:#3fce90;--warn:#e6ac57;--warnbg:#2a2113}}
:root[data-theme="light"]{{--bg:#f4f7fa;--surface:#fff;--surface2:#eaeff5;--ink:#101923;
--muted:#5b6b7e;--line:#d6dee8;--grid:#e3e9f1;--accent:#1364d2;--ok:#137a52;--warn:#9a5b00;--warnbg:#f8ebd2}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);
font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;line-height:1.55}}
.wrap{{max-width:1000px;margin:0 auto;padding:clamp(18px,4vw,44px)}}
h1{{font-size:clamp(21px,3vw,28px);margin:0 0 4px;letter-spacing:-.01em}}
.sub{{color:var(--muted);font-size:14px;margin:0 0 22px}}
.mono{{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace}}
.verdict{{background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--ok);
border-radius:14px;padding:20px 22px;margin:0 0 8px;box-shadow:0 8px 24px -14px rgba(0,0,0,.25)}}
.verdict.warn{{border-left-color:var(--warn);background:var(--warnbg)}}
.verdict .crown{{font-family:ui-monospace,monospace;font-size:12px;letter-spacing:.1em;
text-transform:uppercase;color:var(--ok)}}
.verdict h2{{margin:4px 0 6px;font-size:24px}}.verdict .wip{{font-family:ui-monospace,monospace;
font-size:15px;color:var(--muted);font-weight:400}}.verdict p{{margin:0;color:var(--muted);font-size:14px}}
.verdict .sec{{color:var(--ok)}}
.banner{{background:var(--warnbg);border:1px solid var(--warn);border-radius:10px;padding:9px 14px;
font-size:13px;margin:0 0 16px}}
.card{{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:20px;
margin-top:20px;box-shadow:0 8px 24px -16px rgba(0,0,0,.22)}}
.card h3{{margin:0 0 14px;font-size:15px}}
.row{{display:grid;grid-template-columns:26px 210px 1fr 150px;gap:12px;align-items:center;
padding:5px 0;border-bottom:1px solid var(--grid)}}
.row:last-child{{border-bottom:0}}
.rank{{font-family:ui-monospace,monospace;color:var(--muted);text-align:right}}
.who{{font-weight:600;font-size:14px}}.who .ip{{font-family:ui-monospace,monospace;font-size:11.5px;
color:var(--muted);font-weight:400;margin-left:6px}}
.dot{{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:7px;vertical-align:middle}}
.track{{position:relative;height:22px;background:var(--surface2);border:1px solid var(--line);
border-radius:6px;overflow:hidden}}
.fill{{position:absolute;left:0;top:0;bottom:0;border-radius:5px}}
.track .val{{position:absolute;right:8px;top:50%;transform:translateY(-50%);font-family:ui-monospace,
monospace;font-size:11.5px;color:var(--ink)}}
.meta{{font-family:ui-monospace,monospace;font-size:11.5px;color:var(--muted);text-align:right}}
@media(max-width:640px){{.row{{grid-template-columns:22px 1fr;}}.track,.meta{{grid-column:2}}}}
table{{border-collapse:collapse;width:100%;font-size:13.5px}}
th,td{{text-align:left;padding:6px 10px;border-bottom:1px solid var(--grid)}}
th{{color:var(--muted);font-weight:600;font-family:ui-monospace,monospace;font-size:12px}}
td:nth-child(n+2){{font-family:ui-monospace,monospace;text-align:right}}
.chartwrap{{overflow-x:auto}}
footer{{margin-top:26px;color:var(--muted);font-size:12.5px}}
</style></head><body><div class="wrap">
<h1>DNS-Mehrtagestest — Auswertung</h1>
<p class="sub mono">{total} Laeufe · Sieger nach Geschwindigkeit + Zuverlaessigkeit · lokal gemessen</p>
{prelim}
{verdict}
<div class="card"><h3>Endwertung (Median der Lauf-Mediane, kleiner = besser)</h3>
{''.join(rows_html)}</div>
<div class="card"><h3>Median-Verlauf ueber die Messzeit — Top-5 farbig, uebrige ausgegraut</h3>
<div class="chartwrap">{chart}</div></div>
<div class="card"><h3>Tageszeit-Check der Top-3</h3>
<table><thead><tr><th>Anbieter</th><th>Tag 08–21 (ms)</th><th>Nacht 22–07 (ms)</th></tr></thead>
<tbody>{''.join(dn_rows)}</tbody></table></div>
<footer>Erzeugt von dns_analyze.py · Median = Median der Lauf-Mediane · Score = Speed + Ausreisser +
Instabilitaet + Verlust. Reproduzierbar via dns-benchmark/.</footer>
</div>
<script>
document.querySelectorAll('.who .ip, .verdict .wip').forEach(el=>{{el.title='Klick zum Kopieren';
el.style.cursor='pointer';el.addEventListener('click',()=>navigator.clipboard&&navigator.clipboard.writeText(el.textContent.trim()));}});
</script>
</body></html>"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc)

def main():
    ap = argparse.ArgumentParser(description="Auswertung des mehrtaegigen DNS-Tests")
    ap.add_argument("--history", default=DEFAULT_HISTORY, help="Verlaufsdatei (JSON Lines)")
    args = ap.parse_args()

    runs = load_runs(args.history)
    valid = [r for r in runs if r.get("ok") and r.get("per_resolver")]
    total = len(valid)
    if total == 0:
        print(f"Keine (gueltigen) Laeufe in {args.history}.")
        print("Erst mit dns_speed_test.py messen (ggf. per Zeitplan ueber mehrere Tage).")
        return

    hij_runs = sum(1 for r in valid if r.get("hijacked") is True)
    preliminary = total < PRELIM_RUNS
    hijack_gate = hij_runs / total >= 0.5

    agg, run_labels = aggregate(valid)
    scored = [s for s in (score_entry(d, total) for d in agg.values()) if s]
    # nur Anbieter mit ausreichender Praesenz werten
    scored = [s for s in scored if s["present_frac"] >= MIN_PRESENT_FRAC] or scored
    ranked = sorted(scored, key=lambda s: s["score"])

    tie = (len(ranked) >= 2 and
           abs(ranked[0]["median"] - ranked[1]["median"]) < TIE_MS and
           abs(ranked[0]["score"] - ranked[1]["score"]) < TIE_SCORE)
    if tie and ranked[0]["avg_loss"] > ranked[1]["avg_loss"]:
        ranked[0], ranked[1] = ranked[1], ranked[0]   # Tie-Break: zuverlaessigeren nach vorn

    sec = load_security()
    print_report(ranked, agg, total, hij_runs, preliminary, hijack_gate, tie, sec)

    # Ausgaben schreiben
    try:
        with open(os.path.join(SCRIPT_DIR, "dns_winner.csv"), "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(ranked[0].keys())); w.writeheader(); w.writerows(ranked)
        json.dump({"runs_total": total, "hijacked_runs": hij_runs, "preliminary": preliminary,
                   "hijack_gate": hijack_gate, "tie": tie,
                   "winner": (ranked[0] if ranked and not hijack_gate else None),
                   "ranking": ranked},
                  open(os.path.join(SCRIPT_DIR, "dns_winner.json"), "w", encoding="utf-8"),
                  indent=2, ensure_ascii=False)
        out_html = os.path.join(SCRIPT_DIR, "dns_trend.html")
        build_html(ranked, agg, run_labels, total, hij_runs, preliminary, hijack_gate, tie, sec, out_html)
        print(f"\n Geschrieben: dns_winner.csv · dns_winner.json · {os.path.basename(out_html)}")
    except Exception as e:
        print(" WARN Ausgabe:", repr(e))

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(1)
