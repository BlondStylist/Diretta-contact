#!/usr/bin/env bash
# laptop-setup.sh - richtet den Laptop (Ubuntu/WSL) fuer die Arbeit mit Diretta Host und Target ein.
#
# Erledigt, soweit automatisierbar:
#   schluessel  eigenen SSH-Schluessel anlegen (ed25519), falls noch keiner da ist
#   config      ~/.ssh/config: Aliase diretta-host/host und diretta-target/target (ProxyJump ueber den Host)
#   kopieren    Schluessel auf Host und Target freischalten (Passwort der Pis tippst DU, genau einmal je Geraet)
#   test        Anmeldung ohne Passwort pruefen (BatchMode)
#   repos       Diretta-contact und diretta-werkzeuge sicher auf den Arbeitsstand bringen
#   pruefen     python3-venv, sudo, unshare, git vorhanden?
#   verteilen   (nur auf Wunsch) Snapshot-Skripte auf beide Pis kopieren und dort den Vorabcheck laufen lassen
#
# Aufruf im Ubuntu-Fenster, direkt am Terminal (nicht ueber Claude: es fragt nach Passwoertern):
#   bash audiolinux-snapshot/laptop-setup.sh              alle Schritte ausser "verteilen"
#   bash audiolinux-snapshot/laptop-setup.sh --config     einzelne Schritte: --schluessel --config --kopieren
#                                                         --test --repos --pruefen --verteilen
#   Optionen: --ja (Rueckfragen mit Ja beantworten), --hilfe
# Umgebung: HOST_IP, TARGET_IP, PI_USER, KEY, REPO_SPEC, DIRETTA_KEY_PASSPHRASE (leer = keine Passphrase)
# Exit: 0 ok | 1 mindestens ein Schritt unvollstaendig | 2 Werkzeug fehlt
set -uo pipefail

HOST_IP="${HOST_IP:-192.168.178.75}"
TARGET_IP="${TARGET_IP:-172.20.0.2}"
PI_USER="${PI_USER:-audiolinux}"
KEY="${KEY:-$HOME/.ssh/id_ed25519_diretta}"
SSH_DIR="$HOME/.ssh"
CFG="$SSH_DIR/config"
REPO_SPEC="${REPO_SPEC:-$HOME/Diretta-contact|https://github.com/BlondStylist/Diretta-contact.git|claude/audiolinux-snapshot-tools
$HOME/diretta-werkzeuge|https://github.com/BlondStylist/diretta-werkzeuge.git|claude/audit-alles}"
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JA=0
RC=0
SCHRITTE=()

hilfe() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

frage() {  # frage "Text" -> 0 bei Ja
  [ "$JA" -eq 1 ] && return 0
  [ -t 0 ] || return 1
  local a; read -r -p "$1 [j/N] " a; case "$a" in j|J|y|Y) return 0;; *) return 1;; esac
}

schluessel() {
  echo "== Schluessel"
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
  if [ -f "$KEY" ]; then echo "  vorhanden: $KEY"; return 0; fi
  command -v ssh-keygen >/dev/null 2>&1 || { echo "  ssh-keygen fehlt (sudo apt install openssh-client)"; return 2; }
  local kommentar
  kommentar="diretta-laptop-$(uname -n)-$(date +%F)"
  if [ -n "${DIRETTA_KEY_PASSPHRASE+x}" ]; then
    ssh-keygen -q -t ed25519 -f "$KEY" -N "$DIRETTA_KEY_PASSPHRASE" -C "$kommentar" || return 1
  else
    echo "  Du wirst nach einer Passphrase gefragt (empfohlen; Enter = keine)."
    ssh-keygen -t ed25519 -f "$KEY" -C "$kommentar" || return 1
  fi
  echo "  angelegt: $KEY (privat, bleibt auf dem Laptop) und $KEY.pub (oeffentlich)"
  echo "  Tipp: ssh-agent nutzen, dann fragt ssh nicht jedes Mal nach der Passphrase:"
  echo "        eval \"\$(ssh-agent -s)\" && ssh-add $KEY"
}

config_block() {
  cat <<EOT
# BEGIN diretta (laptop-setup.sh) - dieser Block wird bei jedem Lauf neu geschrieben
Host diretta-host host
  HostName $HOST_IP
  User $PI_USER
  IdentityFile $KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
Host diretta-target target
  HostName $TARGET_IP
  User $PI_USER
  ProxyJump diretta-host
  IdentityFile $KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
# END diretta
EOT
}

config() {
  echo "== ~/.ssh/config"
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
  [ -f "$CFG" ] || : > "$CFG"
  [ ! -s "$CFG" ] || cp -a "$CFG" "$CFG.vor-diretta-$(date +%Y%m%d-%H%M%S)"
  local alt neu
  alt="$(mktemp)"; neu="$(mktemp)"
  awk '/^# BEGIN diretta \(laptop-setup.sh\)/{skip=1} !skip{print} /^# END diretta/{skip=0}' "$CFG" > "$alt"
  { config_block; echo; cat "$alt"; } > "$neu"
  cat "$neu" > "$CFG"; chmod 600 "$CFG"
  # Der Block steht GANZ OBEN, weil ssh je Option den ERSTEN passenden Eintrag nimmt.
  echo "  Block fuer diretta-host/host ($HOST_IP) und diretta-target/target ($TARGET_IP, ueber den Host) steht oben."
  if grep -nE 'HostName[[:space:]]+192\.168\.178\.(66|71)([^0-9]|$)' "$alt" | sed 's/^/  WARNUNG alte Host-Adresse in der Config, Zeile /' | grep .; then
    echo "  (die alten Eintraege weiter unten werden durch den Block uebersteuert, koennen aber geloescht werden)"
  fi
  rm -f "$alt" "$neu"
}

ssh_still() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$@"; }

kopieren() {
  echo "== Schluessel auf den Pis freischalten"
  [ -f "$KEY.pub" ] || { echo "  $KEY.pub fehlt: zuerst --schluessel"; return 1; }
  command -v ssh >/dev/null 2>&1 || { echo "  ssh fehlt (sudo apt install openssh-client)"; return 2; }
  local h rc=0
  for h in diretta-host diretta-target; do
    if ssh_still "$h" true 2>/dev/null; then echo "  $h: schon freigeschaltet"; continue; fi
    echo "  $h: Passwort des Benutzers $PI_USER wird jetzt von ssh abgefragt (du tippst es selbst)"
    if command -v ssh-copy-id >/dev/null 2>&1; then
      ssh-copy-id -i "$KEY.pub" "$h" || rc=1
    else
      ssh "$h" 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys' < "$KEY.pub" || rc=1
    fi
  done
  return $rc
}

test_verbindung() {
  echo "== Verbindung ohne Passwort"
  local h rc=0
  for h in diretta-host diretta-target; do
    if o="$(ssh_still "$h" 'hostname; uname -r' 2>&1)"; then echo "  $h: ok ($(echo "$o" | tr '\n' ' '))"; else echo "  $h: FEHLT ($o)"; rc=1; fi
  done
  return $rc
}

repos() {
  echo "== Repos"
  command -v git >/dev/null 2>&1 || { echo "  git fehlt (sudo apt install git)"; return 2; }
  local dir url br rc=0 name mail
  while IFS='|' read -r dir url br; do
    [ -n "$dir" ] || continue
    echo "  -- $dir ($br)"
    if [ ! -d "$dir/.git" ]; then
      git clone -q "$url" "$dir" || { echo "     clone fehlgeschlagen (private Repos: Anmeldung per 'gh auth login' oder SSH-Schluessel bei GitHub)"; rc=1; continue; }
    fi
    (
      cd "$dir" || exit 1
      if [ -n "$(git status --porcelain)" ]; then
        echo "     lokale Aenderungen:"; git status -s | head -20 | sed 's/^/       /'; git diff --stat | tail -3 | sed 's/^/       /'
        if frage "     in einen Stash legen? (nichts geht verloren; zurueck mit 'git stash pop')"; then
          name="$(git config user.name || echo laptop-setup)"; mail="$(git config user.email || echo laptop-setup@localhost)"
          git -c user.name="$name" -c user.email="$mail" stash push -u -m "vor laptop-setup $(date +%F-%H%M%S)" >/dev/null || exit 1
          echo "     gesichert: $(git stash list | head -1)"
        else
          echo "     uebersprungen, nichts veraendert"; exit 1
        fi
      fi
      git fetch -q origin || { echo "     fetch fehlgeschlagen"; exit 1; }
      if git show-ref -q --verify "refs/heads/$br"; then git checkout -q "$br" || exit 1
      else git checkout -q -b "$br" "origin/$br" || { echo "     Branch $br fehlt auf origin"; exit 1; }; fi
      git pull -q --ff-only origin "$br" || { echo "     pull --ff-only nicht moeglich (lokale Commits?)"; exit 1; }
      echo "     jetzt $(git rev-parse --short HEAD) auf $br"
    ) || rc=1
  done <<<"$REPO_SPEC"
  return $rc
}

pruefen() {
  echo "== Werkzeuge auf dem Laptop"
  local c rc=0
  for c in git python3 sudo unshare ssh; do
    if command -v "$c" >/dev/null 2>&1; then echo "  ok     $c"; else echo "  FEHLT  $c"; rc=1; fi
  done
  python3 -c 'import venv, ensurepip' 2>/dev/null && echo "  ok     python3-venv" || { echo "  FEHLT  python3-venv (sudo apt install python3-venv)"; rc=1; }
  return $rc
}

verteilen() {
  echo "== Snapshot-Skripte auf die Pis kopieren und Vorabcheck ausfuehren"
  frage "  Laeuft gerade Musik? scp/ssh ueber die Strecke stoert das Hoeren. Wiedergabe ist AUS, fortfahren?" || { echo "  abgebrochen"; return 1; }
  local h rc=0
  for h in diretta-host diretta-target; do
    scp -q "$HIER/snapshot.sh" "$HIER/compare.sh" "$HIER/restore.sh" "$h:~/" || { echo "  $h: scp fehlgeschlagen"; rc=1; continue; }
    echo "  -- $h: bash snapshot.sh --check"
    ssh_still "$h" 'bash ~/snapshot.sh --check' | sed 's/^/     /' || rc=1
  done
  return $rc
}

while [ $# -gt 0 ]; do
  case "$1" in
    --schluessel|--config|--kopieren|--test|--repos|--pruefen|--verteilen) SCHRITTE+=("${1#--}");;
    --ja) JA=1;;
    --hilfe|-h|--help) hilfe; exit 0;;
    *) echo "Unbekannte Option: $1 (--hilfe)" >&2; exit 2;;
  esac
  shift
done
[ "${#SCHRITTE[@]}" -gt 0 ] || SCHRITTE=(pruefen repos schluessel config kopieren test)

for s in "${SCHRITTE[@]}"; do
  case "$s" in
    test) test_verbindung; r=$?;;
    *) "$s"; r=$?;;
  esac
  [ "$r" -eq 0 ] || RC=1
  [ "$r" -ne 2 ] || { echo "Abbruch: Werkzeug fehlt"; exit 2; }
done
echo
if [ "$RC" -eq 0 ]; then echo "FERTIG: alle Schritte ok."; else echo "FERTIG mit offenen Punkten (siehe oben)."; fi
exit "$RC"
