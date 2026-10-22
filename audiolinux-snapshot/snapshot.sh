#!/usr/bin/env bash
# Sichert Konfiguration + Zustand eines AudioLinux-Geraets (Diretta Host oder Target) fuer den Vorher/Nachher-Vergleich.
# Nur lesend ausser der Ausgabe. Kein shadow, keine privaten SSH-/Host-Schluessel.
# Usage: sudo bash snapshot.sh [label]        Env: OUT_BASE=/root/config-archiv  SAMPLE=10 (Sekunden IRQ-Delta, 0=aus)
# Exit: 0 ok | 3 Pflicht-Werkzeug fehlt | 4 kein Root | 5 Archiv unvollstaendig | 7 zu wenig Platz | 130 abgebrochen
# shellcheck disable=SC2016  # Befehle gehen bewusst als String an bash -c
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Als root starten: sudo bash $0 [label]" >&2; exit 4; }
need=(tar gzip find xargs sha256sum sort awk df mktemp grep sed cut wc du head tail readlink date uname)
miss=(); for c in "${need[@]}"; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
(( ${#miss[@]} == 0 )) || { echo "Fehlende Pflicht-Werkzeuge: ${miss[*]} (Arch: pacman -S coreutils findutils gawk tar gzip grep sed diffutils)" >&2; exit 3; }
export LC_ALL=C LANG=C                       # stabile Ausgabe: keine Sprachunterschiede im Vergleich
trap '' HUP                                  # SSH-Abbruch beendet den Lauf nicht
taskset -pc 0,1 $$ >/dev/null 2>&1; renice -n 19 -p $$ >/dev/null 2>&1; ionice -c3 -p $$ >/dev/null 2>&1   # Audiokerne 2-3 nicht stoeren
label="${1:-pre-update}"; label="${label//[^A-Za-z0-9._-]/_}"; OUT_BASE="${OUT_BASE:-/root/config-archiv}"; SAMPLE="${SAMPLE:-10}"
ts="$(date +%Y%m%d-%H%M%S)"; base="snapshot-$(uname -n)-$label-$ts"; name="$base"; n=1
while [[ -e "$OUT_BASE/$name" || -e "$OUT_BASE/$name.tar.gz" ]]; do n=$((n+1)); name="$base-$n"; done   # nie in ein altes Verzeichnis schreiben
D="$OUT_BASE/$name"; sx=""
mkdir -p "$OUT_BASE" && (( $(df -Pk "$OUT_BASE" | awk 'NR==2{print $4}') > 204800 )) || { echo "Weniger als 200 MB frei in $OUT_BASE" >&2; exit 7; }
umask 077; mkdir -p "$D/report" "$D/volatile" || exit 7
abort() { echo "ABBRUCH: unvollstaendiger Snapshot wird verworfen" >&2
  [[ $D == "$OUT_BASE"/snapshot-* ]] && rm -rf -- "$D" "$D.tar.gz"; [[ -n $sx && -d $sx ]] && rm -rf -- "$sx"; exit 130; }
trap abort INT TERM
fst="$(findmnt -no FSTYPE / 2>/dev/null || awk '$2=="/"{t=$3} END{print t}' /proc/mounts)"
case "$fst" in ext4|f2fs|btrfs|xfs|vfat) ;; *) echo "WARNUNG: Root-Dateisystem ist '$fst' (ramroot?). Das Archiv liegt dann im RAM und ist nach einem Neustart weg: sofort per scp holen." >&2;; esac

# Befehl ausfuehren, Ausgabe + Exit-Code ablegen; Fehlschlaege zusaetzlich in fehler.txt
cap() { local f="$1" out rc; shift; out="$(bash -c "$*" 2>&1)"; rc=$?
  printf '$ %s\n%s\n[rc=%s]\n\n' "$*" "$out" "$rc" >> "$D/$f.txt"
  (( rc == 0 )) || printf '%s | %.90s\n' "$f" "$*" >> "$D/fehler.txt"; }

# --- stabile Berichte (werden beim Vergleich gediffed) ---
r=report
cap $r/00-system 'uname -n; cat /etc/os-release; uname -a; cat /proc/cmdline; tr -d "\0" < /proc/device-tree/model; echo; grep -E "^(Model|Revision)" /proc/cpuinfo'
cap $r/00-system 'findmnt / || grep " / " /proc/mounts; cat /proc/mounts; ip -br link'
cap $r/00-system 'ls -la /etc/*release* /etc/audiolinux* /opt 2>&1; grep -rIhoiE "menu[ _]?version[^\"'"'"']{0,40}" /opt/scripts 2>/dev/null | sort -u | head -20'
cap $r/00-system 'vcgencmd version; rpi-eeprom-update; vcgencmd bootloader_config | head -40'
b=/boot; [[ -d /boot/firmware ]] && b=/boot/firmware
cap $r/00-system "ls -la $b | head -60; cat $b/cmdline.txt; cat $b/config.txt"
cap $r/10-packages 'pacman -Q; echo ---explicit; pacman -Qe; echo ---foreign; pacman -Qm; echo ---dkms; dkms status'
cap $r/10-packages 'pacman -Qii 2>/dev/null | awk "/^MODIFIED/"; find /etc /opt /usr/local -name "*.pacnew" -o -name "*.pacsave" 2>/dev/null'
cap $r/10-packages 'ls -la /boot/*.img /boot/vmlinuz* /lib/modules 2>&1; grep -vE "^\s*#|^\s*$" /etc/pacman.conf /etc/pacman.d/mirrorlist'
cap $r/20-services 'systemctl list-unit-files --no-pager; systemctl list-timers --all --no-pager --no-legend | awk "{print \$(NF-1), \$NF}"; systemctl --failed --no-pager; systemd-delta --no-pager'
cap $r/20-services 'for u in end0-irq-core3 usb-irq-core3 diretta-thread-pin disable-eee limit-speed-100m qdisc-pfifo purist-mode-webui purist-mode-auto purist-mode-revert-on-boot diretta_alsa diretta_alsa_target roonbridge; do systemctl show "$u" -p Id,LoadState,UnitFileState,ActiveState --no-pager; echo; done'
cap $r/20-services 'systemctl cat isolated0.slice isolated1.slice diretta_alsa.service diretta_alsa_target.service 2>&1; for f in /sys/fs/cgroup/isolated*.slice/cpuset.cpus*; do echo "$f: $(cat $f)"; done'
if id audiolinux >/dev/null 2>&1; then
  cap $r/20-services 'u=$(id -u audiolinux); setpriv --reuid=audiolinux --regid=audiolinux --init-groups env XDG_RUNTIME_DIR=/run/user/$u systemctl --user list-unit-files --no-pager; crontab -u audiolinux -l; loginctl show-user audiolinux'
fi
cap $r/20-services 'crontab -l; ls /var/spool/cron /etc/cron.d'
cap $r/30-network 'ip -br a; ip r; networkctl status --no-pager; cat /etc/hosts /etc/resolv.conf; ip -d link show end0 | head -5'
cap $r/30-network 'for i in $(ls /sys/class/net | grep -vx lo); do echo "== $i"; ethtool $i; ethtool -c $i; ethtool -k $i | grep -E ": on|: off" | head -80; ethtool --show-eee $i; tc qdisc show dev $i; done'
cap $r/30-network 'nft list ruleset; sysctl -a 2>/dev/null | grep -vE "^(fs\.(dentry|file-nr|inode)|kernel\.(random|pty|ns_last_pid)|vm\.(stat|dirty_)|net\..*(neigh|stat))" | sort'
cap $r/40-cpu-irq 'for d in /proc/irq/[0-9]*; do n=${d##*/}; echo "$n $(cat $d/smp_affinity) eff=$(cat $d/effective_affinity 2>/dev/null) $(awk -v n="$n:" "\$1==n{print \$NF}" /proc/interrupts)"; done'
cap $r/40-cpu-irq 'grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; cat /sys/kernel/mm/transparent_hugepage/enabled; cat /sys/devices/system/cpu/isolated /sys/devices/system/cpu/nohz_full 2>&1'
cap $r/50-diretta 'ls -la /opt/diretta-alsa /opt/diretta-alsa-target; for f in /opt/diretta-alsa/setting.inf /opt/diretta-alsa-target/*setting*.inf; do echo "## $f"; cat "$f"; done'
cap $r/50-diretta 'pacman -Q | grep -iE "diretta|roon|upmpdcli|minim|purist"; lsmod | grep -iE "diretta|snd_usb|alsa_bridge"; modinfo diretta_direct 2>&1 | head; sha256sum /opt/diretta-alsa*/* 2>/dev/null'
cap $r/50-diretta 'find /etc /opt /usr/local /home /var/lib /srv -xdev \( -name super_purist.flag -o -name "purist*" \) 2>/dev/null | head -40; cat /etc/sudoers.d/* 2>&1'
cap $r/60-audio 'cat /proc/asound/cards; aplay -l; lsusb -t; lsblk -f'
cap $r/70-extras 'find /home/audiolinux -maxdepth 3 -printf "%M %u %s %p\n" 2>/dev/null | grep -vE "\.(flac|mp3|wav)$" | sort -k4 | head -600; du -sh /var/roon /home/audiolinux/.* /opt/* 2>/dev/null'

# --- volatile Messwerte (nicht gediffed) ---
v=volatile
cap $v/uptime 'df -h; uptime; date; vcgencmd get_throttled; vcgencmd measure_volts core; vcgencmd measure_temp; vcgencmd pmic_read_adc 2>&1 | head -30'
cap $v/threads 'ps -eLo pid,tid,cls,rtprio,psr,comm --sort=-rtprio | head -60; for p in $(pgrep -f "[s]yncAlsa|[d]iretta"); do chrt -p $p; taskset -cp $p; done'
cap $v/interrupts-t0 'cat /proc/interrupts'
if (( SAMPLE > 0 )); then sleep "$SAMPLE"; cap $v/interrupts-t1 'cat /proc/interrupts'; fi
cap $v/recent-files 'find /etc /opt /usr/local /home/audiolinux -xdev -type f -mtime -45 -printf "%TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | sort | tail -400'
cap $v/journal 'journalctl -b -p warning --no-pager | tail -150; journalctl -u diretta_alsa_target -b --no-pager | grep -iE "licen|valid|ReleaseNo|version|certified|MTU" | tail -20'

# --- Dateien: ganz /etc (ohne Geheimnisse/Regenerierbares) + gezielte Pfade ---
paths=(/etc /var/spool/cron /opt/configuration /opt/scripts /opt/diretta-alsa /opt/diretta-alsa-target "$b/cmdline.txt" "$b/config.txt"
  /home/audiolinux/.ssh/config /home/audiolinux/.ssh/authorized_keys /home/audiolinux/.config/systemd /home/audiolinux/.bashrc /home/audiolinux/.bash_profile)
while IFS= read -r -d '' f; do paths+=("$f"); done < <(find /home/audiolinux -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.conf' \) -size -200k -not -path '*/.cache/*' -not -path '*/snapshots/*' -print0 2>/dev/null)
ex=(); for p in "${paths[@]}"; do [[ -e $p ]] && ex+=("${p#/}"); done
excl=(--exclude='etc/shadow*' --exclude='etc/gshadow*' --exclude='etc/ssh/ssh_host_*' --exclude='etc/ssl/private' --exclude='etc/pacman.d/gnupg'
  --exclude='etc/ca-certificates/extracted' --exclude='etc/ssl/certs' --exclude='etc/ld.so.cache' --exclude='etc/udev/hwdb.bin' --exclude='etc/*-'
  --exclude='*.o' --exclude='.git' --exclude='*.ko' --exclude='*.log')
tar -czpf "$D/files.tar.gz" --ignore-failed-read "${excl[@]}" -C / "${ex[@]}" 2>/dev/null
(( $? <= 1 )) || { echo "FEHLER: files.tar.gz unvollstaendig (Platz?)" >&2; exit 5; }   # 1 = Datei aenderte sich, ok

# Manifest aus dem Archiv selbst (Dateien + Symlink-Ziele); gleichzeitig Zugangsdaten-Scan
sx="$(mktemp -d)"; tar -xzf "$D/files.tar.gz" -C "$sx" --no-same-owner 2>/dev/null
hits="$(grep -rIiE 'BEGIN [A-Z ]*PRIVATE KEY|(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+' "$sx" 2>/dev/null | grep -v NOPASSWD | cut -d: -f1 | sort -u | sed "s|^$sx||")"
[[ -n $hits ]] && { echo "$hits" > "$D/WARNUNG-zugangsdaten.txt"; echo "WARNUNG: moegliche Zugangsdaten in Dateien (Archiv privat halten):"; echo "$hits"; }
{ ( cd "$sx" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum )
  ( cd "$sx" && find . -type l -print0 | while IFS= read -r -d '' l; do printf '%s  %s\n' "$(readlink "$l" | sha256sum | cut -c1-64)" "$l"; done )
} | sed -E 's#^([0-9a-f]{64}  )\./#\1/#' | sort -k2 > "$D/manifest.sha256"
rm -rf -- "$sx"; sx=""

if [[ -s $D/fehler.txt ]]; then echo "Hinweis: $(wc -l < "$D/fehler.txt") Befehle mit Fehler (fehlende Tools sind normal), z. B.:"; head -6 "$D/fehler.txt"; fi
( cd "$OUT_BASE" && tar -czf "$name.tar.gz" "$name" ) || { echo "FEHLER: Archiv konnte nicht erstellt werden" >&2; exit 5; }
chmod 0600 "$OUT_BASE/$name.tar.gz"; trap - INT TERM
nfiles="$(wc -l < "$D/manifest.sha256")"; rm -rf -- "$D"      # nur das eine Archiv behalten

# Kopie fuer den Nutzer: als Nutzer schreiben (root folgt nie einem vom Nutzer gelegten Symlink).
# setpriv statt runuser: keine PAM-Sitzung, also kein Eintrag in lastlog (der Snapshot soll nichts am System veraendern)
as_user() { if command -v setpriv >/dev/null 2>&1; then setpriv --reuid=audiolinux --regid=audiolinux --init-groups "$@"; else runuser -u audiolinux -- "$@"; fi; }
if id audiolinux >/dev/null 2>&1; then
  uh="$(getent passwd audiolinux 2>/dev/null | cut -d: -f6)"; uh="${uh:-/home/audiolinux}"
  as_user sh -c 'umask 077; d="$1/snapshots"; [ ! -L "$d" ] || { echo "WARNUNG: $d ist ein Symlink, Kopie uebersprungen" >&2; exit 1; }; mkdir -p "$d" && cat > "$d/$2"' _ "$uh" "$name.tar.gz" < "$OUT_BASE/$name.tar.gz" \
    && copy="Kopie: $uh/snapshots/$name.tar.gz" || copy="Kopie nach $uh/snapshots fehlgeschlagen: Archiv aus $OUT_BASE holen"
else copy="Kein Nutzer audiolinux: Archiv aus $OUT_BASE holen"; fi
sync                                          # Stromausfall/Omni-Haenger direkt nach dem Lauf darf das Archiv nicht kosten
echo "Fertig: $OUT_BASE/$name.tar.gz ($(du -h "$OUT_BASE/$name.tar.gz" | cut -f1), ${#ex[@]} Pfade, $nfiles Dateien/Links)"
echo "$copy. Enthaelt IPs/Seriennummer, nicht oeffentlich ablegen."
