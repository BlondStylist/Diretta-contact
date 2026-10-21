#!/usr/bin/env bash
# Sichert Konfiguration + Zustand eines AudioLinux-Geraets (Diretta Host oder Target) fuer den Vorher/Nachher-Vergleich.
# Nur lesend ausser der Ausgabe. Keine privaten SSH-Schluessel, keine Passwoerter.
# Usage: sudo bash snapshot.sh [label]        Env: OUT_BASE=/root/config-archiv  SAMPLE=10 (Sekunden IRQ-Delta, 0=aus)
# shellcheck disable=SC2016  # Befehle gehen bewusst als String an bash -c
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Als root starten: sudo bash $0 [label]" >&2; exit 4; }
taskset -pc 0,1 $$ >/dev/null 2>&1; renice -n 19 -p $$ >/dev/null 2>&1; ionice -c3 -p $$ >/dev/null 2>&1
label="${1:-pre-update}"; label="${label//[^A-Za-z0-9._-]/_}"; OUT_BASE="${OUT_BASE:-/root/config-archiv}"; SAMPLE="${SAMPLE:-10}"
ts="$(date +%Y%m%d-%H%M%S)"; base="snapshot-$(hostname)-$label-$ts"; name="$base"; n=1
while [[ -e "$OUT_BASE/$name" || -e "$OUT_BASE/$name.tar.gz" ]]; do n=$((n+1)); name="$base-$n"; done   # nie in ein altes Verzeichnis schreiben
D="$OUT_BASE/$name"
mkdir -p "$OUT_BASE" && (( $(df -Pk "$OUT_BASE" | awk 'NR==2{print $4}') > 204800 )) || { echo "Weniger als 200 MB frei in $OUT_BASE" >&2; exit 7; }
umask 077; mkdir -p "$D/report" "$D/volatile" || exit 7
cap() { local f="$1"; shift; { echo "\$ $*"; bash -c "$*" 2>&1; echo "[rc=$?]"; echo; } >> "$D/$f.txt"; }

# --- stabile Berichte (werden beim Vergleich gediffed) ---
r=report
cap $r/00-system 'hostname; cat /etc/os-release; uname -a; cat /proc/cmdline; cat /proc/device-tree/model; echo; grep -E "^(Model|Revision)" /proc/cpuinfo'
cap $r/00-system 'ls -la /etc/*release* /etc/audiolinux* /opt 2>&1; grep -rIhoiE "menu[ _]?version[^\"'"'"']{0,40}" /opt/scripts 2>/dev/null | sort -u | head -20'
cap $r/00-system 'vcgencmd version; rpi-eeprom-update; vcgencmd bootloader_config | head -40'
b=/boot; [[ -d /boot/firmware ]] && b=/boot/firmware
cap $r/00-system "ls -la $b | head -60; cat $b/cmdline.txt; cat $b/config.txt"
cap $r/10-packages 'pacman -Q; echo ---explicit; pacman -Qe; echo ---foreign; pacman -Qm; echo ---dkms; dkms status'
cap $r/10-packages 'pacman -Qii 2>/dev/null | awk "/^MODIFIED/"; find /etc /opt /usr/local -name "*.pacnew" -o -name "*.pacsave" 2>/dev/null'
cap $r/10-packages 'ls -la /boot/*.img /boot/vmlinuz* /lib/modules 2>/dev/null; cat /etc/pacman.conf | grep -vE "^\s*#|^\s*$"; grep -vE "^\s*#|^\s*$" /etc/pacman.d/mirrorlist'
cap $r/20-services 'systemctl list-unit-files --no-pager; systemctl list-timers --all --no-pager --no-legend | awk "{print \$(NF-1), \$NF}"; systemctl --failed --no-pager; systemd-delta --no-pager'
cap $r/20-services 'for u in end0-irq-core3 usb-irq-core3 diretta-thread-pin disable-eee limit-speed-100m qdisc-pfifo purist-mode-webui purist-mode-auto purist-mode-revert-on-boot diretta_alsa diretta_alsa_target roonbridge; do systemctl show "$u" -p Id,LoadState,UnitFileState,ActiveState --no-pager; echo; done'
cap $r/20-services 'systemctl cat isolated0.slice isolated1.slice diretta_alsa.service diretta_alsa_target.service 2>&1; for f in /sys/fs/cgroup/isolated*.slice/cpuset.cpus*; do echo "$f: $(cat $f)"; done'
cap $r/30-network 'ip -br a; ip r; networkctl status --no-pager; cat /etc/hosts /etc/resolv.conf; ip -d link show end0 | head -5'
cap $r/30-network 'for i in $(ls /sys/class/net | grep -vx lo); do echo "== $i"; ethtool $i; ethtool -c $i; ethtool -k $i | grep -E ": on|: off" | head -80; ethtool --show-eee $i; tc qdisc show dev $i; done'
cap $r/30-network 'nft list ruleset; sysctl -a 2>/dev/null | grep -vE "^(fs\.(dentry|file-nr|inode)|kernel\.(random|pty|ns_last_pid)|vm\.(stat|dirty_)|net\..*(neigh|stat))" | sort'
cap $r/40-cpu-irq 'for d in /proc/irq/[0-9]*; do n=${d##*/}; echo "$n $(cat $d/smp_affinity) eff=$(cat $d/effective_affinity 2>/dev/null) $(awk -v n="$n:" "\$1==n{print \$NF}" /proc/interrupts)"; done'
cap $r/40-cpu-irq 'grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; cat /sys/kernel/mm/transparent_hugepage/enabled; cat /sys/devices/system/cpu/isolated /sys/devices/system/cpu/nohz_full 2>&1'
cap $r/50-diretta 'ls -la /opt/diretta-alsa /opt/diretta-alsa-target; for f in /opt/diretta-alsa/setting.inf /opt/diretta-alsa-target/*setting*.inf; do echo "## $f"; cat "$f"; done'
cap $r/50-diretta 'pacman -Q | grep -iE "diretta|roon|upmpdcli|minim|purist"; lsmod | grep -iE "diretta|snd_usb|alsa_bridge"; modinfo diretta_direct 2>&1 | head; sha256sum /opt/diretta-alsa*/* 2>/dev/null'
cap $r/50-diretta 'find /etc /opt /usr/local /home /var/lib /srv -xdev \( -name super_purist.flag -o -name "purist*" \) 2>/dev/null | head -40; cat /etc/sudoers.d/* 2>&1'
cap $r/60-audio 'cat /proc/asound/cards; aplay -l; lsusb -t; lsblk -f; mount | grep -E "^/dev"'
cap $r/70-extras 'ls -laR /home/audiolinux 2>/dev/null | grep -vE "\.(flac|mp3|wav)$" | head -400'
cap volatile/recent-files 'find /etc /opt /usr/local /home/audiolinux -xdev -type f -mtime -45 -printf "%TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | sort | tail -400'
cap $r/70-extras 'crontab -l; ls /var/spool/cron /etc/cron.d; systemctl --user list-unit-files 2>&1 | head -40'

# --- volatile Messwerte (nicht gediffed) ---
v=volatile
cap $v/uptime 'df -h; uptime; date; vcgencmd get_throttled; vcgencmd measure_volts core; vcgencmd measure_temp; vcgencmd pmic_read_adc 2>&1 | head -30'
cap $v/threads 'ps -eLo pid,tid,cls,rtprio,psr,comm --sort=-rtprio | head -60; for p in $(pgrep -f "[s]yncAlsa|[d]iretta"); do chrt -p $p; taskset -cp $p; done'
cap $v/interrupts-t0 'cat /proc/interrupts'
if (( SAMPLE > 0 )); then sleep "$SAMPLE"; cap $v/interrupts-t1 'cat /proc/interrupts'; fi
cap $v/journal 'journalctl -b -p warning --no-pager | tail -150; journalctl -u diretta_alsa_target -b --no-pager | grep -iE "licen|valid|ReleaseNo|version|certified|MTU" | tail -20'

# --- Dateien ---
paths=(/etc/systemd /etc/sudoers.d /etc/sysctl.d /etc/sysctl.conf /etc/udev/rules.d /etc/modprobe.d /etc/modules-load.d /etc/security
  /etc/rtirq.conf /etc/rtpriority /etc/rtapp /etc/pacman.conf /etc/pacman.d/mirrorlist /etc/fstab /etc/hosts /etc/hostname /etc/environment
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/chrony.conf /etc/nftables.conf /etc/default /etc/mkinitcpio.conf /etc/dkms /etc/conf.d
  /etc/cron.d /var/spool/cron /opt/configuration /opt/scripts /opt/diretta-alsa /opt/diretta-alsa-target
  "$b/cmdline.txt" "$b/config.txt" /home/audiolinux/.ssh/config /home/audiolinux/.ssh/authorized_keys /home/audiolinux/.config/systemd
  /home/audiolinux/.bashrc /home/audiolinux/.bash_profile)
while IFS= read -r -d '' f; do paths+=("$f"); done < <(find /home/audiolinux -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.conf' \) -size -200k -not -path '*/.cache/*' -not -path '*/snapshots/*' -print0 2>/dev/null)
ex=(); for p in "${paths[@]}"; do [[ -e $p ]] && ex+=("${p#/}"); done
tar -czpf "$D/files.tar.gz" --ignore-failed-read --exclude='*.o' --exclude='.git' --exclude='*.ko' --exclude='*.log' -C / "${ex[@]}" 2>/dev/null
(( $? <= 1 )) || { echo "FEHLER: files.tar.gz unvollstaendig (Platz?)" >&2; exit 5; }   # 1 = Datei aenderte sich, ok
sx="$(mktemp -d)"; tar -xzf "$D/files.tar.gz" -C "$sx" 2>/dev/null   # Zugangsdaten-Scan: nur warnen, nichts weglassen
hits="$(grep -rIiE 'BEGIN [A-Z ]*PRIVATE KEY|(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+' "$sx" 2>/dev/null | grep -v NOPASSWD | cut -d: -f1 | sort -u | sed "s|^$sx||")"; rm -rf "$sx"
[[ -n $hits ]] && { echo "$hits" > "$D/WARNUNG-zugangsdaten.txt"; echo "WARNUNG: moegliche Zugangsdaten in Dateien (Archiv privat halten):"; echo "$hits"; }
find "${ex[@]/#//}" -type f -print0 2>/dev/null | xargs -0 sha256sum 2>/dev/null | sort -k2 > "$D/manifest.sha256"

( cd "$OUT_BASE" && tar -czf "$name.tar.gz" "$name" ) && chmod 0600 "$OUT_BASE/$name.tar.gz"
if [[ -d /home/audiolinux ]]; then mkdir -p /home/audiolinux/snapshots && cp -a "$OUT_BASE/$name.tar.gz" /home/audiolinux/snapshots/ && chown -R audiolinux: /home/audiolinux/snapshots; fi
echo "Fertig: $OUT_BASE/$name.tar.gz ($(du -h "$OUT_BASE/$name.tar.gz" | cut -f1), ${#ex[@]} Pfade, $(wc -l < "$D/manifest.sha256") Dateien)"
echo "Kopie: /home/audiolinux/snapshots/ (per scp holen). Enthaelt IPs/Seriennummer, nicht oeffentlich ablegen."
