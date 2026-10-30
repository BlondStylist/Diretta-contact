#!/usr/bin/env bash
# ext5v_install.sh v2.1 - legt ext5v_log.c, ext5v_run.sh, ext5v_stats.py an, baut den Logger, fuehrt Selbsttests aus
# (Statistik-Selbsttest + End-to-End-Test des Loggers mit simuliertem Mailbox-Transport).
# Aufruf: bash ext5v_install.sh [ZIELVERZEICHNIS]   (Standard: $HOME/ext5v; kein root noetig; gcc + python3 erforderlich)
set -eu
export LC_ALL=C
D=${1:-$HOME/ext5v}; mkdir -p "$D"
command -v gcc >/dev/null || { echo "gcc fehlt (auf diesem Geraet oder auf diretta-host bauen und per scp kopieren)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 fehlt"; exit 1; }
cat > "$D/ext5v_log.c" <<'EXT5V_EOF_C'
// ext5v_log.c v2.1 - EXT5V_V-Logger fuer Raspberry Pi 5: ein Mailbox-ioctl pro Sample, kein fork/exec.
// Build:  gcc -O2 -Wall -Wextra -o ext5v_log ext5v_log.c
// Aufruf: ext5v_log --probe                      (Selbstcheck: Befehl, Rohantwort, Latenz, Wertwechsel)
//         [EXT5V_CPU=n] [EXT5V_SCHED=idle|other] ext5v_log HZ SEKUNDEN OUT.csv
//         EXT5V_SCHED: idle (Standard, SCHED_IDLE) | other (SCHED_OTHER, nice 19; falls idle verhungert)
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>

#define VERSION "2.1"
#define MAX_STRING 4096
#define GET_GENCMD_RESULT 0x00030080u
#define IOCTL_MBOX_PROPERTY _IOWR(100, 0, char *)
#define MAX_CONSEC_ERR 20

#ifdef EXT5V_TEST_TRANSPORT
#include EXT5V_TEST_TRANSPORT
#else
static int transport_open(void) {
    static const char *dev[] = {"/dev/vcio_gencmd", "/dev/vcio"};
    for (unsigned i = 0; i < 2; i++) {
        int fd = open(dev[i], O_RDONLY | O_CLOEXEC);
        if (fd >= 0) return fd;
    }
    return -1;
}
/* Rueckgabe: 0 = OK; -1 = ioctl-Fehler; sonst Firmware-Fehlercode (p[5]). Layout wie raspberrypi/utils vcgencmd.c */
static int transport_gencmd(int fd, const char *cmd, char *out, size_t outlen) {
    static uint32_t p[(MAX_STRING >> 2) + 7];
    size_t len = strlen(cmd);
    if (len + 1 >= MAX_STRING || outlen == 0) return -1;
    memset(p, 0, sizeof p);
    unsigned i = 0;
    p[i++] = 0; p[i++] = 0; p[i++] = GET_GENCMD_RESULT; p[i++] = MAX_STRING; p[i++] = 0; p[i++] = 0;
    memcpy(p + i, cmd, len + 1);
    i += MAX_STRING >> 2;
    p[i++] = 0;
    p[0] = i * sizeof p[0];
    if (ioctl(fd, IOCTL_MBOX_PROPERTY, p) < 0) return -1;
    size_t n = outlen - 1 < MAX_STRING ? outlen - 1 : MAX_STRING;
    memcpy(out, p + 6, n);
    out[n] = '\0';
    return (int)p[5];
}
#endif

static volatile sig_atomic_t stop_flag = 0;
static void on_sig(int s) { (void)s; stop_flag = 1; }
static double raw_now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC_RAW, &t); return (double)t.tv_sec + t.tv_nsec * 1e-9; }
static void ts_add(struct timespec *t, long long ns) { long long n = t->tv_nsec + ns; t->tv_sec += n / 1000000000LL; t->tv_nsec = (long)(n % 1000000000LL); }
static long long ts_diff(const struct timespec *a, const struct timespec *b) { return (long long)(a->tv_sec - b->tv_sec) * 1000000000LL + (a->tv_nsec - b->tv_nsec); }

/* EXT5V_V-Wert aus Antwort; Zeile "... EXT5V_V volt(24)=5.10138000V" (auch wenn weitere Schienen enthalten sind) */
static int parse_ext5v(const char *s, double *v) {
    const char *k = strstr(s, "EXT5V_V");
    if (!k) return -1;
    const char *e = strchr(k, '=');
    const char *nl = strchr(k, '\n');
    if (!e || (nl && e > nl)) return -1;
    char *end;
    double x = strtod(e + 1, &end);
    if (end == e + 1 || *end != 'V' || !(x > 0.0 && x < 10.0)) return -1;
    *v = x;
    return 0;
}

static void affinity_str(char *s, size_t n) {
    cpu_set_t set; size_t o = 0; s[0] = '\0';
    if (sched_getaffinity(0, sizeof set, &set)) { snprintf(s, n, "?"); return; }
    for (int c = 0; c < CPU_SETSIZE && o + 8 < n; c++)
        if (CPU_ISSET(c, &set)) o += (size_t)snprintf(s + o, n - o, "%s%d", o ? "," : "", c);
}

int main(int argc, char **argv) {
    static const char *cmds[2] = {"pmic_read_adc EXT5V_V", "pmic_read_adc"};
    int probe = (argc == 2 && !strcmp(argv[1], "--probe"));
    if (!probe && argc != 4) { fprintf(stderr, "usage: %s --probe | HZ SEKUNDEN OUT.csv   (env: EXT5V_CPU)\n", argv[0]); return 2; }
    double hz = 0, dur = 0;
    if (!probe) {
        char *e1, *e2;
        hz = strtod(argv[1], &e1); dur = strtod(argv[2], &e2);
        if (!*argv[1] || *e1 || !*argv[2] || *e2 || !(hz >= 0.1 && hz <= 200.0) || !(dur >= 1.0 && dur <= 86400.0) || hz * dur > 5e6) {
            fprintf(stderr, "ext5v_log: ungueltige Parameter (HZ 0.1..200, SEKUNDEN 1..86400, HZ*SEKUNDEN<=5e6)\n");
            return 2;
        }
    }
    int fd = transport_open();
    if (fd < 0) { fprintf(stderr, "ext5v_log: /dev/vcio_gencmd und /dev/vcio nicht oeffnbar: %s\n", strerror(errno)); return 1; }

    static char buf[MAX_STRING];
    double v = 0; int ci = -1;
    for (int c = 0; c < 2 && ci < 0; c++) {
        int rc = transport_gencmd(fd, cmds[c], buf, sizeof buf);
        if (rc == 0 && parse_ext5v(buf, &v) == 0) ci = c;
        else fprintf(stderr, "ext5v_log: Befehl \"%s\" unbrauchbar: rc=%d %s%s\n", cmds[c], rc, rc < 0 ? "(ioctl-Fehler) " : "Antwort: ", rc < 0 ? "" : buf);
    }
    if (ci < 0) return 1;
    const char *cmd = cmds[ci];

    if (probe) {
        printf("cmd=\"%s\"\nraw:\n%s\n", cmd, buf);
        double lmin = 1e9, lmax = 0, last = -1; int distinct = 0, okc = 0;
        for (int i = 0; i < 20; i++) {
            double a = raw_now();
            int rc = transport_gencmd(fd, cmd, buf, sizeof buf);
            double b = raw_now(), x;
            if (rc == 0 && parse_ext5v(buf, &x) == 0) { okc++; if (x != last) distinct++; last = x; }
            double us = (b - a) * 1e6; if (us < lmin) lmin = us; if (us > lmax) lmax = us;
            struct timespec d = {0, 50000000}; nanosleep(&d, NULL);
        }
        printf("20 Aufrufe @20 Hz: gueltig=%d, call_us min=%.0f max=%.0f, Wertwechsel=%d, letzter Wert=%.6f V\n", okc, lmin, lmax, distinct, last);
        return okc == 20 ? 0 : 1;
    }

    size_t cap = (size_t)(hz * dur) + 16;
    double *T = calloc(cap, sizeof *T), *V = calloc(cap, sizeof *V);
    float *L = calloc(cap, sizeof *L); short *C = calloc(cap, sizeof *C);
    int rc_main = 0;
    if (!T || !V || !L || !C) { fprintf(stderr, "ext5v_log: Speicher\n"); rc_main = 1; goto out; }
    int mlocked = (mlockall(MCL_CURRENT | MCL_FUTURE) == 0);

    long cpu_req = -1; const char *ce = getenv("EXT5V_CPU");
    if (ce && *ce) {
        char *e; cpu_req = strtol(ce, &e, 10);
        if (*e || cpu_req < 0 || cpu_req >= CPU_SETSIZE) { fprintf(stderr, "ext5v_log: EXT5V_CPU ungueltig\n"); rc_main = 2; goto out; }
        cpu_set_t s; CPU_ZERO(&s); CPU_SET((int)cpu_req, &s);
        if (sched_setaffinity(0, sizeof s, &s)) { fprintf(stderr, "ext5v_log: sched_setaffinity(%ld): %s\n", cpu_req, strerror(errno)); rc_main = 1; goto out; }
    }
    const char *se = getenv("EXT5V_SCHED");
    int want_idle = 1;
    if (se && *se) {
        if (!strcmp(se, "other")) want_idle = 0;
        else if (strcmp(se, "idle")) { fprintf(stderr, "ext5v_log: EXT5V_SCHED ungueltig (idle|other)\n"); rc_main = 2; goto out; }
    }
    struct sched_param sp; memset(&sp, 0, sizeof sp);
    int idle_ok = 0, nice_ok = 0;
    if (want_idle) idle_ok = (sched_setscheduler(0, SCHED_IDLE, &sp) == 0);
    else { errno = 0; nice_ok = (sched_setscheduler(0, SCHED_OTHER, &sp) == 0 && setpriority(PRIO_PROCESS, 0, 19) == 0); }

    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig;
    sigaction(SIGINT, &sa, NULL); sigaction(SIGTERM, &sa, NULL);

    const long long step = (long long)(1e9 / hz);
    struct timespec next; clock_gettime(CLOCK_MONOTONIC, &next);
    double t0 = raw_now();
    size_t k = 0; unsigned errs = 0, consec = 0, missed = 0; int failed = 0;
    while (!stop_flag && k < cap) {
        double a = raw_now();
        int rc = transport_gencmd(fd, cmd, buf, sizeof buf);
        double b = raw_now(), x;
        if (rc == 0 && parse_ext5v(buf, &x) == 0) {
            T[k] = a - t0; V[k] = x; L[k] = (float)((b - a) * 1e6); C[k] = (short)sched_getcpu(); k++; consec = 0;
        } else {
            errs++;
            if (++consec >= MAX_CONSEC_ERR) { fprintf(stderr, "ext5v_log: %d Fehler in Folge, Abbruch (rc=%d)\n", MAX_CONSEC_ERR, rc); failed = 1; break; }
        }
        if (b - t0 >= dur) break;
        ts_add(&next, step);
        struct timespec nm; clock_gettime(CLOCK_MONOTONIC, &nm);
        long long late = ts_diff(&nm, &next);          /* >=0: Slot bereits verstrichen -> ueberspringen, kein Burst */
        if (late >= 0) { long long m = late / step + 1; missed += (unsigned)m; ts_add(&next, m * step); }
        while (!stop_flag && clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL) == EINTR) {}
    }
    close(fd);
    struct rusage ru; getrusage(RUSAGE_SELF, &ru);
    char aff[256]; affinity_str(aff, sizeof aff);
    int idle_now = (sched_getscheduler(0) == SCHED_IDLE);
    int nice_now = (sched_getscheduler(0) == SCHED_OTHER && getpriority(PRIO_PROCESS, 0) == 19);

    char tmp[4096]; snprintf(tmp, sizeof tmp, "%s.tmp", argv[3]);
    FILE *f = fopen(tmp, "w");
    if (!f) { fprintf(stderr, "ext5v_log: fopen %s: %s\n", tmp, strerror(errno)); rc_main = 1; goto out; }
    fprintf(f, "# ext5v_log %s cmd=\"%s\" hz=%g dur=%g n=%zu errs=%u missed=%u failed=%d cpu_req=%ld affinity=%s sched_req=%s idle=%d nice19=%d mlock=%d "
               "utime_s=%.3f stime_s=%.3f nvcsw=%ld nivcsw=%ld minflt=%ld majflt=%ld\n",
            VERSION, cmd, hz, dur, k, errs, missed, failed, cpu_req, aff, want_idle ? "idle" : "other", idle_ok && idle_now, nice_ok && nice_now, mlocked,
            ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6, ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6,
            ru.ru_nvcsw, ru.ru_nivcsw, ru.ru_minflt, ru.ru_majflt);
    fprintf(f, "t_s,v_V,call_us,cpu\n");
    for (size_t i = 0; i < k; i++) fprintf(f, "%.6f,%.6f,%.1f,%d\n", T[i], V[i], (double)L[i], (int)C[i]);
    /* nacheinander pruefen: eine unvollstaendige Datei darf nie unter dem Zielnamen landen */
    int werr = ferror(f);
    if (fclose(f) != 0 || werr) { fprintf(stderr, "ext5v_log: Schreiben von %s fehlgeschlagen: %s\n", tmp, strerror(errno)); unlink(tmp); rc_main = 1; goto out; }
    if (rename(tmp, argv[3]) != 0) { fprintf(stderr, "ext5v_log: Umbenennen nach %s fehlgeschlagen: %s\n", argv[3], strerror(errno)); unlink(tmp); rc_main = 1; goto out; }
    rc_main = (failed || k == 0) ? 1 : 0;
out:
    free(T); free(V); free(L); free(C);
    return rc_main;
}
EXT5V_EOF_C
cat > "$D/ext5v_run.sh" <<'EXT5V_EOF_RUN'
#!/usr/bin/env bash
# ext5v_run.sh v2.1 - ein Messlauf inkl. Metadaten. HZ=0 (exakt "0") = Referenzlauf OHNE Logger.
# Aufruf: [EXT5V_CPU=n] [EXT5V_SCHED=idle|other] [EXT5V_OUT=/dev/shm] ext5v_run.sh HZ SEKUNDEN TAG     (gibt den Ergebnisordner aus)
set -u
export LC_ALL=C
HZ=${1:?HZ (0 = ohne Logger)}; DUR=${2:?SEKUNDEN}; TAG=${3:-run}
case $TAG in ''|*[!A-Za-z0-9.-]*) echo "TAG nur A-Za-z0-9.-" >&2; exit 2;; esac
case $HZ in 0) ;; *[!0-9.]*|'') echo "HZ ungueltig" >&2; exit 2;; esac
case $DUR in ''|*[!0-9]*) echo "SEKUNDEN ungueltig" >&2; exit 2;; esac
[ "$((10#$DUR))" -ge 1 ] || { echo "SEKUNDEN >= 1" >&2; exit 2; }
DUR=$((10#$DUR))
BIN=${EXT5V_BIN:-$(dirname "$(readlink -f "$0")")/ext5v_log}
OUT=${EXT5V_OUT:-/dev/shm}/ext5v_$(date +%Y%m%d_%H%M%S)_$TAG
mkdir "$OUT" || exit 1
vc() { if command -v vcgencmd >/dev/null 2>&1; then vcgencmd "$@" 2>&1 | tr '\n' ' '; else echo n/a; fi; }
snap() { grep '^cpu[0-9]' /proc/stat > "$OUT/$1"; }
{
  echo "date=$(date -Is)"; echo "tag=$TAG"; echo "hz=$HZ"; echo "dur=$DUR"; echo "cpu_req=${EXT5V_CPU:--}"; echo "sched_req=${EXT5V_SCHED:-idle}"
  echo "host=$(hostname) kernel=$(uname -r)"; echo "fw=$(vc version)"
  echo "cmdline=$(cat /proc/cmdline)"; echo "isolated=$(cat /sys/devices/system/cpu/isolated 2>/dev/null)"
  echo "loadavg=$(cut -d' ' -f1-3 /proc/loadavg)"
  if [ "$HZ" != 0 ]; then echo "bin_sha256=$(sha256sum "$BIN" 2>/dev/null | cut -d' ' -f1)"; fi
  echo "script_sha256=$(sha256sum "$0" | cut -d' ' -f1)"
  echo "throttled_before=$(vc get_throttled)"; echo "temp_before=$(vc measure_temp) pmic=$(vc measure_temp pmic)"
} > "$OUT/meta.txt"
snap stat_before.txt
rc=0
if [ "$HZ" = 0 ]; then sleep "$DUR"; else "$BIN" "$HZ" "$DUR" "$OUT/ext5v.csv" 2> "$OUT/logger.err" || rc=$?; fi
snap stat_after.txt
{ echo "throttled_after=$(vc get_throttled)"; echo "temp_after=$(vc measure_temp) pmic=$(vc measure_temp pmic)"; echo "logger_rc=$rc"; } >> "$OUT/meta.txt"
echo "$OUT"
exit $rc
EXT5V_EOF_RUN
cat > "$D/ext5v_stats.py" <<'EXT5V_EOF_STATS'
#!/usr/bin/env python3
"""ext5v_stats.py v2.1 - Auswertung von ext5v_run-Ordnern (nur Standardbibliothek).
Aufruf: ext5v_stats.py ORDNER [ORDNER ...]   |   ext5v_stats.py --selftest"""
import math, os, re, shlex, sys

LSB = 0.00134      # V/Code; belegt durch oeffentliche Ausgaben (z. B. 5.06788 V = 3782 x 1.34 mV), pro Lauf gegen die Daten geprueft
CODE_MAX = 4095    # Annahme 12 bit (nicht dokumentiert) -> Saettigungsgate nur WARN

def mean(a): return math.fsum(a) / len(a)
def sd(a):
    if len(a) < 2: return 0.0
    m = mean(a); return math.sqrt(max(0.0, math.fsum((x - m) ** 2 for x in a) / (len(a) - 1)))
def pct(s, p):                                   # s sortiert; lineare Interpolation (= numpy.percentile)
    r = (len(s) - 1) * p / 100.0; lo = int(math.floor(r)); hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (r - lo)
def ols(t, v):                                   # Steigung [V/s] und naive Standardabweichung der Steigung
    n = len(t); tm, vm = mean(t), mean(v)
    sxx = math.fsum((x - tm) ** 2 for x in t)
    if n < 3 or sxx == 0: return 0.0, float("nan")
    b = math.fsum((x - tm) * (y - vm) for x, y in zip(t, v)) / sxx
    rss = math.fsum((y - vm - b * (x - tm)) ** 2 for x, y in zip(t, v))
    return b, math.sqrt(rss / (n - 2) / sxx)
def batch_sem(v, nb=20):                         # Standardfehler des Mittels aus Blockmitteln (beruecksichtigt Autokorrelation grob)
    if len(v) < nb * 10: return float("nan")
    L = len(v) // nb; bm = [mean(v[i * L:(i + 1) * L]) for i in range(nb)]
    return sd(bm) / math.sqrt(nb)
def adev(v, dt):                                 # nicht ueberlappende Allan-Abweichung bei tau = k*dt
    out, k = [], 1
    while len(v) // k >= 8:
        m = len(v) // k; y = [mean(v[i * k:(i + 1) * k]) for i in range(m)]
        out.append((k * dt, math.sqrt(math.fsum((y[i + 1] - y[i]) ** 2 for i in range(m - 1)) / (2 * (m - 1))))); k *= 2
    return out
def lsb_mode(v):                                 # haeufigster Abstand benachbarter distinkter Werte (robust gegen Luecken)
    u = sorted(set(round(x, 6) for x in v)); cnt = {}
    for a, b in zip(u, u[1:]): d = round(b - a, 6); cnt[d] = cnt.get(d, 0) + 1
    if not cnt: return float("nan")
    m = max(cnt.values()); return min(d for d, c in cnt.items() if c == m)
def thr_bits(x):                                 # "throttled=0x50000 " -> int, sonst None
    m = re.search(r"throttled=(0x[0-9a-fA-F]+)", x or ""); return int(m.group(1), 16) if m else None
def is_baseline(meta):                           # v2.1: eigene Zeile hz=0; v2.0: "tag=X hz=0 dur=..."
    if "hz" in meta: return meta["hz"].strip() == "0"
    return meta.get("tag", "").split("hz=")[-1].split()[:1] == ["0"]
def mean_run(v):                                 # mittlere Laenge gleicher aufeinanderfolgender Werte
    runs, c = [], 1
    for a, b in zip(v, v[1:]):
        if a == b: c += 1
        else: runs.append(c); c = 1
    runs.append(c); return mean(runs)

def analyze(t, v, call, hdr):
    R = {"n": len(v)}
    if len(v) < 3: return R
    dts = sorted(b - a for a, b in zip(t, t[1:])); dur = t[-1] - t[0]
    R.update(dur=dur, rate=(len(v) - 1) / dur if dur > 0 else float("nan"), dt50=pct(dts, 50), dt99=pct(dts, 99), dtmax=dts[-1])
    cs = sorted(call); R.update(c50=pct(cs, 50), c99=pct(cs, 99), cmax=cs[-1])
    s = sorted(v)
    R.update(min=s[0], p001=pct(s, .1), p01=pct(s, 1), p50=pct(s, 50), p99=pct(s, 99), p999=pct(s, 99.9), max=s[-1],
             mean=mean(v), sd=sd(v), pp=s[-1] - s[0], sem=batch_sem(v))
    b, se = ols(t, v); R.update(drift=b * 3.6e6, drift_se=se * 3.6e6)
    dist = sorted(set(round(x, 6) for x in v)); diffs = sorted(round(y - x, 6) for x, y in zip(dist, dist[1:]))
    R.update(ndist=len(dist), lsb_min=diffs[0] if diffs else float("nan"), lsb_med=pct(diffs, 50) if diffs else float("nan"), lsb_mode=lsb_mode(v))
    codes = [round(x / LSB) for x in v]; res = max(abs(x - c * LSB) for x, c in zip(v, codes))
    R.update(grid_ok=res < 2e-6, grid_res=res, sat=sum(c >= CODE_MAX for c in codes), zero=sum(c <= 0 for c in codes),
             cmin=min(codes), cmax_code=max(codes), run=mean_run(v), adev=adev(v, R["dt50"]))
    return R

def gates(R, hdr, meta):
    G = []
    def g(name, ok, info, warn=False): G.append(("PASS" if ok else ("WARN" if warn else "FAIL"), name, info))
    if R["n"] < 3: return [("FAIL", "Daten", "weniger als 3 Samples")]
    hz = float(hdr.get("hz", "nan"))
    g("Lesefehler", hdr.get("errs") == "0" and hdr.get("failed") == "0", f"errs={hdr.get('errs')} failed={hdr.get('failed')}")
    g("Rate", abs(R["rate"] - hz) / hz <= 0.01, f"{R['rate']:.3f} S/s (Soll {hz:g})", True)
    exp = hz * R["dur"]; g("verpasste Slots", int(hdr.get("missed", "0")) <= 0.005 * exp, f"missed={hdr.get('missed')} von ~{exp:.0f}", True)
    g("Takt-Jitter", R["dt99"] <= 1.5 / hz, f"dt P99={R['dt99'] * 1e3:.1f} ms (Periode {1e3 / hz:.0f} ms)", True)
    aff = hdr.get("affinity", "?"); pinned = aff.isdigit() and R.get("cpus", set()) <= {int(aff)}
    g("Pinning", pinned, f"affinity={aff} cpu_req={hdr.get('cpu_req')} genutzt={sorted(R.get('cpus', []))}", True)
    if hdr.get("sched_req") == "other": g("Scheduling", hdr.get("nice19") == "1", f"SCHED_OTHER nice 19 angefordert, wirksam={hdr.get('nice19')}", True)
    else: g("SCHED_IDLE", hdr.get("idle") == "1", f"idle={hdr.get('idle')}", True)
    g("ADC-Raster", R["grid_ok"], f"alle Werte = k x {LSB * 1e3:.2f} mV (max. Abw. {R['grid_res'] * 1e6:.2f} uV)", True)
    lm = R["lsb_mode"]
    if R["ndist"] >= 3: g("LSB-Schaetzung", abs(lm - LSB) <= 0.02 * LSB, f"haeufigster Schritt {lm * 1e3:.3f} mV (erwartet {LSB * 1e3:.2f} mV)", True)
    g("Saettigung", R["sat"] == 0 and R["zero"] == 0, f"{R['sat']} Samples bei Code>={CODE_MAX} ({CODE_MAX * LSB:.4f} V, Annahme 12 bit), {R['zero']} bei 0", True)
    tb, ta = thr_bits(meta.get("throttled_before")), thr_bits(meta.get("throttled_after"))
    if tb is not None and ta is not None:            # Bits 0-3 aktuell, 16-19 sticky seit Boot -> nur NEUE Sticky-Bits zaehlen
        g("Drosselung/Unterspannung", not (tb & 0xF) and not (ta & 0xF) and not (ta & ~tb & 0xF0000),
          f"vorher=0x{tb:x} nachher=0x{ta:x} (aktiv vorher/nachher={tb & 0xF:#x}/{ta & 0xF:#x}, neu sticky={ta & ~tb & 0xF0000:#x})")
    elif any(not meta.get(k, "n/a").startswith("n/a") for k in ("throttled_before", "throttled_after")):
        g("Drosselung/Unterspannung", False, f"nicht auswertbar: {meta.get('throttled_before')!r} / {meta.get('throttled_after')!r}", True)
    return G

def load(d):
    hdr, t, v, c, cpus = {}, [], [], [], set()
    with open(os.path.join(d, "ext5v.csv")) as f:
        for line in f:
            if line.startswith("# "):
                for tok in shlex.split(line[2:])[2:]:
                    if "=" in tok: k, x = tok.split("=", 1); hdr[k] = x
            elif line[:1].isdigit():
                p = line.split(","); t.append(float(p[0])); v.append(float(p[1])); c.append(float(p[2])); cpus.add(int(p[3]))
    meta = {}
    try:
        for line in open(os.path.join(d, "meta.txt")):
            tok = line.strip()
            if "=" in tok: k, x = tok.split("=", 1); meta[k] = x
    except OSError: pass
    return hdr, t, v, c, cpus, meta

def busy(d):
    def rd(n):
        r = {}
        for line in open(os.path.join(d, n)):
            p = line.split(); f = [int(x) for x in p[1:9]]; r[p[0]] = (sum(f), f[3] + f[4])
        return r
    try: a, b = rd("stat_before.txt"), rd("stat_after.txt")
    except (OSError, IndexError, ValueError): return {}
    return {k: 100.0 * (1 - (b[k][1] - a[k][1]) / (b[k][0] - a[k][0])) for k in a if k in b and b[k][0] > a[k][0]}

def report(d):
    tag = os.path.basename(d.rstrip("/")).split("_", 3)[-1]
    if not os.path.exists(os.path.join(d, "ext5v.csv")):
        m = {}
        try:
            for line in open(os.path.join(d, "meta.txt")):
                if "=" in line: k, x = line.strip().split("=", 1); m[k] = x
        except OSError: pass
        if is_baseline(m):
            print(f"== {tag}  (Referenzlauf ohne Logger)")
            print("Kernlast waehrend Lauf: " + "  ".join(f"{k}={x:.2f}%" for k, x in sorted(busy(d).items())))
        else:
            err = ""
            try: err = open(os.path.join(d, "logger.err")).readline().strip()
            except OSError: pass
            print(f"== {tag}  [FAIL] keine Messdaten (logger_rc={m.get('logger_rc', '?')}) {err}")
        return {"n": 0, "tag": tag}
    hdr, t, v, c, cpus, meta = load(d)
    R = analyze(t, v, c, hdr); R["cpus"] = cpus
    print(f"== {os.path.basename(d.rstrip('/'))}  ({hdr.get('cmd')}, hz={hdr.get('hz')}, dur={hdr.get('dur')} s)")
    if R["n"] < 3: print("zu wenige Samples"); return R
    mv = lambda x: f"{x * 1e3:.2f}"
    print(f"N={R['n']}  Dauer={R['dur']:.1f}s  Rate={R['rate']:.3f} S/s  dt P50/P99/max={R['dt50'] * 1e3:.1f}/{R['dt99'] * 1e3:.1f}/{R['dtmax'] * 1e3:.1f} ms  Aufruf P50/P99/max={R['c50']:.0f}/{R['c99']:.0f}/{R['cmax']:.0f} us")
    print(f"Spannung [V]: min={R['min']:.5f} P0.1={R['p001']:.5f} P1={R['p01']:.5f} P50={R['p50']:.5f} P99={R['p99']:.5f} P99.9={R['p999']:.5f} max={R['max']:.5f}")
    sem = "n/a (<200 Samples)" if math.isnan(R["sem"]) else f"{mv(R['sem'])} mV"
    print(f"mean={R['mean']:.5f} V (SEM Blockmittel {sem})  sd={mv(R['sd'])} mV  pp={mv(R['pp'])} mV  P99.9-P0.1={mv(R['p999'] - R['p001'])} mV")
    dn = "" if R["dur"] >= 600 else "  [Lauf < 600 s: Drift nicht aussagekraeftig]"
    print(f"Drift={R['drift']:+.2f} +/- {R['drift_se']:.2f} mV/h (naiv, ohne Autokorrelation){dn}   Quantisierungsrauschen sd={LSB / math.sqrt(12) * 1e3:.2f} mV")
    print(f"distinkte Werte={R['ndist']}  LSB min/median/haeufigst={mv(R['lsb_min'])}/{mv(R['lsb_med'])}/{mv(R['lsb_mode'])} mV  Codes {R['cmin']}..{R['cmax_code']}  mittlere Lauflaenge gleicher Werte={R['run']:.2f} Samples")
    print("ADEV: " + "  ".join(f"tau={a:.3g}s:{mv(b)}mV" for a, b in R["adev"]))
    ds = sorted(set(round(x / LSB) for x in v))
    if len(ds) <= 24:
        cnt = {}
        for x in v: cnt[round(x / LSB)] = cnt.get(round(x / LSB), 0) + 1
        print("Codes: " + "  ".join(f"{k * LSB:.5f}V:{cnt[k]}" for k in ds))
    bs = busy(d)
    if bs: print("Kernlast waehrend Lauf: " + "  ".join(f"{k}={x:.2f}%" for k, x in sorted(bs.items())))
    print(f"Logger-Eigenlast: utime={hdr.get('utime_s')}s stime={hdr.get('stime_s')}s nvcsw={hdr.get('nvcsw')} nivcsw={hdr.get('nivcsw')} majflt={hdr.get('majflt')}")
    for st, n, i in gates(R, hdr, meta): print(f"[{st}] {n}: {i}")
    R["tag"] = os.path.basename(d.rstrip("/")).split("_", 3)[-1]
    return R

def compare(Rs):
    print("\n== Vergleich (mean/sd in V bzw. mV)")
    print(f"{'Tag':<14}{'N':>7}{'mean':>10}{'sd':>8}{'P0.1':>10}{'P99.9':>10}{'min':>10}{'max':>10}{'drift mV/h':>12}")
    for R in Rs:
        if R["n"] >= 3: print(f"{R['tag']:<14}{R['n']:>7}{R['mean']:>10.5f}{R['sd'] * 1e3:>8.2f}{R['p001']:>10.5f}{R['p999']:>10.5f}{R['min']:>10.5f}{R['max']:>10.5f}{R['drift']:>+12.2f}")
    grp = {}
    for R in Rs:
        if R["n"] >= 3: grp.setdefault(R["tag"], []).append(R["mean"])
    for k, m in grp.items():
        if len(m) > 1: print(f"Tag {k}: {len(m)} Laeufe, Mittel der Mittelwerte {mean(m):.5f} V, Streuung zwischen den Laeufen sd={sd(m) * 1e3:.2f} mV")

def selftest():
    import random
    rnd = random.Random(12345); fails = []
    def chk(name, ok, info=""):
        print(f"[{'PASS' if ok else 'FAIL'}] {name} {info}"); 
        if not ok: fails.append(name)
    s = [1, 2, 3, 4, 5]
    chk("Perzentil", pct(s, 0) == 1 and pct(s, 50) == 3 and pct(s, 25) == 2 and pct(s, 100) == 5 and abs(pct(s, 10) - 1.4) < 1e-12)
    n, dt = 9000, 0.2; t = [i * dt for i in range(n)]
    v = [round((5.1 + 0.003 * x / 3600 + rnd.gauss(0, 0.001)) / LSB) * LSB for x in t]
    R = analyze(t, v, [800.0] * n, {})
    chk("Mittelwert", abs(R["mean"] - 5.10075) < 2e-4, f"{R['mean']:.5f}")
    chk("Drift", abs(R["drift"] - 3.0) < 4 * R["drift_se"], f"{R['drift']:+.2f} +/- {R['drift_se']:.2f} (Soll +3.00)")
    chk("LSB-Erkennung", abs(R["lsb_min"] - LSB) < 2e-6 and R["grid_ok"], f"{R['lsb_min'] * 1e3:.3f} mV")
    w = [round((5.1 + rnd.gauss(0, 0.002)) / LSB) * LSB for _ in range(9000)]
    a = adev(w, 0.2); r = a[0][1] / a[4][1]
    chk("ADEV weisses Rauschen ~ 1/sqrt(k)", 3.0 < r < 5.0, f"ADEV(1)/ADEV(16)={r:.2f} (Soll ~4)")
    c = analyze([i * 0.2 for i in range(50)], [5.1] * 50, [800.0] * 50, {})
    chk("konstante Reihe", c["sd"] == 0.0 and c["pp"] == 0.0)
    chk("kurze Reihe", analyze([0, 1], [5.1, 5.1], [1, 1], {})["n"] == 2)
    sat = analyze([i * 0.2 for i in range(50)], [5.1] * 49 + [CODE_MAX * LSB], [800.0] * 50, {})
    chk("Saettigungserkennung", sat["sat"] == 1, f"sat={sat['sat']}")
    gap = [LSB * c for c in (3800, 3801, 3802, 3805, 3806, 3807)]
    chk("LSB-Schaetzung mit Luecke", abs(lsb_mode(gap) - LSB) < 1e-9, f"{lsb_mode(gap) * 1e3:.3f} mV")
    def gt(tb, ta):
        R = analyze([i * 0.2 for i in range(50)], [5.1] * 50, [800.0] * 50, {})
        return [x for x in gates(R, {"hz": "5", "errs": "0", "failed": "0", "missed": "0"},
                                 {"throttled_before": tb, "throttled_after": ta}) if x[1].startswith("Drossel")][0][0]
    chk("Drossel-Gate: Sticky seit Boot ist kein Fehler", gt("throttled=0x50000 ", "throttled=0x50000 ") == "PASS")
    chk("Drossel-Gate: neues Sticky-Bit / aktiv = FAIL", gt("throttled=0x0 ", "throttled=0x50000 ") == "FAIL" and gt("throttled=0x0 ", "throttled=0x4 ") == "FAIL")
    chk("Drossel-Gate: Muell = WARN", gt("error=1 ", "throttled=0x0 ") == "WARN")
    chk("Referenzlauf-Erkennung v2.0/v2.1", is_baseline({"hz": "0"}) and not is_baseline({"hz": "10"})
        and is_baseline({"tag": "base hz=0 dur=60 cpu_req=-"}) and not is_baseline({"tag": "x hz=0.5 dur=60"}))
    print("SELBSTTEST:", "OK" if not fails else "FEHLER " + ", ".join(fails)); return 1 if fails else 0

if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest": sys.exit(selftest())
    if len(sys.argv) < 2: print(__doc__); sys.exit(2)
    Rs = [report(d) for d in sys.argv[1:]]
    if len(Rs) > 1: compare(Rs)
EXT5V_EOF_STATS
chmod +x "$D/ext5v_run.sh" "$D/ext5v_stats.py"
gcc -O2 -Wall -Wextra -o "$D/ext5v_log" "$D/ext5v_log.c"
python3 "$D/ext5v_stats.py" --selftest
# --- End-to-End-Test: echter Logger-Code, nur der Mailbox-Transport ist simuliert (12-bit-Codes x 1.34 mV)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/mock.h" <<'EXT5V_EOF_MOCK'
static int transport_open(void) { return open("/dev/null", O_RDONLY | O_CLOEXEC); }
static int transport_gencmd(int fd, const char *cmd, char *out, size_t outlen) {
    static unsigned s = 12345; (void)fd; (void)cmd;
    s = s * 1103515245u + 12345u;
    struct timespec d = {0, 300000}; nanosleep(&d, NULL);
    if (getenv("MOCK_FAIL")) { snprintf(out, outlen, "error=1 error_msg=\"Command not registered\""); return 0; }
    snprintf(out, outlen, "     EXT5V_V volt(24)=%.8fV\n", (3806 + (int)((s >> 16) % 3)) * 0.00134);
    return 0;
}
EXT5V_EOF_MOCK
gcc -O2 -Wall -Wextra -DEXT5V_TEST_TRANSPORT="\"$T/mock.h\"" -o "$T/ext5v_mock" "$D/ext5v_log.c"
E2E_FAIL=0
e2e() { if eval "$2"; then echo "[PASS] E2E $1"; else echo "[FAIL] E2E $1"; E2E_FAIL=1; fi; }
R1=$(EXT5V_BIN="$T/ext5v_mock" EXT5V_OUT="$T" EXT5V_CPU=0 bash "$D/ext5v_run.sh" 50 2 e2e) || true
python3 "$D/ext5v_stats.py" "$R1" > "$T/r1.txt" 2>&1 || true
e2e "Messlauf schreibt CSV + Meta" '[ -s "$R1/ext5v.csv" ] && grep -q "^logger_rc=0$" "$R1/meta.txt" && grep -q "^hz=50$" "$R1/meta.txt"'
e2e "~100 Samples in 2 s @50 Hz" 'n=$(grep -c "^[0-9]" "$R1/ext5v.csv"); [ "$n" -ge 95 ] && [ "$n" -le 102 ]'
e2e "Auswertung: Lesefehler/Rate/Raster/LSB PASS" 'for x in Lesefehler Rate ADC-Raster LSB-Schaetzung Pinning; do grep -q "^\[PASS\] $x" "$T/r1.txt" || exit 1; done'
e2e "Mittelwert = Mock-Mittel 5.10138 V +- 1 LSB" 'awk -F, '"'"'/^[0-9]/{s+=$2;n++} END{m=s/n; exit !(m>5.10004 && m<5.10272)}'"'"' "$R1/ext5v.csv"'
R2=$(MOCK_FAIL=1 EXT5V_BIN="$T/ext5v_mock" EXT5V_OUT="$T" bash "$D/ext5v_run.sh" 50 2 fail) && E2E_FAIL=1
python3 "$D/ext5v_stats.py" "$R2" > "$T/r2.txt" 2>&1 || true
e2e "Firmware-Fehlertext -> Abbruch, FAIL im Bericht" 'grep -q "^logger_rc=1$" "$R2/meta.txt" && [ ! -e "$R2/ext5v.csv" ] && grep -q "FAIL\] keine Messdaten" "$T/r2.txt"'
"$T/ext5v_mock" 20 30 "$T/int.csv" 2>/dev/null & P=$!
sleep 1; kill -INT "$P"; wait "$P" || true
e2e "SIGINT -> Daten bis dahin gesichert" '[ -s "$T/int.csv" ] && n=$(grep -c "^[0-9]" "$T/int.csv") && [ "$n" -ge 10 ] && [ "$n" -le 30 ] && [ ! -e "$T/int.csv.tmp" ]'
e2e "ungueltige Parameter -> Exit 2" '"$T/ext5v_mock" 500 1 "$T/x.csv" 2>/dev/null; [ $? -eq 2 ] && EXT5V_SCHED=foo "$T/ext5v_mock" 10 1 "$T/x.csv" 2>/dev/null; [ $? -eq 2 ]'
e2e "EXT5V_SCHED=other -> nice 19 wirksam" 'EXT5V_SCHED=other "$T/ext5v_mock" 20 1 "$T/o.csv" && grep -q "sched_req=other idle=0 nice19=1" "$T/o.csv"'
e2e "Referenzlauf HZ=0 erkannt" 'R0=$(EXT5V_OUT="$T" bash "$D/ext5v_run.sh" 0 1 base) && python3 "$D/ext5v_stats.py" "$R0" | grep -q "Referenzlauf ohne Logger"'
[ "$E2E_FAIL" -eq 0 ] || { echo "E2E-TEST: FEHLER"; exit 1; }
echo "E2E-TEST: OK"
sha256sum "$D/ext5v_log.c" "$D/ext5v_run.sh" "$D/ext5v_stats.py" "$D/ext5v_log"
echo "--- Probe (nur auf dem Pi sinnvoll; Exit 0 nur bei 20/20 gueltigen Lesungen):"
"$D/ext5v_log" --probe || echo "Probe fehlgeschlagen (kein /dev/vcio?)"
echo "installiert in $D"
