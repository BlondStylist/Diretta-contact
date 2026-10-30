#!/usr/bin/env python3
"""erdung-auswertung.py v1.2 - Auswertung diretta-erdung.sh (nur Standardbibliothek, Python >= 3.6).

  python3 erdung-auswertung.py LAUFVERZEICHNIS
  python3 erdung-auswertung.py --selbsttest

Analyse-Einheit = Block (Paar MIT/OHNE). Kenngroesse je Segment: Mittelwert;
Rauschen = SD der ersten Differenzen / sqrt(2) (driftbereinigt).
Statistik: Blockdifferenz MIT-OHNE, exakter Vorzeichen-Permutationstest (n<=16,
sonst Monte-Carlo), exaktes 95%-KI durch Testinversion (Hartigan), Aequivalenz per TOST
(90%-KI innerhalb +-SESOI), Holm ueber die 2 vorab festgelegten Primaerendpunkte.
Ausschluss (vorab): Segment fehlt, <3 gueltige Proben, >20% Fehlproben,
Drosselung aktiv, Wiedergabe nicht eindeutig (>=90%/<=10%) oder ungleich.
"""
import bisect, csv, itertools, math, os, random, sys, tempfile
import statistics as S
from collections import Counter

VERSION = "1.2"
# SESOI in V / A / W - VOR der Messung festlegen, danach nicht mehr aendern.
SESOI = {("EXT5V_V", "mean"): 0.002, ("EXT5V_V", "noise"): 0.0005}
SESOI_STD = {"V": 0.001, "A": 0.010, "W": 0.050}
PRIMAER = [("EXT5V_V", "mean"), ("EXT5V_V", "noise")]
EXPLOR = [("EXT5V_V", "med"), ("HDMI_V", "mean"), ("VDD_CORE_V", "mean"), ("3V3_SYS_V", "mean"),
          ("1V8_SYS_V", "mean"), ("1V1_SYS_V", "mean"), ("0V8_SW_V", "mean"), ("DDR_VDD2_V", "mean"),
          ("3V3_DAC_V", "mean"), ("VDD_CORE_V", "noise"), ("VDD_CORE_A", "mean"), ("P_PMIC_W", "mean")]
ARTNAME = {"mean": "Mittel", "med": "Median", "noise": "Rauschen"}
NAN = float("nan")


def sesoi(col, art):
    return SESOI.get((col, art), SESOI_STD[col[-1]])


def fnum(x):
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def mittel(v):
    v = list(v)
    return sum(v) / len(v) if v else NAN


def kat(x):
    if x is None:
        return None
    return 1 if x >= .9 else (0 if x <= .1 else None)


def lies_segment(pfad):
    with open(pfad, newline="") as fh:
        roh = list(csv.DictReader(fh))
    rows = [r for r in roh if fnum(r.get("EXT5V_V")) is not None]
    paare = [(k, k[:-2] + "_V") for k in (rows[0].keys() if rows else []) if k and k.endswith("_A")]
    for r in rows:
        # nur vollstaendige Zeilen: jede Schiene mit Strom UND Spannung, sonst NA (keine Teilsummen)
        a_u = [(fnum(r.get(ka)), fnum(r.get(kv))) for ka, kv in paare]
        ok = bool(a_u) and all(a is not None and u is not None for a, u in a_u)
        r["P_PMIC_W"] = sum(a * u for a, u in a_u) if ok else None
    werte = {}
    for c in (list(rows[0].keys()) if rows else []):
        v = [x for x in (fnum(r.get(c)) for r in rows) if x is not None]
        if v:
            werte[c] = v
    t = [int(r["t_us"]) for r in rows if (r.get("t_us") or "").isdigit()]
    dts = [(b - a) / 1e6 for a, b in zip(t, t[1:])]
    e = werte.get("EXT5V_V", [])
    thr = 0
    for r in rows:
        x = r.get("throttled") or ""
        if x.startswith("0x"):
            try:
                thr += bool(int(x, 16) & 0xF)
            except ValueError:
                pass
    meta = {"n": len(rows), "n_roh": len(roh),
            "play": sum(r.get("play") == "1" for r in rows) / len(rows) if rows else None,
            "temp": mittel(werte["temp_mC"]) / 1000 if "temp_mC" in werte else None,
            "thr_akt": thr,
            "dt": S.median(dts) if dts else None,
            "wdh": sum(a == b for a, b in zip(e, e[1:])) / (len(e) - 1) if len(e) > 1 else None}
    return werte, meta


def kenn(v, art):
    if v is None or len(v) < 3:
        return None
    if art == "mean":
        return mittel(v)
    if art == "med":
        return S.median(v)
    d = [b - a for a, b in zip(v, v[1:])]
    return S.pstdev(d) / math.sqrt(2)


def _schwellen(d):
    """Schwellen t_s = Mittel der Teilmenge mit Vorzeichen -1 (Hartigan 1969).

    Fuer H0: E[d] = mu gilt  sum s_i (d_i - mu) >= sum (d_i - mu)  genau dann, wenn mu >= t_s
    (Identitaet: immer). Beide einseitigen p(mu) sind damit monotone Treppenfunktionen,
    das Konfidenzintervall ist exakt ein Intervall aus Ordnungsstatistiken der t_s.
    n <= 16: alle 2^n Vorzeichenvektoren; sonst 20000 Monte-Carlo-Vektoren (Seed 1).
    Rueckgabe: sortierte endliche Schwellen, Anzahl Identitaeten, Nenner, exakt?
    """
    n = len(d)
    if n <= 16:
        summen, anz = [0.0], [0]
        for x in d:
            summen = summen + [a + x for a in summen]
            anz = anz + [k + 1 for k in anz]
        t = sorted(a / k for a, k in zip(summen, anz) if k)
        return t, 1, 2 ** n, True
    rnd = random.Random(1)
    t, ident = [], 0
    for _ in range(20000):
        a = k = 0
        for x in d:
            if rnd.random() < .5:
                a += x
                k += 1
        if k:
            t.append(a / k)
        else:
            ident += 1
    t.sort()
    return t, ident + 1, 20000 + 1, False  # +1: beobachtete Zuordnung selbst


def p_fun(d):
    """p(mu): zweiseitiger Vorzeichen-Permutationstest (2 x kleineres einseitiges p) fuer H0: Mittel = mu."""
    t, c0, N, exakt = _schwellen(d)

    def p(mu=0.0):
        p_unter = (c0 + bisect.bisect_right(t, mu)) / N      # klein -> mu zu klein
        p_ueber = (c0 + len(t) - bisect.bisect_left(t, mu)) / N  # klein -> mu zu gross
        return min(1.0, 2 * min(p_unter, p_ueber))

    p.schwellen, p.c0, p.N = t, c0, N
    return p, min(1.0, 2 * c0 / N)


def exakt_p(d):
    return p_fun(d)[0](0.0)


def ki(d, alpha=.05, pf=None):
    """Exaktes KI durch Testinversion: {mu : p(mu) >= alpha}; unbegrenzt, wenn alpha nicht erreichbar."""
    p, _ = pf or p_fun(d)
    t, c0, N = p.schwellen, p.c0, p.N
    # kleinstes k mit (c0 + k)/N >= alpha/2
    k = max(0, math.ceil(alpha / 2 * N - c0 - 1e-9))
    if k == 0 or k > len(t):
        return -math.inf, math.inf
    return t[k - 1], t[len(t) - k]


def holm(ps):
    ps = [1.0 if x is None else x for x in ps]
    o = sorted(range(len(ps)), key=lambda i: ps[i])
    adj, run = [0.0] * len(ps), 0.0
    for r, i in enumerate(o):
        run = max(run, min(1.0, (len(ps) - r) * ps[i]))
        adj[i] = run
    return adj


def lsb(alle):
    u = sorted(set(round(x, 9) for x in alle))
    g = Counter(round(b - a, 9) for a, b in zip(u, u[1:]) if b - a > 1e-9)
    if not g:
        return 0.0
    mx = max(g.values())
    return min(k for k, v in g.items() if v == mx)


def befund(prim, p, padj, lo90, hi90, E):
    aequi = math.isfinite(lo90) and math.isfinite(hi90) and -E <= lo90 and hi90 <= E
    sig = (padj is not None and padj < .05) if prim else p < .05
    if sig and aequi:
        return "EFFEKT < SESOI (irrelevant)" if prim else "Hinweis < SESOI (irrelevant)"
    if sig:
        return "EFFEKT" if prim else "Hinweis (explorativ)"
    if aequi:
        return "aequivalent (+-SESOI)"
    return "unklar"


def lies_meta(pfad):
    m = {}
    if os.path.exists(pfad):
        with open(pfad, errors="replace") as fh:
            for z in fh:
                if "=" in z:
                    k, v = z.rstrip("\n").split("=", 1)
                    m[k] = v
    return m


def ausschluss(m, o, mm, om):
    if not (m and o):
        return "fehlt"
    for (_, me), sm in ((m, mm or {}), (o, om or {})):
        if me["n"] < 3:
            return "n<3"
        fehl = fnum(sm.get("fehlproben")) or 0
        inv = fehl + (me["n_roh"] - me["n"])
        if inv > .2 * (me["n_roh"] + fehl):
            return "fehl>20%"
        if me["thr_akt"]:
            return "Drossel"
    km, ko = kat(m[1]["play"]), kat(o[1]["play"])
    if km is None or ko is None:
        return "Wdg?"
    if km != ko:
        return "Wdg!="
    return ""


def auswerten(d):
    out = []
    w = out.append
    run = lies_meta(os.path.join(d, "run.meta"))
    pp = os.path.join(d, "plan.csv")
    if not os.path.exists(pp):
        w("ABBRUCH: plan.csv fehlt.")
        return out, []
    with open(pp, newline="") as fh:
        plan = list(csv.DictReader(fh))
    seg, smeta = {}, {}
    for p in plan:
        sid = "b%s_%s" % (p.get("block"), p.get("cond"))
        base = os.path.join(d, "seg_" + sid)
        if os.path.exists(base + ".done") and os.path.exists(base + ".csv"):
            seg[sid] = lies_segment(base + ".csv")
            smeta[sid] = lies_meta(base + ".meta")
    bloecke, ausg = [], []
    for b in sorted({int(p["block"]) for p in plan if (p.get("block") or "").isdigit()}):
        g = ausschluss(seg.get(f"b{b}_MIT"), seg.get(f"b{b}_OHNE"),
                       smeta.get(f"b{b}_MIT"), smeta.get(f"b{b}_OHNE"))
        if g:
            ausg.append(f"{b}:{g}")
        else:
            bloecke.append(b)
    w(f"ERDUNG A/B v{VERSION}  {run.get('geraet', '?')}  Kernel {run.get('kernel', '?')}  "
      f"Skript {run.get('version', '?')}/{run.get('sha', '?')}")
    w(f"Bloecke {len(bloecke)}/{run.get('bloecke', '?')}  ausgeschl.: {', '.join(ausg) or '-'}  "
      f"Kabel anderes Geraet: {run.get('anderes_geraet_kabel', '?')}")
    if len(bloecke) < 2:
        w("ABBRUCH: weniger als 2 gueltige Bloecke.")
        return out, []
    for c in ("MIT", "OHNE"):
        ms = [seg[f"b{b}_{c}"][1] for b in bloecke]
        mm = [smeta.get(f"b{b}_{c}", {}) for b in bloecke]

        def summe(k, mm=mm):
            v = [x.get(k) for x in mm]
            return "NA" if any(not (x or "").isdigit() for x in v) else sum(int(x) for x in v)

        tl = [x["temp"] for x in ms if x["temp"] is not None]
        wd = [x["wdh"] for x in ms if x["wdh"] is not None]
        neu = sum(1 for x in mm if x.get("throttled_vor") != x.get("throttled_nach"))
        w(f"{c:4}: Proben {sum(x['n'] for x in ms)}  dt {mittel(x['dt'] for x in ms if x['dt']):.2f}s  "
          f"Wdg {mittel(x['play'] for x in ms) * 100:.0f}%  Temp {mittel(tl):.1f}C  Wdh(EXT5V) {mittel(wd) * 100:.0f}%")
        w(f"      Sticky-neu {neu}  KLog B/M {summe('klog_settle')}/{summe('klog_mess')}  "
          f"NetErr {summe('neterr_delta')}  Fehlproben {summe('fehlproben')}  verspaetet {summe('verspaetet')}")
    dtemp = [seg[f"b{b}_MIT"][1]["temp"] - seg[f"b{b}_OHNE"][1]["temp"] for b in bloecke
             if seg[f"b{b}_MIT"][1]["temp"] is not None and seg[f"b{b}_OHNE"][1]["temp"] is not None]
    if len(dtemp) >= 2:
        pt = exakt_p(dtemp)
        w(f"Temp-Kontrolle MIT-OHNE {mittel(dtemp):+.2f} K (p={pt:.3f})"
          + ("  WARNUNG: Temperatur-Konfundierung" if pt < .05 else "  (n.s. beweist keine Gleichheit)"))
    w("")
    w(f"{'Groesse':19}{'Delta':>10}{'95%-KI (Inversion)':>22}{'p':>7}{'p_Holm':>7}{'Schritt':>8}  Befund")
    ergebnisse = []
    for col, art in PRIMAER + EXPLOR:
        dd = []
        for b in bloecke:
            ka = kenn(seg[f"b{b}_MIT"][0].get(col), art)
            kz = kenn(seg[f"b{b}_OHNE"][0].get(col), art)
            if ka is None or kz is None:
                dd = None
                break
            dd.append(ka - kz)
        if not dd or len(dd) < 2:
            ergebnisse.append((col, art, None))
            continue
        pf = p_fun(dd)
        lo, hi = ki(dd, .05, pf)
        lo9, hi9 = ki(dd, .10, pf)
        alle = [x for b in bloecke for c in ("MIT", "OHNE") for x in seg[f"b{b}_{c}"][0].get(col, [])]
        st = lsb(alle) if (col != "P_PMIC_W" and art != "noise") else 0.0
        ergebnisse.append((col, art, (mittel(dd), lo, hi, pf[0](0.0), st, lo9, hi9)))
    ph = holm([e[2][3] if e[2] else None for e in ergebnisse[:len(PRIMAER)]])
    for i, (col, art, e) in enumerate(ergebnisse):
        name = f"{col} {ARTNAME[art]}"
        prim = i < len(PRIMAER)
        if e is None:
            w(f"{name:19}{'NA':>10}")
        else:
            m, lo, hi, p, st, lo9, hi9 = e
            padj = ph[i] if prim else None
            eh = "mW" if col.endswith("_W") else ("mA" if col.endswith("_A") else "mV")
            bef = befund(prim, p, padj, lo9, hi9, sesoi(col, art))
            w(f"{name:19}{m * 1e3:>+7.3f} {eh}{f'[{lo * 1e3:+.3f};{hi * 1e3:+.3f}]':>22}{p:>7.3f}"
              f"{(f'{padj:.3f}' if prim else '-'):>7}{(f'{st * 1e3:.3g}' if st else '-'):>8}  {bef}")
        if i == len(PRIMAER) - 1:
            w("-- explorativ (ohne Holm) --")
    n = len(bloecke)
    w("")
    w(f"Kleinstes p bei {n} Bloecken: {2 / 2 ** n:.4f}" + (" (Monte-Carlo)" if n > 16 else "")
      + f"; SESOI EXT5V Mittel {SESOI[PRIMAER[0]] * 1e3:.1f} mV, Rauschen {SESOI[PRIMAER[1]] * 1e3:.1f} mV")
    w("Aequivalent = 90%-KI (TOST) in +-SESOI. Schritt = haeufigster Werteabstand (nur Anzeige).")
    w("Grenze: PMIC misst gegen Platinenmasse; Gleichtakt, Ripple, HF, Audio-Brumm unsichtbar.")
    return out, ergebnisse


def schreibe_atomar(pfad, txt):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(pfad)), prefix=".ausw.")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(txt)
        os.replace(tmp, pfad)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# ---------------- Selbsttest ----------------
SYN_COLS = ["t_us", "dur_us", "throttled", "temp_mC", "play", "EXT5V_V", "HDMI_V", "VDD_CORE_V", "3V3_SYS_V", "VDD_CORE_A"]
Q = 0.00134


def _schreibe(pfad, zeilen):
    with open(pfad, "w") as fh:
        fh.write("\n".join(zeilen) + "\n")


def synth(d, eff=0.0, n=10, seed=1, play=None, thr=None, nproben=60, drift=.0008, leer=(), na=0):
    """10 Bloecke, je Segment 60 Proben, EXT5V quantisiert auf 1,34 mV, Blockdrift gauss(0, 0.8 mV)."""
    rnd = random.Random(seed)
    os.makedirs(d, exist_ok=True)
    _schreibe(os.path.join(d, "run.meta"), ["geraet=test", "version=1.2", "sha=x", "kernel=k",
                                            f"seed={seed}", f"bloecke={n}", "anderes_geraet_kabel=n"])
    plan, t = ["block,pos,cond"], 1700000000000000
    for b in range(1, n + 1):
        reihe = ("MIT", "OHNE") if rnd.random() < .5 else ("OHNE", "MIT")
        dr = rnd.gauss(0, drift)
        for pos, c in enumerate(reihe, 1):
            plan.append(f"{b},{pos},{c}")
            sid = f"b{b}_{c}"
            base = os.path.join(d, "seg_" + sid)
            pl, th = (play or {}).get(sid, "1"), (thr or {}).get(sid, "0x0")
            zeilen = [",".join(SYN_COLS)]
            for i in range(0 if sid in leer else nproben):
                t += 500000
                u = 5.05 + dr + (eff if c == "MIT" else 0.0) + rnd.gauss(0, .001)
                e = "NA" if i < na else f"{round(u / Q) * Q:.8f}"
                zeilen.append(f"{t},40000,{th},{45000 + rnd.randint(0, 500)},{pl},{e},{e},"
                              f"{0.72 + rnd.gauss(0, .0005):.8f},3.31467300,{0.9 + rnd.gauss(0, .01):.8f}")
            _schreibe(base + ".csv", zeilen)
            _schreibe(base + ".meta", [f"block={b}", "fehlproben=0", "verspaetet=0", "klog_settle=0", "klog_mess=0",
                                       "neterr_delta=0", "throttled_vor=0x0", "throttled_nach=0x0"])
            _schreibe(base + ".done", [""])
    _schreibe(os.path.join(d, "plan.csv"), plan)


def selbsttest():
    erg = []

    def chk(name, fn):
        try:
            r = bool(fn())
            info = ""
        except Exception as ex:  # Regressionstest: jede Exception ist ein Fehler
            r, info = False, f" ({type(ex).__name__}: {ex})"
        erg.append(r)
        if not r:
            print(f"  FAIL: {name}{info}")

    def zeile(out, key):
        return next((z for z in out if z.startswith(key)), "")

    d10 = [0.001 * (i + 1) for i in range(10)]
    chk("P01 exakt p n=10 -> 2/1024", lambda: abs(exakt_p(d10) - 2 / 1024) < 1e-12)
    chk("P02 Vorzeichen-Symmetrie", lambda: exakt_p(d10) == exakt_p([-x for x in d10]))
    chk("P03 Holm-Werte/Monotonie", lambda: holm([.01, .04]) == [.02, .04] and holm([.04, .01]) == [.04, .02])
    chk("P04 Holm: fehlender Endpunkt zaehlt als p=1", lambda: holm([.01, None]) == [.02, 1.0])
    chk("P05 Schritt = haeufigster Abstand", lambda: abs(lsb([5 + k * Q for k in range(20)] + [5.0001]) - Q) < 1e-9)
    chk("P06 Schritt leer = 0", lambda: lsb([]) == 0.0 and lsb([1.0, 1.0]) == 0.0)
    chk("P07 kenn <3 -> None", lambda: kenn([1.0, 2.0], "mean") is None and kenn(None, "noise") is None)
    chk("P08 kenn Mittel", lambda: abs(kenn([1.0, 2.0, 6.0], "mean") - 3.0) < 1e-12)
    drift = [i * 1e-4 for i in range(50)]
    chk("P09 Rauschmass driftbereinigt", lambda: kenn(drift, "noise") < 1e-12 and S.pstdev(drift) > 1e-3)
    chk("P10 fnum NA/nan/inf", lambda: fnum("NA") is None and fnum("nan") is None and fnum("inf") is None and fnum("1.5") == 1.5)
    chk("P11 n=5 -> KI unbegrenzt, n=6 begrenzt", lambda: ki([1.0, 2.0, 3.0, 4.0, 5.0]) == (-math.inf, math.inf)
        and ki([1.0, 2.0, 3.0, 4.0, 5.0, 6.0]) == (1.0, 6.0))
    dk = [0.5, 1.2, -0.3, 0.8, 1.5, 0.2, 0.9, 1.1, -0.1, 0.7]
    pk = p_fun(dk)[0]
    lo, hi = ki(dk)
    chk("P12 KI = Testinversion", lambda: pk(lo) >= .05 and pk(hi) >= .05 and pk(lo - 1e-6) < .05 and pk(hi + 1e-6) < .05)
    with tempfile.TemporaryDirectory() as tmp:
        synth(os.path.join(tmp, "e"), eff=.006, seed=3)
        out, eg = auswerten(os.path.join(tmp, "e"))
        chk("P13 6-mV-Effekt -> EFFEKT", lambda: "EFFEKT" in zeile(out, "EXT5V_V Mittel"))
        chk("P14 Effektgroesse 6 +- 1,5 mV", lambda: abs(eg[0][2][0] - .006) <= .0015)
        synth(os.path.join(tmp, "n"), eff=0.0, seed=4)
        out0, _ = auswerten(os.path.join(tmp, "n"))
        chk("P15 Nulleffekt -> aequivalent", lambda: "aequivalent" in zeile(out0, "EXT5V_V Mittel"))
        synth(os.path.join(tmp, "w"), seed=5, play={"b2_MIT": "0"})
        outw, _ = auswerten(os.path.join(tmp, "w"))
        chk("P16 Ausschluss Wiedergabe ungleich", lambda: "2:Wdg!=" in outw[1])
        chk("P17 Ausgabe <= 40 Zeilen", lambda: max(len(out), len(out0), len(outw)) <= 40)
        chk("P18 Holm-Grenzfall: roh p<.05, Holm>=.05 -> kein EFFEKT",
            lambda: befund(True, .03, .06, -.0005, .003, .002) != "EFFEKT" and befund(True, .01, .02, .001, .003, .002) == "EFFEKT")
        rnd = random.Random(9)
        fp = sum(exakt_p([rnd.gauss(0, .0011) for _ in range(10)]) < .05 for _ in range(60))
        chk("P19 Falsch-positiv-Rate <= 9/60", lambda: fp <= 9)
        synth(os.path.join(tmp, "l"), seed=6, leer=("b1_MIT",))
        outl, _ = auswerten(os.path.join(tmp, "l"))
        chk("P20 leeres Segment -> Ausschluss, keine Exception", lambda: "1:n<3" in outl[1])
        synth(os.path.join(tmp, "k"), n=2, nproben=1, seed=7)
        outk, _ = auswerten(os.path.join(tmp, "k"))
        chk("P21 1-Proben-Segmente -> ABBRUCH", lambda: any(z.startswith("ABBRUCH") for z in outk))
        synth(os.path.join(tmp, "a"), seed=8, na=5)
        me = lies_segment(os.path.join(tmp, "a", "seg_b1_MIT.csv"))[1]
        chk("P22 NA-Zeilen = Fehlproben", lambda: me["n"] == 55 and me["n_roh"] == 60)
        synth(os.path.join(tmp, "t"), seed=10, thr={"b3_OHNE": "0x4"})
        outt, _ = auswerten(os.path.join(tmp, "t"))
        chk("P23 aktive Drosselung -> Ausschluss", lambda: "3:Drossel" in outt[1])
    rnd = random.Random(11)
    hits = 0
    for _ in range(150):
        dd = [rnd.gauss(.3, 1) for _ in range(8)]
        a, b = ki(dd)
        hits += a <= .3 <= b
    chk("P24 Ueberdeckung Inversions-KI >= 90%", lambda: hits / 150 >= .90)

    def brute(d, mu):
        obs = sum(x - mu for x in d)
        ts = [sum(s * (x - mu) for s, x in zip(sv, d)) for sv in itertools.product((1, -1), repeat=len(d))]
        ge = sum(t >= obs - 1e-12 for t in ts)
        le = sum(t <= obs + 1e-12 for t in ts)
        return min(1.0, 2 * min(ge, le) / len(ts))

    rnd = random.Random(12)
    fall = [([round(rnd.gauss(.2, 1), 3) for _ in range(rnd.randint(1, 9))], rnd.gauss(0, 1)) for _ in range(80)]
    chk("P25 p(mu) = Brute-Force-Permutation", lambda: all(abs(p_fun(d)[0](mu) - brute(d, mu)) < 1e-12 for d, mu in fall))

    def konvex(d):
        pf = p_fun(d)
        lo, hi = ki(d, .05, pf)
        w = hi - lo
        gitter = [lo - w + i * 3 * w / 3000 for i in range(3001)]
        return all((pf[0](m) >= .05) == (lo <= m <= hi) for m in gitter)

    rnd = random.Random(13)
    chk("P26 Annahmebereich = genau [lo;hi] (konvex)",
        lambda: all(konvex([rnd.gauss(.3, 1) for _ in range(rnd.choice((6, 8, 10, 12)))]) for _ in range(30)))
    chk("P27 signifikant aber in SESOI -> irrelevant",
        lambda: befund(True, .001, .002, .0002, .0008, .002) == "EFFEKT < SESOI (irrelevant)")
    with tempfile.TemporaryDirectory() as tmp:
        pf = os.path.join(tmp, "s.csv")
        _schreibe(pf, ["t_us,EXT5V_V,VDD_CORE_A,VDD_CORE_V,HDMI_A,HDMI_V",
                       "1,5.0,2.0,0.9,0.1,5.0", "2,5.0,2.0,0.9,NA,5.0", "3,5.0,2.0,0.9,0.1,5.0"])
        chk("P28 P_PMIC_W nur aus vollstaendigen Zeilen",
            lambda: [round(x, 12) for x in lies_segment(pf)[0]["P_PMIC_W"]] == [2.3, 2.3])
    print(f"Selbsttest: {sum(erg)} ok, {len(erg) - sum(erg)} Fehler")
    return all(erg)


def main(argv):
    if len(argv) == 2 and argv[1] == "--selbsttest":
        return 0 if selbsttest() else 1
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print(__doc__, file=sys.stderr)
        return 1
    out, _ = auswerten(argv[1])
    txt = "\n".join(out)
    print(txt)
    try:
        schreibe_atomar(os.path.join(argv[1], "auswertung.txt"), txt + "\n")
    except OSError as ex:
        print(f"WARNUNG: auswertung.txt nicht geschrieben: {ex}", file=sys.stderr)
        return 3
    return 2 if any(z.startswith("ABBRUCH") for z in out) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
