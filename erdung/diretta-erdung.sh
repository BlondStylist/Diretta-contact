#!/usr/bin/env bash
# diretta-erdung.sh v1.2 - Blockrandomisierte A/B-Messung Erdungskabel (USB-A -> PE)
# Laeuft auf dem Geraet, dessen Erdungskabel umgesteckt wird (Host ODER Target).
# Erfasst PMIC-Rails (vcgencmd pmic_read_adc), Drosselbits, SoC-Temperatur,
# ALSA-Zustand, Netz-Fehlerzaehler und Kernel-Log-Treffer je Segment.
#
#   sudo ./diretta-erdung.sh lauf  [--dir DIR] [--bloecke 10] [--settle 30] [--dauer 120] [--intervall 0.5] [--seed N]
#   sudo ./diretta-erdung.sh probe [SEKUNDEN]     # ohne Umstecken: Funktion, Aufrufdauer, Wiederholrate
#        ./diretta-erdung.sh selbsttest           # hardwarefrei (Mocks)
#
# Exit: 0 ok, 1 Bedienung, 2 Plattform, 3 Lock/Schreiben/Messung, 4 Abbruch/kein TTY, 5 Laufverzeichnis inkonsistent
# Grenze: PMIC misst gegen PLATINENMASSE; Gleichtakt (Masse gegen Erde) ist unsichtbar.
# Sichtbar waere nur DC-Erdstrom (Abfall auf USB-C-Masse) -> vorher Strom im Erdungskabel messen.
export LC_ALL=C
set -uo pipefail
VERSION=1.2
SELF=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null) || SELF=${BASH_SOURCE[0]}
OUT_BASE=${OUT_BASE:-/root/config-archiv/erdung}
HK_CPUS=${HK_CPUS:-0,1}
LOCK=${ERD_LOCK:-/run/lock/diretta-erdung.lock}
VCG=${VCGENCMD:-vcgencmd}
VCG_TMO=${ERD_VCG_TIMEOUT:-5}   # s; haengt die Firmware-Mailbox, zaehlt die Probe als Fehlprobe
MAX_FEHLEINGABEN=5
JCTL=${ERD_JOURNALCTL:-journalctl}
ASOUND=${ERD_ASOUND:-/proc/asound}
THERM=${ERD_THERM:-/sys/class/thermal/thermal_zone0/temp}
TTYDEV=${ERD_TTY:-/dev/tty}
KLOG_RE='xhci|usb [0-9-]+:.*(reset|disconnect|error|fail)|over-current|macb|under-voltage|voltage|snd_usb|urb'
COLS=(EXT5V_V VDD_CORE_V 3V3_SYS_V 1V8_SYS_V 1V1_SYS_V 0V8_SW_V DDR_VDD2_V DDR_VDDQ_V
      3V3_DAC_V 3V3_ADC_V 0V8_AON_V HDMI_V 3V7_WL_SW_V
      VDD_CORE_A 3V3_SYS_A 1V8_SYS_A 1V1_SYS_A 0V8_SW_A DDR_VDD2_A DDR_VDDQ_A
      3V3_DAC_A 3V3_ADC_A 0V8_AON_A HDMI_A 3V7_WL_SW_A)
RUN_DIR=""
PROBE_DIR=""

die(){ printf 'FEHLER: %s\n' "$1" >&2; exit "${2:-1}"; }
inf(){ printf '%s\n' "$*"; }
is_uint(){ [[ ${1:-} =~ ^[0-9]{1,9}$ ]]; }
digits_us(){ local t=${1//[!0-9]/}; [ -n "$t" ] || return 1; printf '%s' "$((10#$t))"; }
now_us(){ digits_us "$EPOCHREALTIME"; }
mono_us(){
  local u r s f=0
  read -r u r </proc/uptime || return 1
  s=${u%%.*}; [[ $u == *.* ]] && f=${u#*.}
  f="${f}000000"; printf '%s' "$(( 10#$s*1000000 + 10#${f:0:6} ))"
}
dec_to_us(){
  [[ ${1:-} =~ ^([0-9]{1,4})(\.([0-9]{1,6}))?$ ]] || return 1
  local f="${BASH_REMATCH[3]}000000"
  printf '%s' "$(( 10#${BASH_REMATCH[1]}*1000000 + 10#${f:0:6} ))"
}
us_fmt(){ printf '%d.%06d' "$(( $1/1000000 ))" "$(( $1%1000000 ))"; }
meta_get(){ sed -n "/^$1=/{s///p;q}" "$2"; }

vcg(){
  if [ -n "$VCG_TMO" ] && command -v timeout >/dev/null; then timeout -k 1 "$VCG_TMO" "$VCG" "$@"
  else "$VCG" "$@"; fi
}

pin_self(){
  [ -n "${_ERD_PINNED:-}" ] && return 0
  export _ERD_PINNED=1
  local -a pre=(taskset -c "$HK_CPUS")
  command -v chrt >/dev/null && pre+=(chrt -o 0)
  pre+=(nice -n 19)
  if command -v taskset >/dev/null && "${pre[@]}" true 2>/dev/null; then
    exec "${pre[@]}" "$BASH" "$SELF" "$@"
  fi
  inf "WARNUNG: Kern-/Prioritaetsbindung nicht moeglich - laeuft ungebunden"
}

header(){ local h="t_us,dur_us,throttled,temp_mC,play" c; for c in "${COLS[@]}"; do h+=",$c"; done; printf '%s\n' "$h"; }

sample(){
  local t0 t1 pm th tp=NA play=0 f st name rest out c
  local re='^(volt|current)\([0-9]+\)=(-?[0-9]+(\.[0-9]+)?)[VA]$'
  local -A V=()
  t0=$(now_us)
  pm=$(vcg pmic_read_adc 2>/dev/null) || return 1
  t1=$(now_us)
  while read -r name rest; do
    [[ $rest =~ $re ]] || continue
    V[$name]=${BASH_REMATCH[2]}
  done <<<"$pm"
  [ -n "${V[EXT5V_V]:-}" ] || return 1
  th=$(vcg get_throttled 2>/dev/null) || th=NA
  th=${th#throttled=}; [[ $th =~ ^0x[0-9a-fA-F]+$ ]] || th=NA
  if [ -r "$THERM" ]; then read -r tp <"$THERM" || tp=NA; fi
  [[ $tp =~ ^-?[0-9]+$ ]] || tp=NA
  for f in "$ASOUND"/card*/pcm*p/sub*/status; do
    [ -r "$f" ] || continue
    st=""; read -r st <"$f" || [ -n "$st" ] || continue
    [[ $st == "state: RUNNING" ]] && play=1
  done
  out="$t0,$((t1-t0)),$th,$tp,$play"
  for c in "${COLS[@]}"; do out+=",${V[$c]:-NA}"; done
  printf '%s\n' "$out"
}

thr_get(){ local x; x=$(vcg get_throttled 2>/dev/null) || { printf NA; return 0; }
  x=${x#throttled=}; if [[ $x =~ ^0x[0-9a-fA-F]+$ ]]; then printf '%s' "$x"; else printf NA; fi; }

net_err(){
  local s=0 k=0 d v x
  for d in /sys/class/net/*; do
    [ "${d##*/}" = lo ] && continue
    for x in rx_errors rx_dropped tx_errors tx_dropped; do
      if [ -r "$d/statistics/$x" ] && read -r v <"$d/statistics/$x" && [[ $v =~ ^[0-9]+$ ]]; then
        s=$((s+10#$v)); k=$((k+1)); fi
    done
  done; printf '%s %s' "$s" "$k"
}

klog_hits(){
  command -v "$JCTL" >/dev/null || { printf NA; return 0; }
  local out
  out=$("$JCTL" -k -q --no-pager -o cat --since "@$1" --until "@$2" 2>/dev/null) || { printf NA; return 0; }
  [ -n "$out" ] || { printf 0; return 0; }
  printf '%s' "$(grep -ciE -- "$KLOG_RE" <<<"$out" || true)"
}

gen_plan(){
  local bl=$1 S=$(( $2 % 2147483648 )) i j t k
  local -a a=()
  k=$((bl/2))
  S=$(( (S*1103515245 + 12345) % 2147483648 ))
  (( bl%2 && (S>>16)%2 )) && k=$((k+1))
  for ((i=0; i<bl; i++)); do a[i]=$(( i<k ? 1 : 0 )); done
  for ((i=bl-1; i>0; i--)); do
    S=$(( (S*1103515245 + 12345) % 2147483648 ))
    j=$(( (S>>16) % (i+1) )); t=${a[i]}; a[i]=${a[j]}; a[j]=$t
  done
  echo "block,pos,cond"
  for ((i=0; i<bl; i++)); do
    if (( a[i] )); then printf '%d,1,MIT\n%d,2,OHNE\n' $((i+1)) $((i+1))
    else printf '%d,1,OHNE\n%d,2,MIT\n' $((i+1)) $((i+1)); fi
  done
}

measure(){
  local dir=$1 id=$2 dur=$3 iv=$4 part="$1/seg_$2.part" n=0 fails=0 late=0
  local iv_us t0 m0 mend next now line
  iv_us=$(dec_to_us "$iv") || return 1
  header >"$part" || return 1
  t0=$(now_us); m0=$(mono_us) || return 1
  mend=$((m0 + dur*1000000)); next=$m0
  while :; do
    now=$(mono_us); [ "$now" -ge "$mend" ] && break
    if line=$(sample); then printf '%s\n' "$line" >>"$part" || return 1; n=$((n+1)); else fails=$((fails+1)); fi
    next=$((next + iv_us)); now=$(mono_us)
    if [ "$next" -gt "$now" ]; then sleep "$(us_fmt $((next-now)))"
    else late=$((late+1)); next=$now; fi
  done
  printf '%s %s %s %s %s\n' "$t0" "$(now_us)" "$n" "$fails" "$late"
}

ask(){
  local a
  { : <"$TTYDEV"; } 2>/dev/null || return 1
  read -r -p "$1" a <"$TTYDEV" || return 1
  printf '%s' "$a"
}

on_sig(){ trap - INT TERM HUP; inf ""; inf "Unterbrochen. Fortsetzen mit: $SELF lauf --dir ${RUN_DIR:-?}"; exit "$1"; }

cmd_lauf(){
  local dir="" bl=10 st=30 du=120 iv=0.5 seed="" a extra=0 host meta planf sha iv_us
  while [ $# -gt 0 ]; do
    case $1 in
      --dir|--bloecke|--settle|--dauer|--intervall|--seed) [ $# -ge 2 ] || die "Wert fehlt fuer $1";;
      *) die "unbekannte Option $1";;
    esac
    case $1 in
      --dir) dir=$2;; --bloecke) bl=$2; extra=1;; --settle) st=$2; extra=1;;
      --dauer) du=$2; extra=1;; --intervall) iv=$2; extra=1;; --seed) seed=$2; extra=1;;
    esac
    shift 2
  done
  host=$(uname -n 2>/dev/null); [ -n "$host" ] || host=$(cat /proc/sys/kernel/hostname 2>/dev/null)
  host=${host:-pi}; host=${host//[^A-Za-z0-9._-]/_}
  [ -n "$dir" ] || dir="$OUT_BASE/$host-$(date +%Y%m%d-%H%M)"
  RUN_DIR=$dir
  mkdir -p "$dir" || die "kann $dir nicht anlegen" 3
  meta="$dir/run.meta"; planf="$dir/plan.csv"
  [ -f "$planf" ] && [ ! -f "$meta" ] && die "plan.csv ohne run.meta in $dir - inkonsistent" 5
  if [ ! -f "$meta" ]; then
    for a in "$bl" "$st" "$du"; do is_uint "$a" || die "Ganzzahl erwartet: $a"; done
    bl=$((10#$bl)); st=$((10#$st)); du=$((10#$du))
    iv_us=$(dec_to_us "$iv") || die "Intervall ungueltig (Punkt verwenden, z. B. 0.5): $iv"
    [ "$bl" -ge 2 ] && [ "$bl" -le 200 ] || die "Bloecke: 2..200"
    [ "$du" -ge 1 ] || die "Dauer >= 1 s"
    [ "$iv_us" -ge 100000 ] && [ "$iv_us" -le 60000000 ] || die "Intervall: 0.1..60 s"
    if [ -n "$seed" ]; then is_uint "$seed" || die "Seed: Ganzzahl"; seed=$((10#$seed))
    else seed=$(( $(now_us) % 1000000000 )); fi
    if [ -n "${ERD_NONINTERACTIVE:-}" ]; then a=${ERD_ANDERES:-NA}
    else a=$(ask "Erdungskabel am ANDEREN Geraet gesteckt? [j/n]: ") || die "kein Terminal fuer Eingabe" 4; fi
    [[ $a =~ ^(j|n|NA)$ ]] || a="?"
    sha=$(sha256sum "$SELF" 2>/dev/null | cut -c1-16); sha=${sha:-NA}
    { echo "geraet=$host"; echo "version=$VERSION"; echo "sha=$sha"; echo "kernel=$(uname -r)"
      echo "seed=$seed"; echo "bloecke=$bl"; echo "settle_s=$st"; echo "dauer_s=$du"
      echo "intervall_s=$iv"; echo "anderes_geraet_kabel=$a"; echo "start=$(date -Is)"; } >"$meta.tmp" \
      && mv "$meta.tmp" "$meta" || die "run.meta nicht schreibbar" 3
    inf "Neuer Lauf: $dir (Seed $seed)"
  else
    [ "$extra" -eq 0 ] || inf "HINWEIS: Fortsetzung - Optionen ausser --dir werden ignoriert (Werte aus run.meta)."
    bl=$(meta_get bloecke "$meta"); st=$(meta_get settle_s "$meta"); du=$(meta_get dauer_s "$meta")
    iv=$(meta_get intervall_s "$meta"); seed=$(meta_get seed "$meta")
    for a in "$bl" "$st" "$du" "$seed"; do is_uint "$a" || die "run.meta beschaedigt/manipuliert: '$a'" 5; done
    dec_to_us "$iv" >/dev/null || die "run.meta: intervall_s ungueltig" 5
    bl=$((10#$bl)); st=$((10#$st)); du=$((10#$du)); seed=$((10#$seed))
    inf "Fortsetzung: $dir"
  fi
  if [ ! -f "$planf" ]; then
    gen_plan "$bl" "$seed" >"$planf.tmp" && mv "$planf.tmp" "$planf" || die "plan.csv nicht schreibbar" 3
  fi
  [ -n "${TMUX:-}${STY:-}" ] || inf "HINWEIS: nicht in tmux/screen - bei SSH-Abbruch mit --dir $dir fortsetzen."
  trap 'on_sig 130' INT; trap 'on_sig 143' TERM; trap 'on_sig 129' HUP
  local b p c id want got tries r t0 t1 n f late s0 e0 ks km nd th0 th1 x0 k0 x1 k1
  while IFS=, read -r b p c <&3; do
    [ "$b" = block ] && continue
    [[ $b =~ ^[0-9]{1,4}$ && $p =~ ^[12]$ && $c =~ ^(MIT|OHNE)$ ]] || die "plan.csv: ungueltige Zeile '$b,$p,$c'" 5
    id="b${b}_${c}"
    [ -f "$dir/seg_$id.done" ] && continue
    rm -f "$dir/seg_$id.part"
    if [ "$c" = MIT ]; then want=m; else want=o; fi
    inf ""; inf ">>> Block $b/$bl, Segment $p: Bedingung $c ($host)"
    inf "    Lautstaerke auf 0. Kabel $( [ "$c" = MIT ] && echo EINSTECKEN || echo ABZIEHEN ). Danach Geraet NICHT beruehren."
    if [ -n "${ERD_NONINTERACTIVE:-}" ]; then got=$want; else
      tries=0
      while :; do
        got=$(ask "    Ist-Zustand bestaetigen [m=mit / o=ohne / q=abbruch]: ") \
          || { inf "Keine Eingabe moeglich (kein TTY/EOF). Fortsetzen mit: lauf --dir $dir"; exit 4; }
        [ "$got" = q ] && { inf "Abbruch - fortsetzen mit: lauf --dir $dir"; exit 4; }
        [ "$got" = "$want" ] && break
        tries=$((tries+1))
        [ "$tries" -lt "$MAX_FEHLEINGABEN" ] || { inf "$MAX_FEHLEINGABEN Fehleingaben - Abbruch. Fortsetzen mit: lauf --dir $dir"; exit 4; }
        inf "    Erwartet '$want'."
      done
    fi
    s0=$EPOCHSECONDS; read -r x0 k0 <<<"$(net_err)"; th0=$(thr_get)
    inf "    Beruhigung ${st}s ..."; sleep "$st"
    e0=$EPOCHSECONDS; ks=$(klog_hits "$s0" "$e0")
    inf "    Messung ${du}s ..."
    r=$(measure "$dir" "$id" "$du" "$iv") || die "Messung $id fehlgeschlagen (Schreibfehler?)" 3
    read -r t0 t1 n f late <<<"$r"
    read -r x1 k1 <<<"$(net_err)"; th1=$(thr_get)
    km=$(klog_hits "$e0" "$((EPOCHSECONDS+1))")
    nd=NA; [ "$k0" = "$k1" ] && [ "$x1" -ge "$x0" ] && nd=$((x1-x0))
    { echo "block=$b"; echo "pos=$p"; echo "cond=$c"; echo "t0_us=$t0"; echo "t1_us=$t1"
      echo "n=$n"; echo "fehlproben=$f"; echo "verspaetet=$late"; echo "klog_settle=$ks"; echo "klog_mess=$km"
      echo "neterr_delta=$nd"; echo "throttled_vor=$th0"; echo "throttled_nach=$th1"; } >"$dir/seg_$id.meta.tmp" \
      && mv "$dir/seg_$id.meta.tmp" "$dir/seg_$id.meta" || die "Segment-Meta $id nicht schreibbar" 3
    mv "$dir/seg_$id.part" "$dir/seg_$id.csv" && sync && touch "$dir/seg_$id.done" || die "Sichern von $id fehlgeschlagen" 3
    inf "    gesichert: seg_$id.csv (n=$n, Fehlproben=$f, verspaetet=$late, KLog B/M=$ks/$km)"
    [ "$n" -ge 3 ] || inf "    WARNUNG: <3 gueltige Proben - Segment wird bei der Auswertung ausgeschlossen."
  done 3<"$planf"
  trap - INT TERM HUP
  grep -q '^ende=' "$meta" || echo "ende=$(date -Is)" >>"$meta"
  inf ""; inf "FERTIG. Auswertung: python3 erdung-auswertung.py $dir"
}

cmd_probe(){
  local d=${1:-20} dir r j=NA
  is_uint "$d" && [ "$((10#$d))" -ge 2 ] || die "Sekunden als Ganzzahl >= 2"
  command -v python3 >/dev/null || die "python3 fehlt" 2
  dir=$(mktemp -d) || die "mktemp fehlgeschlagen" 3
  PROBE_DIR=$dir; trap 'rm -rf "${PROBE_DIR:-/nonexistent}"' EXIT
  r=$(measure "$dir" probe "$((10#$d))" 0.5) || die "Messung fehlgeschlagen" 3
  inf "Messung (t0 t1 n fehl verspaetet): $r"
  command -v "$JCTL" >/dev/null && j=$("$JCTL" -k -q --no-pager -n 1 -o cat 2>/dev/null | wc -l)
  inf "Kernel-Journal lesbar: $j Zeile(n)  (0/NA: Storage=none o. ae. -> klog-Werte bedeutungslos)"
  python3 - "$dir/seg_probe.part" <<'PY'
import csv, sys, math, statistics as S
from collections import Counter
r = list(csv.DictReader(open(sys.argv[1])))
if len(r) < 3:
    print("ZU WENIG PROBEN:", len(r)); sys.exit(1)
t = [int(x["t_us"]) for x in r]; du = [int(x["dur_us"]) for x in r]
print(f"Proben {len(r)}  dt median {S.median([b-a for a, b in zip(t, t[1:])])/1e6:.3f}s  "
      f"pmic-Aufruf median {S.median(du)/1e3:.0f} ms, max {max(du)/1e3:.0f} ms")
print(f"ALSA RUNNING {sum(x['play'] == '1' for x in r)}/{len(r)}  throttled {sorted({x['throttled'] for x in r})}")
wd5 = None
for c in ("EXT5V_V", "HDMI_V", "VDD_CORE_V", "3V3_SYS_V", "1V8_SYS_V", "VDD_CORE_A"):
    v = [float(x[c]) for x in r if x.get(c) not in (None, "", "NA")]
    if len(v) < 3:
        print(f"{c:11} NA"); continue
    u = sorted(set(round(a, 9) for a in v))
    g = Counter(round(b - a, 9) for a, b in zip(u, u[1:]))
    st = min((k for k, n in g.items() if n == max(g.values())), default=0.0)
    wd = sum(a == b for a, b in zip(v, v[1:])) / (len(v) - 1)
    d = [b - a for a, b in zip(v, v[1:])]
    if c == "EXT5V_V":
        wd5 = wd
    print(f"{c:11} mittel {sum(v)/len(v):.5f}  sd {S.pstdev(v)*1e3:.2f} m  rauschen {S.pstdev(d)/math.sqrt(2)*1e3:.2f} m  "
          f"schritt {st*1e3:.3g} m  eindeutig {len(u)}  wdh {wd*100:.0f}%")
if wd5 is not None and wd5 > .5:
    print("HINWEIS: >50% identische Folgewerte (Cache/Quantisierung): Proben nicht unabhaengig -> Intervall 1.0 waehlen.")
PY
}

# shellcheck disable=SC2016,SC2034  # chk-Ausdruecke werden bewusst per eval ausgewertet
cmd_selbsttest(){
  local tmp ok=0 bad=0 out rc; tmp=$(mktemp -d) || return 1
  mkdir -p "$tmp/bin" "$tmp/snd/card0/pcm0p/sub0" "$tmp/snd/card1/pcm0p/sub0"
  cat >"$tmp/bin/vcgencmd" <<'M'
#!/usr/bin/env bash
case ${MOCK_MODE:-ok}:$1 in
 fail:*) exit 1;;
 err:*) echo 'error=1 error_msg="Command not registered"'; exit 0;;
 ok:pmic_read_adc) awk -v s="$RANDOM" 'BEGIN{srand(s); printf "  VDD_CORE_A current(7)=%.8fA\n     EXT5V_V volt(24)=%.8fV\n  VDD_CORE_V volt(15)=%.8fV\n   3V3_SYS_V volt(9)=3.31467300V\n      BATT_V volt(25)=0.00000000V\n",0.9+rand()*0.05,5.05+rand()*0.004,0.72+rand()*0.002}';;
 ok:get_throttled) echo throttled=0x0;;
 hang:*) exec sleep 30;;
esac
M
  cat >"$tmp/bin/journalctl" <<'M'
#!/usr/bin/env bash
case ${MOCK_J:-leer} in
 fail) exit 1;;
 leer) exit 0;;
 zwei) printf 'xhci-hcd: reset\nirgendwas\nusb 1-1: USB disconnect, device number 3\n';;
esac
M
  chmod +x "$tmp/bin/vcgencmd" "$tmp/bin/journalctl"
  echo "state: RUNNING" >"$tmp/snd/card0/pcm0p/sub0/status"
  echo "closed" >"$tmp/snd/card1/pcm0p/sub0/status"
  echo 48123 >"$tmp/temp"
  chk(){ if eval "$2"; then ok=$((ok+1)); else bad=$((bad+1)); inf "  FAIL: $1"; fi; }
  local VCG="$tmp/bin/vcgencmd" JCTL="$tmp/bin/journalctl" ASOUND="$tmp/snd" THERM="$tmp/temp" TTYDEV="$tmp/kein-tty"
  out=$(sample)
  chk "T01 Probe hat $(( ${#COLS[@]}+5 )) Felder" '[ "$(awk -F, "{print NF}" <<<"$out")" -eq $(( ${#COLS[@]}+5 )) ]'
  chk "T02 Komma-Zeitstempel" '[ "$(digits_us 1629376497,853634)" = 1629376497853634 ]'
  chk "T03 Punkt-Zeitstempel" '[ "$(digits_us 1629376497.000042)" = 1629376497000042 ]'
  chk "T04 now_us 16 Ziffern" '[[ $(now_us) =~ ^[0-9]{16}$ ]]'
  chk "T05 EXT5V geparst" '[[ $(cut -d, -f6 <<<"$out") =~ ^5\.0[0-9]+$ ]]'
  chk "T06 fehlende Rail = NA" '[ "$(cut -d, -f9 <<<"$out")" = NA ]'
  chk "T07 3V3_SYS exakt" '[ "$(cut -d, -f8 <<<"$out")" = 3.31467300 ]'
  chk "T08 throttled ohne Praefix" '[ "$(cut -d, -f3 <<<"$out")" = 0x0 ]'
  chk "T09 dur_us ganzzahlig" '[[ $(cut -d, -f2 <<<"$out") =~ ^[0-9]+$ ]]'
  chk "T10 Intervall 0.5 ok, 0,5 abgelehnt" '[ "$(dec_to_us 0.5)" = 500000 ] && ! dec_to_us 0,5 >/dev/null'
  chk "T11 fuehrende Null" '[ "$(dec_to_us 08)" = 8000000 ] && is_uint 08 && [ $((10#08)) -eq 8 ]'
  chk "T12 Sleep-Format ohne awk" '[ "$(us_fmt 1500)" = 0.001500 ] && [ "$(us_fmt 2500000)" = 2.500000 ]'
  chk "T13 Fehlertext mit Exit 0 = Fehlprobe" '! MOCK_MODE=err sample >/dev/null'
  chk "T14 vcgencmd Exit 1 = Fehlprobe" '! MOCK_MODE=fail sample >/dev/null'
  chk "T15 Wiedergabe RUNNING/closed" '[ "$(cut -d, -f5 <<<"$out")" = 1 ] && [ "$(ASOUND=$tmp/leer sample | cut -d, -f5)" = 0 ]'
  chk "T16 Temperatur / NA bei Muell" 'echo abc >"$tmp/t2"; [ "$(THERM=$tmp/t2 sample | cut -d, -f4)" = NA ] && [ "$(cut -d, -f4 <<<"$out")" = 48123 ]'
  chk "T17 Plan balanciert" '[ "$(gen_plan 10 7 | grep -c ",1,MIT")" -eq 5 ] && [ "$(gen_plan 3 1 | wc -l)" -eq 7 ]'
  chk "T18 Plan reproduzierbar, Seed wirkt" '[ "$(gen_plan 10 7)" = "$(gen_plan 10 7)" ] && [ "$(for s in 1 2 3 4 5 6; do gen_plan 10 $s | md5sum; done | sort -u | wc -l)" -gt 1 ]'
  chk "T19 journalctl-Fehler = NA" '[ "$(MOCK_J=fail klog_hits 1 2)" = NA ]'
  chk "T20 0 Treffer = 0" '[ "$(MOCK_J=leer klog_hits 1 2)" = 0 ]'
  chk "T21 2 Treffer" '[ "$(MOCK_J=zwei klog_hits 1 2)" = 2 ]'
  chk "T22 journalctl fehlt = NA" '[ "$(JCTL=$tmp/nix klog_hits 1 2)" = NA ]'
  ( OUT_BASE=$tmp/o cmd_lauf --dir "$tmp/r0" --bloecke 2 --settle 0 --dauer 1 --intervall 0.2 --seed 1 ) </dev/null >"$tmp/log0" 2>&1; rc=$?
  printf 'j\n' >"$tmp/fake-tty"
  ( TTYDEV=$tmp/fake-tty cmd_lauf --dir "$tmp/r1" --bloecke 2 --settle 0 --dauer 1 --intervall 0.2 --seed 1 ) </dev/null >"$tmp/log1" 2>&1
  chk "T23 kein TTY / falsche Eingaben -> Exit 4" '[ "$rc" -eq 4 ] && grep -q "$MAX_FEHLEINGABEN Fehleingaben" "$tmp/log1" && [ "$(grep -c "Erwartet" "$tmp/log1")" -eq $((MAX_FEHLEINGABEN-1)) ]'
  chk "T24 die: Meldung ohne Code, Exit-Code" '[ "$( (die "x y" 2) 2>&1 )" = "FEHLER: x y" ] && { (die z 2) 2>/dev/null; [ $? -eq 2 ]; }'
  chk "T25 SELF absolut und lesbar" '[[ $SELF == /* ]] && [ -r "$SELF" ]'
  ( ERD_NONINTERACTIVE=1 ERD_ANDERES=n cmd_lauf --dir "$tmp/r" --bloecke 2 --settle 0 --dauer 2 --intervall 0.2 --seed 7 ) </dev/null >"$tmp/log" 2>&1
  chk "T26 4 Segmente fertig" '[ "$(ls "$tmp"/r/*.done 2>/dev/null | wc -l)" -eq 4 ]'
  chk "T27 keine .part/.tmp-Reste" '! compgen -G "$tmp/r/*.part" >/dev/null && ! compgen -G "$tmp/r/*.tmp" >/dev/null'
  chk "T28 Plan je Block MIT+OHNE" '[ "$(grep -c MIT "$tmp/r/plan.csv")" -eq 2 ] && [ "$(grep -c OHNE "$tmp/r/plan.csv")" -eq 2 ]'
  chk "T29 Proben je Segment >=5" '[ "$(meta_get n "$tmp/r/seg_b1_MIT.meta")" -ge 5 ]'
  chk "T30 Segment-Meta vollstaendig" 'grep -q "^verspaetet=[0-9]" "$tmp/r/seg_b1_MIT.meta" && grep -q "^klog_mess=0$" "$tmp/r/seg_b1_MIT.meta" && grep -q "^neterr_delta=" "$tmp/r/seg_b1_MIT.meta"'
  rm -f "$tmp/r/seg_b2_OHNE.done"; touch "$tmp/r/seg_b2_OHNE.part"
  ( ERD_NONINTERACTIVE=1 cmd_lauf --dir "$tmp/r" ) </dev/null >"$tmp/log2" 2>&1
  chk "T31 Fortsetzung misst nur Fehlendes" '[ "$(grep -c ">>> Block" "$tmp/log2")" -eq 1 ] && [ -f "$tmp/r/seg_b2_OHNE.done" ] && [ ! -e "$tmp/r/seg_b2_OHNE.part" ]'
  rm -f "$tmp/r/seg_b1_MIT.done"
  ( ERD_NONINTERACTIVE=1 cmd_lauf --dir "$tmp/r" --dauer 99 ) </dev/null >"$tmp/log3" 2>&1
  chk "T32 neue Optionen sichtbar ignoriert" 'grep -q "ignoriert" "$tmp/log3" && grep -q "Messung 2s" "$tmp/log3"'
  cp "$tmp/r/plan.csv" "$tmp/plan.ref"; rm -f "$tmp/r/plan.csv"
  ( ERD_NONINTERACTIVE=1 cmd_lauf --dir "$tmp/r" ) </dev/null >"$tmp/log4" 2>&1
  chk "T33 plan.csv aus Seed rekonstruiert" 'cmp -s "$tmp/plan.ref" "$tmp/r/plan.csv"'
  mkdir -p "$tmp/r2"
  printf 'seed=1\nbloecke=2\nsettle_s=0\ndauer_s=x[$(touch %s/PWNED)]\nintervall_s=0.2\n' "$tmp" >"$tmp/r2/run.meta"
  ( ERD_NONINTERACTIVE=1 cmd_lauf --dir "$tmp/r2" ) </dev/null >/dev/null 2>&1; rc=$?
  chk "T34 manipulierte run.meta abgewiesen" '[ "$rc" -eq 5 ] && [ ! -e "$tmp/PWNED" ]'
  mkdir -p "$tmp/r3"; echo "block,pos,cond" >"$tmp/r3/plan.csv"
  ( ERD_NONINTERACTIVE=1 cmd_lauf --dir "$tmp/r3" ) </dev/null >/dev/null 2>&1; rc=$?
  chk "T35 plan.csv ohne run.meta -> Exit 5" '[ "$rc" -eq 5 ]'
  local t_a=$SECONDS
  chk "T36 haengendes vcgencmd -> Fehlprobe nach Timeout" '! VCG_TMO=1 MOCK_MODE=hang sample >/dev/null && [ $((SECONDS-t_a)) -le 4 ]'
  chk "T37 Bash >= 5 (EPOCHREALTIME vorhanden)" '[ "${BASH_VERSINFO[0]}" -ge 5 ] && [ -n "${EPOCHREALTIME:-}" ]'
  rm -rf "$tmp"; inf "Selbsttest: $ok ok, $bad Fehler"; [ "$bad" -eq 0 ]
}

main(){
  [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] && [ -n "${EPOCHREALTIME:-}" ] || die "Bash >= 5.0 erforderlich (EPOCHREALTIME)" 2
  [[ $VCG_TMO =~ ^([1-9][0-9]{0,2})?$ ]] || die "ERD_VCG_TIMEOUT: 1..999 s oder leer"
  case ${1:-} in
    lauf|probe)
      [ "$(id -u)" -eq 0 ] || die "als root starten (sudo)"
      command -v "$VCG" >/dev/null || die "vcgencmd fehlt" 2
      command -v flock >/dev/null || die "flock fehlt (util-linux)" 2
      local o sub; o=$(vcg pmic_read_adc 2>/dev/null) || true
      [[ $o == *EXT5V_V* ]] || die "pmic_read_adc nicht verfuegbar (kein Pi 5?)" 2
      pin_self "$@"
      mkdir -p "${LOCK%/*}" 2>/dev/null
      exec 9>"$LOCK" || die "Lock-Datei nicht anlegbar: $LOCK" 3
      flock -n 9 || die "laeuft bereits" 3
      sub=$1; shift; "cmd_$sub" "$@";;
    selbsttest) cmd_selbsttest;;
    *) sed -n '2,14p' "$SELF"; exit 1;;
  esac
}
main "$@"
