#!/usr/bin/env bash
# image-snapshot.sh - liest ein AudioLinux-Image NUR LESEND und erzeugt ein Archiv im Format von snapshot.sh.
# Damit laesst sich der Zustand eines Pi (snapshot.sh) mit dem ORIGINAL-Image vergleichen (compare.sh) und
# gezielt aus dem Original zuruecksetzen (restore.sh).
#
#   sudo bash image-snapshot.sh --suche                       sucht Images (WSL-Home, Downloads/Desktop unter /mnt/c/Users/*)
#   sudo bash image-snapshot.sh BILD.img[.gz|.xz|.zip] [label]   Image einlesen (Root noetig: Loop-Mount, nur lesend)
#   bash image-snapshot.sh --wurzel DIR [--boot DIR] [label]  statt eines Images ein entpacktes Verzeichnis (ohne Root; Tests)
# Optionen: --cache DIR (Ablage fuer das entpackte Image, Standard ~/.cache/diretta-images), --behalten (entpacktes Image nicht loeschen)
# Env: OUT_BASE (Standard ~/snapshots), SUCHPFADE (durch : getrennt), MIN_KB (Mindestgroesse bei --suche, Standard 200000),
#      MIN_FREI_GB (freier Platz fuer das Entpacken, Standard 10)
# Das Image wird in einem eigenen Mount-Namespace eingehaengt (ro,noload): es wird nie veraendert, nach dem Lauf ist nichts gemountet.
# Exit: 0 ok | 1 Fehler | 2 Aufruf/Werkzeug fehlt
set -uo pipefail
export LC_ALL=C LANG=C

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BENUTZER="${SUDO_USER:-${USER:-root}}"
BHOME="$(getent passwd "$BENUTZER" 2>/dev/null | cut -d: -f6)"; BHOME="${BHOME:-$HOME}"
OUT_BASE="${OUT_BASE:-$BHOME/snapshots}"
CACHE="$BHOME/.cache/diretta-images"
BEHALTEN=0

suche() {
  local d dirs=() f gefunden=0
  if [ -n "${SUCHPFADE:-}" ]; then IFS=: read -r -a dirs <<<"$SUCHPFADE"
  else for d in "$BHOME" "$BHOME/Downloads" /mnt/c/Users/*/Downloads /mnt/c/Users/*/Desktop /mnt/c/Users/*/Documents /mnt/d /mnt/e; do [ -d "$d" ] && dirs+=("$d"); done; fi
  echo "Suche Images (>= ${MIN_KB:-200000} kB) in: ${dirs[*]}"
  while IFS= read -r -d '' f; do
    gefunden=$((gefunden + 1))
    printf '%2d) %6d MB  %s  %s\n' "$gefunden" "$(( $(stat -c %s "$f") / 1048576 ))" "$(date -r "$f" +%F)" "$f"
  done < <(find "${dirs[@]}" -maxdepth 4 -type f \( -iname '*.img' -o -iname '*.img.gz' -o -iname '*.img.xz' -o -iname '*.img.zip' -o -iname '*audiolinux*.zip' -o -iname '*audiolinux*.gz' -o -iname '*audiolinux*.xz' \) \
            -size +"${MIN_KB:-200000}"k -print0 2>/dev/null | sort -z)
  (( gefunden > 0 )) || { echo "Keine Images gefunden. Pfad direkt angeben oder SUCHPFADE=/pfad1:/pfad2 setzen."; return 1; }
  echo "Aufruf: sudo bash $0 PFAD host-original   (und danach fuer das zweite Image: ... target-original)"
}

entpacken() {  # entpacken IMAGE -> gibt Pfad der rohen .img-Datei aus
  local img="$1" base roh
  case "$img" in
    *.img) echo "$img"; return 0;;
  esac
  mkdir -p "$CACHE" || return 1
  base="$(basename "$img")"; base="${base%.gz}"; base="${base%.xz}"; base="${base%.zip}"; base="${base%.img}"
  roh="$CACHE/$base.img"
  local frei; frei="$(df -Pk "$CACHE" | awk 'NR==2{print int($4/1048576)}')"
  (( frei >= ${MIN_FREI_GB:-10} )) || { echo "Zu wenig Platz in $CACHE (${frei} GB frei, mindestens ${MIN_FREI_GB:-10} GB; --cache auf eine groessere Platte setzen)" >&2; return 1; }
  echo "Entpacke nach $roh (kann einige Minuten dauern) ..." >&2
  case "$img" in
    *.gz) gzip -dc -- "$img" >"$roh" || return 1;;
    *.xz) xz -dc -- "$img" >"$roh" || return 1;;
    *.zip) unzip -p -- "$img" '*.img' >"$roh" || return 1;;
    *) echo "Unbekanntes Format: $img" >&2; return 1;;
  esac
  echo "$roh"
}

# ------------------------------------------------------------------ Verzeichnis -> Archiv
wurzel_modus() {  # wurzel_modus WURZEL BOOTDIR LABEL QUELLE
  local R="$1" B="$2" label="$3" quelle="$4" b=/boot ts base name n=1 D sx="" stage ex p f top
  label="${label//[^A-Za-z0-9._-]/_}"
  ts="$(date +%Y%m%d-%H%M%S)"; base="snapshot-image-$label-$ts"; name="$base"
  mkdir -p "$OUT_BASE" || return 1
  while [[ -e "$OUT_BASE/$name" || -e "$OUT_BASE/$name.tar.gz" ]]; do n=$((n + 1)); name="$base-$n"; done
  D="$OUT_BASE/$name"; umask 077; mkdir -p "$D/report" || return 1
  # shellcheck disable=SC2034  # wird vom wortgleich uebernommenen Block benutzt
  local hits
# --- paths-start
paths=(/etc /var/spool/cron /opt/configuration /opt/scripts /opt/diretta-alsa /opt/diretta-alsa-target "$b/cmdline.txt" "$b/config.txt"
  /home/audiolinux/.ssh/config /home/audiolinux/.ssh/authorized_keys /home/audiolinux/.config/systemd /home/audiolinux/.bashrc /home/audiolinux/.bash_profile)
# --- paths-ende
  while IFS= read -r -d '' f; do paths+=("/$f"); done < <(cd "$R" && find home/audiolinux -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.conf' \) -size -200k -not -path '*/.cache/*' -not -path '*/snapshots/*' -print0 2>/dev/null)
  ex=(); for p in "${paths[@]}"; do [[ $p == "$b"/* ]] && continue; [[ -e "$R$p" ]] && ex+=("${p#/}"); done
# --- excl-start
excl=(--exclude='etc/shadow*' --exclude='etc/gshadow*' --exclude='etc/ssh/ssh_host_*' --exclude='etc/ssl/private' --exclude='etc/pacman.d/gnupg'
  --exclude='etc/ca-certificates/extracted' --exclude='etc/ssl/certs' --exclude='etc/ld.so.cache' --exclude='etc/udev/hwdb.bin' --exclude='etc/*-'
  --exclude='*.o' --exclude='.git' --exclude='*.ko' --exclude='*.log')
# --- excl-ende
  stage="$(mktemp -d)"
  if [ "${#ex[@]}" -gt 0 ]; then
    tar -C "$R" -cpf - --ignore-failed-read "${excl[@]}" -- "${ex[@]}" 2>/dev/null | tar -C "$stage" -xpf - 2>/dev/null
  fi
  if [ -n "$B" ] && [ -d "$B" ]; then
    mkdir -p "$stage$b"
    for f in cmdline.txt config.txt; do [ -f "$B/$f" ] && cp -a "$B/$f" "$stage$b/"; done
  fi
  top=(); while IFS= read -r -d '' f; do top+=("$f"); done < <(cd "$stage" && find . -mindepth 1 -maxdepth 1 -printf '%f\0')
  [ "${#top[@]}" -gt 0 ] || { echo "Nichts gefunden: ist $R ein AudioLinux-Wurzelverzeichnis?" >&2; return 1; }
  tar -czpf "$D/files.tar.gz" -C "$stage" -- "${top[@]}" || return 1
  rm -rf -- "$stage"
# --- manifest-start
sx="$(mktemp -d)"; tar -xzf "$D/files.tar.gz" -C "$sx" --no-same-owner 2>/dev/null
hits="$(grep -rIiE 'BEGIN [A-Z ]*PRIVATE KEY|(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+' "$sx" 2>/dev/null | grep -v NOPASSWD | cut -d: -f1 | sort -u | sed "s|^$sx||")"
[[ -n $hits ]] && { echo "$hits" > "$D/WARNUNG-zugangsdaten.txt"; echo "WARNUNG: moegliche Zugangsdaten in Dateien (Archiv privat halten):"; echo "$hits"; }
{ ( cd "$sx" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum )
  ( cd "$sx" && find . -type l -print0 | while IFS= read -r -d '' l; do printf '%s  %s\n' "$(readlink "$l" | sha256sum | cut -c1-64)" "$l"; done )
} | sed -E 's#^([0-9a-f]{64}  )\./#\1/#' | sort -k2 > "$D/manifest.sha256"
rm -rf -- "$sx"; sx=""
# --- manifest-ende
  { echo "Quelle: $quelle"; echo "Erzeugt: $(date -Is) mit image-snapshot.sh"; echo "Nur Dateien (kein Laufzeitbericht): compare.sh vergleicht daher nur Dateien."; } > "$D/QUELLE.txt"
  rmdir "$D/report" 2>/dev/null
  ( cd "$OUT_BASE" && tar -czf "$name.tar.gz" "$name" ) || return 1
  chmod 0600 "$OUT_BASE/$name.tar.gz"; rm -rf -- "$D"
  [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$OUT_BASE" "$OUT_BASE/$name.tar.gz" 2>/dev/null
  echo "Fertig: $OUT_BASE/$name.tar.gz ($(du -h "$OUT_BASE/$name.tar.gz" | cut -f1), $(tar -xzOf "$OUT_BASE/$name.tar.gz" "$name/manifest.sha256" | wc -l) Dateien/Links)"
}

# ------------------------------------------------------------------ Image -> Verzeichnisse einhaengen
bild_modus() {  # bild_modus IMAGE LABEL
  local img="$1" label="$2" roh sf broff="" brsz="" rooff="" rosz="" start size typ ss=512 zeile
  [ -f "$img" ] || { echo "Image nicht gefunden: $img" >&2; return 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Root noetig (Loop-Mount): sudo bash $0 ..." >&2; return 2; }
  for c in sfdisk unshare mount; do command -v "$c" >/dev/null 2>&1 || { echo "Werkzeug fehlt: $c" >&2; return 2; }; done
  roh="$(entpacken "$img")" || return 1
  sf="$(sfdisk -d "$roh" 2>/dev/null)" || { echo "Keine Partitionstabelle in $roh" >&2; return 1; }
  ss="$(awk -F': *' '/^sector-size:/{print $2}' <<<"$sf")"; ss="${ss:-512}"
  while IFS= read -r zeile; do
    [[ $zeile == *start=* ]] || continue
    start="$(sed -E 's/.*start= *([0-9]+),.*/\1/' <<<"$zeile")"; size="$(sed -E 's/.*size= *([0-9]+),.*/\1/' <<<"$zeile")"
    typ="$(sed -E 's/.*type=([0-9A-Fa-f-]+).*/\1/' <<<"$zeile")"
    case "${typ,,}" in
      c|0c|b|e) broff=$((start * ss)); brsz=$((size * ss));;
      83|0fc63daf-8483-4772-8e79-3d69d8477de4) rooff=$((start * ss)); rosz=$((size * ss));;
    esac
  done <<<"$sf"
  [ -n "$rooff" ] || { echo "Keine Linux-Wurzelpartition (Typ 83) gefunden:"; echo "$sf" | tail -5; return 1; } >&2
  echo "Wurzelpartition: Offset $rooff, Groesse $rosz${broff:+; Bootpartition: Offset $broff}"
  # shellcheck disable=SC2016  # der Block laeuft bewusst in der Unter-Shell, dort werden die Variablen aufgeloest
  OUT_BASE="$OUT_BASE" SUDO_USER="${SUDO_USER:-}" ROH="$roh" ROOFF="$rooff" ROSZ="$rosz" BROFF="$broff" BRSZ="$brsz" LABEL="$label" QUELLE="$img" SELF="$SELF" \
  unshare -m --propagation private bash -c '
    set -e
    M="$(mktemp -d)"; mkdir -p "$M/root" "$M/boot"
    mount -t ext4 -o ro,noload,loop,offset="$ROOFF",sizelimit="$ROSZ" "$ROH" "$M/root"
    B=""
    if [ -n "$BROFF" ]; then
      if mount -o ro,loop,offset="$BROFF",sizelimit="$BRSZ" "$ROH" "$M/boot"; then B="$M/boot"
      else echo "WARNUNG: Bootpartition nicht einhaengbar (vfat-Unterstuetzung?): /boot/cmdline.txt und config.txt fehlen im Archiv" >&2; fi
    fi
    set +e
    bash "$SELF" --wurzel "$M/root" ${B:+--boot "$B"} --quelle "$QUELLE" "$LABEL"
    rc=$?
    exit $rc
  '
  local rc=$?
  if [ "$BEHALTEN" -eq 0 ] && [ "$roh" != "$img" ]; then rm -f -- "$roh"; else echo "Entpacktes Image bleibt: $roh"; fi
  return $rc
}

# ------------------------------------------------------------------ Aufruf
MODUS=""; WURZEL=""; BOOT=""; QUELLE_ANGABE=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --suche) MODUS=suche;;
    --wurzel) MODUS=wurzel; WURZEL="${2:?}"; shift;;
    --boot) BOOT="${2:?}"; shift;;
    --quelle) QUELLE_ANGABE="${2:?}"; shift;;
    --cache) CACHE="${2:?}"; shift;;
    --behalten) BEHALTEN=1;;
    --hilfe|-h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "Unbekannte Option: $1 (--hilfe)" >&2; exit 2;;
    *) POS+=("$1");;
  esac
  shift
done

case "$MODUS" in
  suche) suche; exit $?;;
  wurzel)
    [ -d "$WURZEL" ] || { echo "Verzeichnis fehlt: $WURZEL" >&2; exit 2; }
    wurzel_modus "$WURZEL" "$BOOT" "${POS[0]:-wurzel}" "${QUELLE_ANGABE:-Verzeichnis $WURZEL}"; exit $?;;
  *)
    [ "${#POS[@]}" -ge 1 ] || { echo "Aufruf: sudo bash $0 BILD [label]   |   --suche   |   --hilfe" >&2; exit 2; }
    bild_modus "${POS[0]}" "${POS[1]:-image}"; exit $?;;
esac
