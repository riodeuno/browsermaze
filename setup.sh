#!/usr/bin/env bash
# setup.sh — installs browsermaze. --role picks what: `pool` or `login`. The default follows the OS.
#
#   pool (the default on Linux; Ubuntu 24.04 or 26.04, x86_64 or arm64): installs the browser pool
#     on this machine.
#     Chrome from Google's apt repository, Xvfb, x11vnc, ffmpeg, socat, rsync and
#     python3-websockets; the `browser` service account; /srv/browsers; the `browsermaze`
#     command and its systemd units; the login that leases slots, with its sudo rule; and a
#     smoke test that leases a slot, fetches its CDP endpoint and releases it. The answers go to
#     /etc/browsermaze/config, which browsermaze and the units read.
#   login (the default on macOS; on a Linux desktop pass --role login): installs the `browsermaze`
#     command, which logs a Chrome in on this Mac or Linux desktop and copies the logins into the
#     pool's golden profile. Its config, ~/.config/browsermaze/config, holds the pool's ssh
#     destination.
#
# Run it from a checkout of the repository, as the user who will run it. The pool role calls sudo
# for everything under /etc, /usr/local, /srv and apt.
#
#   bash setup.sh                       # asks on a terminal, takes the defaults without one
#   bash setup.sh --bind 192.0.2.7 --slots 6 --caller alice --authorize-key "$(cat key.pub)"
#   bash setup.sh --pool alice@192.0.2.7                  # on macOS
#   bash setup.sh --role login --pool alice@192.0.2.7     # on a Linux desktop
#
# Each question has a flag and an environment variable (setup.sh --help lists them), so another
# script can run setup.sh with no terminal. The order of precedence is flag, environment
# variable, the answer remembered in the config file, a question on a terminal, the default.
#
# Each install is a step that prints "installed" or "unchanged", or "FAILED" with the log's tail,
# and running setup.sh again changes nothing that is already in place. The last output is a
# checklist with a "fix:" line for each item that failed. Exit status: 0 when everything is in
# place, 1 when anything failed, 2 when the flags or answers are not valid.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERSION="$(tr -d '[:space:]' <"$DIR/VERSION")"  # the one place the version is written down
NL=$'\n'

# --- pins ------------------------------------------------------------------------------
# gum asks the questions and draws the login command's prompts. Each platform's tarball has its own sha256,
# checked against the release's checksums.txt.
GUM_VERSION=2.0.2
GUM_URL_BASE=https://github.com/charmbracelet/gum/releases/download/v2.0.2
GUM_PINS=(
  "Linux_x86_64 d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2"
  "Linux_arm64 8ebf8b54ec1e8c81f2bb58b59ff9b70998186a4d11375f0cf357b80e0ccfa1d5"
  "Darwin_x86_64 5374966c7c7199ea879fcaa525ddc6d447a098d3d35496e430a9a1ef38d30485"
  "Darwin_arm64 4777a69b1170b8db23c95d5889fb32186cfda1a3ac950d339aa17e3513633890"
)
# Chrome has no pin: the pool wants Chrome stable, from Google's apt repository, because it logs
# in to real sites that expect a current browser.
CHROME_KEY_URL=https://dl.google.com/linux/linux_signing_key.pub
CHROME_KEYRING=/usr/share/keyrings/google-chrome.gpg
CHROME_LIST=/etc/apt/sources.list.d/google-chrome.list
CHROME_REPO_LINE="deb [arch=amd64,arm64 signed-by=$CHROME_KEYRING] https://dl.google.com/linux/chrome/deb/ stable main"
APT_PREREQS=(ca-certificates curl gnupg sudo)
APT_PACKAGES=(google-chrome-stable xvfb x11vnc ffmpeg socat rsync python3 python3-websockets)

# --- layout ----------------------------------------------------------------------------
BIN="$HOME/.local/bin"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/browsermaze-setup"
ANSWERED="$STATE/answered"
POOL_CONFIG=/etc/browsermaze/config
LOGIN_CONFIG="${BROWSERMAZE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/browsermaze/config}"
SUDOERS_FILE=/etc/sudoers.d/browsermaze
# The pool role installs the whole command here, root-owned, and links it from /usr/local/bin. The
# pool program is the one file the caller's sudo rule names.
LIB=/usr/local/lib/browsermaze
LIB_PROGRAM=$LIB/browsermaze-pool
# 0.3.x installed the pool program as /usr/local/bin/browserpool, under a sudo rule in
# /etc/sudoers.d/browserpool. The pool role removes both.
OLD_PROGRAM=/usr/local/bin/browserpool
OLD_SUDOERS=/etc/sudoers.d/browserpool
BASE=/srv/browsers
UNITS=(
  browser-xvfb@.service
  browser-chrome@.service
  browser-cdp-proxy@.service
  browser-slot@.service
  browser-golden-xvfb.service
  browser-golden-chrome.service
  browser-golden-vnc.service
  browser-golden.service
)

usage() {
  cat <<'EOF'
usage: setup.sh [options]

  --role ROLE          pool or login (env BROWSERMAZE_ROLE). Linux defaults to pool and macOS to
                       login; pool needs Linux, login works on both

The pool role installs the browser pool on this machine:
  --bind ADDRESS       address the CDP ports listen on: 127.0.0.1 when the agents run on this
                       machine, this machine's own LAN address for agents elsewhere
                       (env POOL_BIND, default 127.0.0.1)
  --slots N            number of slots, 1 to 9 (env POOL_SLOTS, default 4)
  --caller LOGIN       login that leases slots, created when missing
                       (env POOL_CALLER, default: the user running setup.sh)
  --authorize-key KEY  public key to add to the caller's authorized_keys; repeat for more
                       (env POOL_AUTHORIZE_KEYS, one key per line; an empty value means none)

The login role installs the browsermaze command on your Mac or Linux desktop:
  --pool DESTINATION   where the command runs `browsermaze`: anything ssh accepts, such as
                       user@host or a host alias (env POOL_SSH, no default)
  --ssh-key PATH       ssh identity file for the pool, when ssh's own config names none
                       (env POOL_SSH_KEY, optional)

  --version            print the version
  -h, --help           this text
EOF
}

die() { echo "setup.sh: $*" >&2; exit 1; }
usage_error() { echo "setup.sh: $*" >&2; echo "run setup.sh --help for the options" >&2; exit 2; }

# --- values ----------------------------------------------------------------------------
valid_bind() {  # a dotted IPv4 address; 0.0.0.0 is no address a client can connect to
  local a b c d re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  [[ "$1" =~ $re ]] || return 1
  [ "$1" != 0.0.0.0 ] || return 1
  IFS=. read -r a b c d <<<"$1"
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}
valid_slots() {  # the units name ports 930N and 920N and displays :N, so N is one digit
  [[ "$1" =~ ^[1-9]$ ]]
}
valid_login() {
  local re='^[a-z_][a-z0-9_-]{0,31}$'
  [[ "$1" =~ $re ]] && [ "$1" != root ]
}
valid_destination() {  # anything ssh takes as a destination, but never an option
  local re='^[A-Za-z0-9_][A-Za-z0-9._@:/%+-]*$'
  [[ "$1" =~ $re ]]
}
valid_pubkey() {  # one line: key type, base64 body, optional comment
  local re='^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/=]+( .*)?$'
  [[ "$1" != *"$NL"* ]] && [[ "$1" =~ $re ]]
}
valid_pubkey_or_blank() { [ -z "$1" ] || valid_pubkey "$1"; }
valid_key_path() { [[ "$1" != *"$NL"* ]]; }

render_pool_config() {
  cat <<EOF
# browsermaze pool configuration, written by setup.sh. The pool program and the systemd units
# read it. To change a value, run setup.sh again with the matching flag.
POOL_BIND=$POOL_BIND
POOL_SLOTS=$POOL_SLOTS
POOL_CALLER=$POOL_CALLER
EOF
}
render_login_config() {
  cat <<EOF
# browsermaze command configuration, written by setup.sh. To change a value, run setup.sh
# again with the matching flag.
POOL_SSH=$POOL_SSH
EOF
  [ -z "${POOL_SSH_KEY:-}" ] || echo "POOL_SSH_KEY=$POOL_SSH_KEY"
  return 0
}
render_sudoers() {
  cat <<EOF
# browsermaze: $POOL_CALLER may run the pool program as root and nothing else. The program
# runs itself again through \`sudo -n\` with its full path.
$POOL_CALLER ALL=(root) NOPASSWD: $LIB_PROGRAM
EOF
}

conf_get() {  # file key: the last value of key in a KEY=value file, nothing when absent
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- arguments -------------------------------------------------------------------------
ROLE_FLAG=""
FLAGS_POOL=0
FLAGS_LOGIN=0
need_value() { [ "$1" -ge 2 ] || usage_error "$2 needs a value"; }
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --role)  need_value $# "$1"; ROLE_FLAG="$2"; shift 2 ;;
      --bind)  need_value $# "$1"; POOL_BIND="$2"; FLAGS_POOL=1; shift 2 ;;
      --slots) need_value $# "$1"; POOL_SLOTS="$2"; FLAGS_POOL=1; shift 2 ;;
      --caller) need_value $# "$1"; POOL_CALLER="$2"; FLAGS_POOL=1; shift 2 ;;
      --authorize-key)
        need_value $# "$1"
        POOL_AUTHORIZE_KEYS="${POOL_AUTHORIZE_KEYS-}"
        [ -z "$2" ] || POOL_AUTHORIZE_KEYS="${POOL_AUTHORIZE_KEYS:+$POOL_AUTHORIZE_KEYS$NL}$2"
        FLAGS_POOL=1; shift 2 ;;
      --pool)    need_value $# "$1"; POOL_SSH="$2"; FLAGS_LOGIN=1; shift 2 ;;
      --ssh-key) need_value $# "$1"; POOL_SSH_KEY="$2"; FLAGS_LOGIN=1; shift 2 ;;
      --version) echo "setup.sh $VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
}

# --- questions -------------------------------------------------------------------------
has_terminal() { ( : </dev/tty ) 2>/dev/null; }

ask() {  # header [gum input flags...]; reads the terminal, never stdin
  local header="$1"; shift
  "$BIN/gum" input --header "$header" --width 0 "$@" </dev/tty
}
ask_valid() {  # header validator why [gum input flags...]: asks again until the answer passes
  local header="$1" check="$2" why="$3" answer; shift 3
  while :; do
    answer="$(ask "$header" "$@")" || exit 130  # ctrl-c in the question stops setup.sh
    if "$check" "$answer"; then printf '%s\n' "$answer"; return 0; fi
    echo "   '$answer' will not do: $why" >&2
  done
}
answered() { grep -qx "$1" "$ANSWERED" 2>/dev/null; }
mark_answered() { answered "$1" || echo "$1" >>"$ANSWERED"; }

SETTINGS=""
resolve_setting() {  # variable config-file default validator why header [gum input flags...]
  local var="$1" cfg="$2" default="$3" check="$4" why="$5" header="$6" value src; shift 6
  if [ -n "${!var+x}" ]; then
    value="${!var}"; src="given"
  else
    value="$(conf_get "$cfg" "$var")"; src="remembered in $cfg"
    if [ -z "$value" ]; then
      if has_terminal; then
        value="$(ask_valid "$header" "$check" "$why" --value "$default" "$@")" || exit 130
        src="asked"
      else
        value="$default"; src="default"
      fi
    fi
  fi
  "$check" "$value" || usage_error "$var='$value' will not do: $why"
  printf -v "$var" '%s' "$value"
  SETTINGS="$SETTINGS  $var=$value ($src)$NL"
}

# --- steps -----------------------------------------------------------------------------
CHANGED=0
STEPS_FAILED=0
FAILED=0

# Each step prints "unchanged" when everything was already in place (it returns before touching
# anything), "installed" when it changed something (it calls `changed`), or "FAILED" plus the
# log's tail. A step that fails calls `fix <checklist item> <text>` first; the checklist shows
# that text. A step's stdin is /dev/null, so a package's install script cannot swallow the
# terminal or the rest of a piped script.
run_step() {  # name word function [args...]
  local name="$1" word="$2" rc=0; shift 2
  printf '%-34s ' "$name"
  echo "=== $name" >>"$LOG"
  set +e
  ( set -e; "$@" ) </dev/null >>"$LOG" 2>&1 3>"$WORK/changed"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "FAILED (log: $LOG)"; STEPS_FAILED=$((STEPS_FAILED + 1))
    tail -n 12 "$LOG" | grep -v -e '^FIX ' -e '^=== ' | tail -n 5 | sed 's/^/    /' || true
  elif [ -s "$WORK/changed" ]; then
    echo "installed"; CHANGED=$((CHANGED + 1))
  else
    echo "$word"
  fi
  : >"$WORK/changed"
}
step() { run_step "$1" unchanged "${@:2}"; }
changed() { echo x >&3; }
fix() { printf 'FIX %s\t%s\n' "$1" "$2" >&2; }  # lands in the log; fix_text reads it back
fix_text() { awk -F'\t' -v k="FIX $1" '$1 == k { t = $2 } END { print t }' "$LOG"; }

check() {  # item fix-if-no-step-said command...
  local item="$1" default_fix="$2" text; shift 2
  if ( "$@" ) </dev/null >/dev/null 2>&1; then
    printf '  [ok]   %s\n' "$item"
  else
    text="$(fix_text "$item")"
    printf '  [FAIL] %s\n         fix: %s\n' "$item" "${text:-$default_fix}"
    FAILED=$((FAILED + 1))
  fi
}

# On a network whose IPv6 route is broken, a plain curl can connect over IPv6 and then get no
# data, and wait for it forever. So each try gives up after 30 s below 1 KB/s, and a failed
# first try is followed by one over IPv4 only. `curl -4` affects that one command.
download() {  # url dest
  local bound=(--connect-timeout 30 --speed-limit 1024 --speed-time 30)
  curl -fsSL "${bound[@]}" -o "$2" "$1" && return 0
  echo "download of $1 failed; trying again over IPv4 only" >&2
  curl -4 -fsSL --retry 3 "${bound[@]}" -o "$2" "$1"
}
fetch_verified() {  # url sha256 dest item
  download "$1" "$3" || { fix "$4" "download failed: $1 — check the network, then run setup.sh again"; return 1; }
  local got; got="$(sha256_of "$3")"
  if [ "$got" != "$2" ]; then
    fix "$4" "the download from $1 has sha256 $got, the pin says $2 — do not install it"
    return 1
  fi
}

platform() {  # Linux_x86_64, Linux_arm64, Darwin_x86_64 or Darwin_arm64
  local arch
  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "this machine is $(uname -m); setup.sh supports x86_64 and arm64" ;;
  esac
  echo "$(uname -s)_$arch"
}

gum_ok() { [ -x "$BIN/gum" ] && [ "$("$BIN/gum" --version | cut -d' ' -f3)" = "v$GUM_VERSION" ]; }
step_gum() {
  gum_ok && return 0
  local plat pin sum="" asset
  plat="$(platform)"
  for pin in "${GUM_PINS[@]}"; do
    case "$pin" in "$plat "*) sum="${pin#* }" ;; esac
  done
  [ -n "$sum" ] || { fix gum "no gum pin for $plat"; return 1; }
  asset="gum_${GUM_VERSION}_$plat"
  fetch_verified "$GUM_URL_BASE/$asset.tar.gz" "$sum" "$WORK/gum.tar.gz" gum
  tar -xzf "$WORK/gum.tar.gz" -C "$WORK"
  install -m 755 "$WORK/$asset/gum" "$BIN/gum"
  changed
}

# --- Linux: helpers --------------------------------------------------------------------
as_root() { "${SUDO[@]}" "$@"; }

apt_installed() { [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ]; }
apt_update_once() {  # steps run in subshells, so the marker is a file
  [ -e "$WORK/apt-updated" ] && return 0
  as_root apt-get update -q
  touch "$WORK/apt-updated"
}

ensure_dir() {  # mode owner group path
  [ "$(as_root stat -c %U:%G:%a "$4" 2>/dev/null)" = "$2:$3:$1" ] && return 0
  as_root install -d -m "$1" -o "$2" -g "$3" "$4"
  changed
}
WROTE=0
write_root_file() {  # dest mode, content on stdin: root-owned; sets WROTE=1 when it wrote
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp "$WORK/file.XXXXXX")"
  cat >"$tmp"
  if as_root test -f "$dest" && as_root cmp -s "$tmp" "$dest" \
    && [ "$(as_root stat -c %U:%G:%a "$dest")" = "root:root:$mode" ]; then
    return 0
  fi
  as_root install -D -m "$mode" -o root -g root "$tmp" "$dest"
  WROTE=1
  changed
}

version_is() {  # expected command...: the command prints exactly the expected line
  local want="$1"; shift
  [ "$("$@")" = "$want" ]
}
old_pool_gone() { ! as_root test -e "$OLD_PROGRAM" && ! as_root test -e "$OLD_SUDOERS"; }
has_line() {  # file line: the file holds exactly this line
  grep -qxF -- "$2" "$1"
}
stat_is() {  # stat-format path expected
  [ "$(stat -c "$1" "$2")" = "$3" ]
}
pool_config_ok() {  # the file holds exactly the settings this run resolved, and this version
  [ "$(grep -c '^POOL_' "$POOL_CONFIG")" = 3 ] \
    && has_line "$POOL_CONFIG" "POOL_BIND=$POOL_BIND" \
    && has_line "$POOL_CONFIG" "POOL_SLOTS=$POOL_SLOTS" \
    && has_line "$POOL_CONFIG" "POOL_CALLER=$POOL_CALLER"
}

address_is_local() {  # an address of this machine, or in 127.0.0.0/8
  local a
  case "$1" in 127.*) return 0 ;; esac
  for a in $(hostname -I); do [ "$a" = "$1" ] && return 0; done
  return 1
}

# --- Linux: steps ----------------------------------------------------------------------
step_prereqs() {  # what the steps below download and verify with; not pinned
  local missing=() p
  for p in "${APT_PREREQS[@]}"; do apt_installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  apt_update_once
  as_root apt-get install -y -q --no-install-recommends "${missing[@]}" \
    || { fix prereqs "run: sudo apt-get install ${missing[*]}"; return 1; }
  changed
}

step_config() {
  ensure_dir 755 root root "$(dirname "$POOL_CONFIG")"
  write_root_file "$POOL_CONFIG" 644 <<<"$(render_pool_config)"
}

step_chrome_repo() {
  local repo_changed=0
  if ! as_root test -f "$CHROME_KEYRING"; then
    download "$CHROME_KEY_URL" "$WORK/chrome.pub" \
      || { fix google-chrome-stable "download failed: $CHROME_KEY_URL — check the network, then run setup.sh again"; return 1; }
    mkdir -m 700 "$WORK/gnupg"
    GNUPGHOME="$WORK/gnupg" gpg --dearmor <"$WORK/chrome.pub" >"$WORK/chrome.gpg"
    as_root install -m 644 -o root -g root "$WORK/chrome.gpg" "$CHROME_KEYRING"
    repo_changed=1
    changed
  fi
  WROTE=0
  write_root_file "$CHROME_LIST" 644 <<<"$CHROME_REPO_LINE"
  if [ "$repo_changed" = 1 ] || [ "$WROTE" = 1 ]; then
    rm -f "$WORK/apt-updated"
    apt_update_once
  fi
}

step_packages() {
  local missing=() p
  for p in "${APT_PACKAGES[@]}"; do apt_installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  apt_update_once
  as_root apt-get install -y -q --no-install-recommends "${missing[@]}" || {
    for p in "${missing[@]}"; do fix "$p" "run: sudo apt-get install --no-install-recommends $p"; done
    return 1
  }
  changed
}

# The service account every slot and the golden profile run as. Its home is /var/lib/browser and
# must be writable: Chrome's launcher writes ~/.local and its crash handler needs a database
# under ~/.config, and Chrome dies with SIGTRAP at start when it cannot.
step_account() {
  if id browser >/dev/null 2>&1; then
    if [ "$(getent passwd browser | cut -d: -f6)" != /var/lib/browser ]; then
      as_root usermod -d /var/lib/browser browser
      changed
    fi
  else
    as_root adduser --system --group --no-create-home --home /var/lib/browser \
      --shell /usr/sbin/nologin browser
    changed
  fi
  ensure_dir 750 browser browser /var/lib/browser
}

# $BASE itself stays root:root 755 so videos/ can be world-readable for a plain `scp`, while
# golden, slots, leases and recordings, which hold or gate every imported login, stay 750
# browser:browser. The pool program always runs as root or the browser account (it runs itself
# again through sudo -n), so this is a real boundary.
step_dirs() {
  local n
  ensure_dir 755 root root "$BASE"
  ensure_dir 750 browser browser "$BASE/golden"
  ensure_dir 750 browser browser "$BASE/slots"
  for n in $(seq 1 "$POOL_SLOTS"); do ensure_dir 750 browser browser "$BASE/slots/$n"; done
  ensure_dir 750 browser browser "$BASE/leases"
  ensure_dir 750 browser browser "$BASE/recordings"
  ensure_dir 755 browser browser "$BASE/videos"
}

step_program() {  # the browsermaze command, the pool program and the systemd units
  local u
  WROTE=0
  ensure_dir 755 root root "$LIB"
  write_root_file "$LIB/browsermaze" 755 <"$DIR/browsermaze"
  write_root_file "$LIB/VERSION" 644 <"$DIR/VERSION"
  write_root_file "$LIB_PROGRAM" 755 <"$DIR/pool/browsermaze-pool"
  if [ "$(as_root readlink /usr/local/bin/browsermaze 2>/dev/null)" != "$LIB/browsermaze" ]; then
    as_root ln -sfn "$LIB/browsermaze" /usr/local/bin/browsermaze
    changed
  fi
  if as_root test -e "$OLD_PROGRAM"; then as_root rm -f "$OLD_PROGRAM"; changed; fi
  for u in "${UNITS[@]}"; do write_root_file "/etc/systemd/system/$u" 644 <"$DIR/pool/systemd/$u"; done
  [ "$WROTE" = 0 ] || as_root systemctl daemon-reload
}

caller_home() { getent passwd "$POOL_CALLER" | cut -d: -f6; }
step_caller() {  # the login, and the public keys that may use it
  local home group file key
  if ! id "$POOL_CALLER" >/dev/null 2>&1; then
    as_root adduser --disabled-password --gecos '' "$POOL_CALLER"
    changed
  fi
  [ -n "${POOL_AUTHORIZE_KEYS:-}" ] || return 0
  home="$(caller_home)"; group="$(id -gn "$POOL_CALLER")"; file="$home/.ssh/authorized_keys"
  ensure_dir 700 "$POOL_CALLER" "$group" "$home/.ssh"
  if ! as_root test -f "$file"; then
    as_root install -m 600 -o "$POOL_CALLER" -g "$group" /dev/null "$file"
    changed
  fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    as_root grep -qxF -- "$key" "$file" && continue
    [ -z "$(as_root tail -c 1 "$file")" ] || echo | as_root tee -a "$file" >/dev/null
    printf '%s\n' "$key" | as_root tee -a "$file" >/dev/null
    changed
  done <<<"$POOL_AUTHORIZE_KEYS"
}

# A sudoers file with a syntax error breaks sudo for every user, so the file is checked as a
# root-owned copy before it goes into /etc/sudoers.d.
step_sudoers() {
  local candidate="$WORK/sudoers.check"
  render_sudoers >"$WORK/sudoers.draft"
  as_root install -m 440 -o root -g root "$WORK/sudoers.draft" "$candidate"
  as_root visudo -cf "$candidate" \
    || { fix "sudo rule" "setup.sh wrote a sudoers file that visudo rejects (see the log); nothing was installed"; return 1; }
  write_root_file "$SUDOERS_FILE" 440 <"$WORK/sudoers.draft"
  if as_root test -e "$OLD_SUDOERS"; then as_root rm -f "$OLD_SUDOERS"; changed; fi
}

# Leases a slot as the caller (which also proves the sudo rule), fetches the slot's CDP
# endpoint, and releases the slot.
step_smoke() {
  local out n url rc=0 as_caller=(runuser -u "$POOL_CALLER" --)
  out="$(as_root "${as_caller[@]}" /usr/local/bin/browsermaze lease)" \
    || { fix "smoke test" "run as $POOL_CALLER: browsermaze lease   (the log has its error); then run setup.sh again"; return 1; }
  echo "lease printed: $out"
  read -r n url <<<"$out"
  [[ "$n" =~ ^[1-9]$ ]] || { fix "smoke test" "browsermaze lease printed an unexpected line: $out"; return 1; }
  curl -fsS --max-time 15 --retry 5 --retry-connrefused --retry-delay 1 "$url/json/version" >"$WORK/version.json" || rc=1
  as_root "${as_caller[@]}" /usr/local/bin/browsermaze release "$n" || rc=1
  if [ $rc -ne 0 ] || ! grep -q '"Browser"' "$WORK/version.json"; then
    fix "smoke test" "$url/json/version did not answer from this machine; check that $POOL_BIND is this machine's address, then run setup.sh again"
    return 1
  fi
  touch "$WORK/smoke-ok"
}

# --- Linux: role -----------------------------------------------------------------------
linux_preconditions() {
  platform >/dev/null
  grep -qE '^VERSION_ID="(24\.04|26\.04)"' /etc/os-release 2>/dev/null \
    || die "this expects Ubuntu 24.04 or 26.04; /etc/os-release says: $(grep '^PRETTY_NAME' /etc/os-release 2>/dev/null || echo nothing)"
  [ -d /run/systemd/system ] || die "systemd is not running on this machine"
  if [ "$(id -u)" = 0 ]; then
    SUDO=()
  else
    command -v sudo >/dev/null || die "run setup.sh as root, or install sudo"
    SUDO=(sudo)
    if ! sudo -n true 2>/dev/null; then
      has_terminal || die "setup.sh needs root: run it as root, as a user with passwordless sudo, or on a terminal to type the sudo password"
      sudo -v || die "sudo did not accept the password"
    fi
  fi
}

linux_resolve() {
  local default_caller="${SUDO_USER:-$(id -un)}" mem key
  mem="$(awk '/^MemTotal:/ { printf "%d", ($2 + 524288) / 1048576 }' /proc/meminfo)"
  resolve_setting POOL_BIND "$POOL_CONFIG" 127.0.0.1 valid_bind \
    "a dotted IPv4 address of this machine, not 0.0.0.0 (flag --bind)" \
    "Address the CDP ports listen on: 127.0.0.1 when the agents run on this machine, this machine's own LAN address when they run elsewhere"
  resolve_setting POOL_SLOTS "$POOL_CONFIG" 4 valid_slots \
    "a number from 1 to 9 (flag --slots)" \
    "Number of slots (1-9), each one Chrome. This machine has $(nproc) CPUs and $mem GiB of memory"
  resolve_setting POOL_CALLER "$POOL_CONFIG" "$default_caller" valid_login \
    "a lower-case login name other than root (flag --caller)" \
    "Login that leases slots (created when missing)"
  if [ -z "${POOL_AUTHORIZE_KEYS+x}" ]; then
    POOL_AUTHORIZE_KEYS=""
    if ! answered authorize-keys && has_terminal; then
      POOL_AUTHORIZE_KEYS="$(ask_valid "Public key allowed to log in as $POOL_CALLER (blank: none; add more with --authorize-key)" \
        valid_pubkey_or_blank "an ssh public key line, such as ssh-ed25519 AAAA... (flag --authorize-key)")" || exit 130
      mark_answered authorize-keys
    fi
  fi
  while IFS= read -r key; do
    [ -z "$key" ] || valid_pubkey "$key" || usage_error "--authorize-key: not an ssh public key line"
  done <<<"$POOL_AUTHORIZE_KEYS"
  address_is_local "$POOL_BIND" || usage_error "POOL_BIND=$POOL_BIND is not an address of this machine (hostname -I lists them)"
}

pool_role() {
  linux_preconditions
  step "prereqs" step_prereqs
  if has_terminal; then step "gum $GUM_VERSION" step_gum; fi
  linux_resolve
  printf 'Settings (config file %s):\n%s' "$POOL_CONFIG" "$SETTINGS"
  step "config file" step_config
  step "Google Chrome apt repository" step_chrome_repo
  step "apt packages" step_packages
  step "account browser" step_account
  step "directories $BASE" step_dirs
  step "browsermaze and systemd units" step_program
  step "login $POOL_CALLER" step_caller
  step "sudo rule $SUDOERS_FILE" step_sudoers
  if [ "$STEPS_FAILED" -eq 0 ]; then
    run_step "smoke test" passed step_smoke
  else
    echo "smoke test                         skipped: a step above failed"
  fi

  echo
  echo "Checklist"
  local p u key
  check "config" "run setup.sh again and read $LOG" pool_config_ok
  for p in "${APT_PACKAGES[@]}"; do check "$p" "run: sudo apt-get install --no-install-recommends $p" apt_installed "$p"; done
  check "account browser" "run setup.sh again and read $LOG" id browser
  check "$BASE/golden (750 browser:browser)" "run setup.sh again and read $LOG" stat_is %U:%G:%a "$BASE/golden" browser:browser:750
  check "$BASE/videos (755, readable for scp)" "run setup.sh again and read $LOG" stat_is %a "$BASE/videos" 755
  check "browsermaze $VERSION" "run setup.sh again and read $LOG" version_is "browsermaze $VERSION" /usr/local/bin/browsermaze version
  check "no 0.3.x pool command or sudo rule" "remove $OLD_PROGRAM and $OLD_SUDOERS" old_pool_gone
  for u in "${UNITS[@]}"; do check "$u" "run setup.sh again and read $LOG" test -f "/etc/systemd/system/$u"; done
  check "login $POOL_CALLER" "run setup.sh again and read $LOG" id "$POOL_CALLER"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    check "key ${key:0:20}... in $POOL_CALLER's authorized_keys" "run setup.sh again with --authorize-key" \
      as_root grep -qxF -- "$key" "$(caller_home)/.ssh/authorized_keys"
  done <<<"$POOL_AUTHORIZE_KEYS"
  check "sudo rule" "run setup.sh again and read $LOG" as_root visudo -cf "$SUDOERS_FILE"
  check "smoke test" "fix the failures above, then run setup.sh again" test -f "$WORK/smoke-ok"

  echo
  if [ "$FAILED" -eq 0 ] && [ "$STEPS_FAILED" -eq 0 ]; then
    echo "All green. Steps that changed something this run: $CHANGED."
    echo "Agents lease a slot with: ssh $POOL_CALLER@<this machine> browsermaze lease"
    echo "Log the golden profile in from your Mac or Linux desktop: run setup.sh there with --role login --pool $POOL_CALLER@<this machine>, then browsermaze login."
  fi
}

# --- login role: steps and role -------------------------------------------------------------
step_login_link() {
  [ "$(readlink "$BIN/browsermaze" 2>/dev/null)" = "$DIR/browsermaze" ] && return 0
  ln -sfn "$DIR/browsermaze" "$BIN/browsermaze"
  changed
}
step_login_config() {
  render_login_config >"$WORK/login-config"
  cmp -s "$WORK/login-config" "$LOGIN_CONFIG" 2>/dev/null && return 0
  mkdir -p "$(dirname "$LOGIN_CONFIG")"
  mv "$WORK/login-config" "$LOGIN_CONFIG"
  changed
}

# The Chrome the browsermaze command will use: CHROME when set, otherwise this OS's usual place.
# The Linux names are the same list as in the browsermaze command.
chrome_path() {
  local name
  if [ -n "${CHROME:-}" ]; then echo "$CHROME"; return 0; fi
  if [ "$(uname -s)" = Darwin ]; then echo "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; return 0; fi
  for name in google-chrome google-chrome-stable chromium chromium-browser; do
    command -v "$name" && return 0
  done
  return 1
}
has_chrome() { local path; path="$(chrome_path)" && [ -x "$path" ]; }
on_path() { [[ ":$PATH:" == *":$BIN:"* ]]; }
pool_answers() {  # the command needs the pool, the caller's sudo rule and the pool program itself
  local ssh=(ssh)
  [ -z "${POOL_SSH_KEY:-}" ] || ssh+=(-i "$POOL_SSH_KEY")
  "${ssh[@]}" -n -o BatchMode=yes -o ConnectTimeout=5 "$POOL_SSH" browsermaze status >>"$LOG" 2>&1
}

login_resolve() {
  resolve_setting POOL_SSH "$LOGIN_CONFIG" "" valid_destination \
    "an ssh destination such as user@host or a host alias (flag --pool)" \
    "The pool's ssh destination: user@host, or a host alias from your ssh config"
  if [ -z "${POOL_SSH_KEY+x}" ]; then POOL_SSH_KEY="$(conf_get "$LOGIN_CONFIG" POOL_SSH_KEY)"; fi
  valid_key_path "$POOL_SSH_KEY" || usage_error "--ssh-key: not a file path"
  [ -z "$POOL_SSH_KEY" ] || SETTINGS="$SETTINGS  POOL_SSH_KEY=$POOL_SSH_KEY$NL"
}

login_role() {
  local gum_first=0
  platform >/dev/null
  if has_terminal; then gum_first=1; step "gum $GUM_VERSION" step_gum; fi  # asking needs gum
  login_resolve
  printf 'Settings (config file %s):\n%s' "$LOGIN_CONFIG" "$SETTINGS"
  [ "$gum_first" = 1 ] || step "gum $GUM_VERSION" step_gum
  step "browsermaze command" step_login_link
  step "config file" step_login_config

  echo
  echo "Checklist"
  check "gum" "run setup.sh again and read $LOG" gum_ok
  check "browsermaze $VERSION" "run setup.sh again and read $LOG" version_is "browsermaze $VERSION" "$BIN/browsermaze" --version
  check "config" "run setup.sh again and read $LOG" has_line "$LOGIN_CONFIG" "POOL_SSH=$POOL_SSH"
  check "Google Chrome" "install Chrome (google.com/chrome), or set CHROME to its path" has_chrome
  check "ssh to $POOL_SSH runs browsermaze" \
    "run: ssh $POOL_SSH browsermaze status   — setup.sh must have run on the pool machine, and this machine's public key must be in the caller login's authorized_keys (pass it there with --authorize-key)" \
    pool_answers
  check "$BIN on PATH" "add it to your shell's PATH" on_path

  echo
  if [ "$FAILED" -eq 0 ] && [ "$STEPS_FAILED" -eq 0 ]; then
    echo "All green. Steps that changed something this run: $CHANGED. Run: browsermaze login"
  fi
}

# --- run -------------------------------------------------------------------------------
main() {
  local role os
  parse_args "$@"
  os="$(uname -s)"
  case "$os" in
    Linux) role=pool ;;
    Darwin) role=login ;;
    *) die "this is $os; setup.sh runs on Linux (pool or login) and macOS (login)" ;;
  esac
  role="${ROLE_FLAG:-${BROWSERMAZE_ROLE:-$role}}"
  case "$role" in
    pool|login) ;;
    *) usage_error "the role is '$role'; it must be pool or login (flag --role)" ;;
  esac
  if [ "$role" = pool ] && [ "$os" != Linux ]; then usage_error "--role pool needs Linux; this is $os"; fi
  if [ "$role" = pool ] && [ "$FLAGS_LOGIN" = 1 ]; then usage_error "--pool and --ssh-key are for the login role (--role login)"; fi
  if [ "$role" = login ] && [ "$FLAGS_POOL" = 1 ]; then usage_error "--bind, --slots, --caller and --authorize-key are for the pool role (--role pool)"; fi

  export PATH="$BIN:$PATH"
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p "$BIN" "$STATE"
  LOG="$STATE/setup-$(date -u +%Y%m%dT%H%M%SZ).log"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  echo "browsermaze setup $VERSION ($role) — log: $LOG"

  if [ "$role" = pool ]; then pool_role; else login_role; fi

  if [ "$FAILED" -ne 0 ] || [ "$STEPS_FAILED" -ne 0 ]; then
    echo "$FAILED checklist item(s) and $STEPS_FAILED step(s) failed; each failed item above names its fix, and the log names each failed step's cause: $LOG"
    echo "Steps that changed something this run: $CHANGED."
    exit 1
  fi
}

# Sourcing this file (the tests do) defines the functions and runs nothing.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
