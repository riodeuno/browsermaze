#!/usr/bin/env bash
# Tests for setup.sh that need no network, no root and no particular OS:
#   - bash -n (and shellcheck, when installed) on every shell file
#   - the version: one source, shown by every entry point
#   - the validators for every answer setup.sh takes
#   - the pool config setup.sh writes parses the way the pool program and systemd read it
#   - the browsermaze command: version, login, and every other subcommand passed to the pool program
#   - the role flag and the wrong-role checks, with the OS faked where a test needs the other one
#   - the Chrome lookup, in setup.sh and in browsermaze, with stub Chrome programs on a made-up PATH
#   - the whole login role against a throwaway HOME, with stub gum, ssh and Chrome
# The pool role installs packages and system files, so it is checked by running setup.sh on a
# Linux machine (a VM), not here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
out="$TEST_ROOT/out"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "  ok  $1"; }
accepts() { "$@" || fail "should accept: $*"; }
rejects() { if "$@"; then fail "should reject: $*"; fi; }
exit_is() {  # wanted status, what: the last status captured in $status
  [ "$status" -eq "$1" ] || fail "$2 (exit $status, wanted $1): $(tail -n 3 "$out" 2>/dev/null)"
}
says() {  # text what: the last output holds the text
  grep -qF -- "$1" "$out" || fail "$2 (no '$1' in the output)"
}
no_tty() {  # run a command in a new session, so /dev/tty cannot be opened and nothing is asked
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
}

echo "syntax"
for f in setup.sh browsermaze test_setup.sh; do
  bash -n "$SCRIPT_DIR/$f" || fail "bash -n $f"
done
ok "bash -n setup.sh browsermaze test_setup.sh"
if command -v shellcheck >/dev/null; then
  shellcheck "$SCRIPT_DIR/setup.sh" "$SCRIPT_DIR/browsermaze" "$SCRIPT_DIR/test_setup.sh" || fail "shellcheck"
  ok "shellcheck"
else
  echo "  skip shellcheck (not installed)"
fi

# Sourcing setup.sh defines its functions and runs nothing.
HOME="$TEST_ROOT/source-home" . "$SCRIPT_DIR/setup.sh"

echo "version"
semver='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$VERSION" =~ $semver ]] || fail "VERSION is '$VERSION', not major.minor.patch"
[ "$(wc -l <"$SCRIPT_DIR/VERSION" | tr -d ' ')" = 1 ] || fail "VERSION is not one line"
grep -q "^## $VERSION " "$SCRIPT_DIR/CHANGELOG.md" || fail "CHANGELOG.md has no entry for $VERSION"
[ "$(bash "$SCRIPT_DIR/setup.sh" --version)" = "setup.sh $VERSION" ] || fail "setup.sh --version"
[ "$("$SCRIPT_DIR/browsermaze" --version)" = "browsermaze $VERSION" ] || fail "browsermaze --version"
[ "$("$SCRIPT_DIR/browsermaze" version)" = "browsermaze $VERSION" ] || fail "browsermaze version"
ln -s "$SCRIPT_DIR/browsermaze" "$TEST_ROOT/linked"
[ "$("$TEST_ROOT/linked" version)" = "browsermaze $VERSION" ] || fail "browsermaze version through a link"
ok "setup.sh and browsermaze print $VERSION, the version in VERSION and CHANGELOG.md"

echo "validators"
accepts valid_bind 127.0.0.1
accepts valid_bind 192.0.2.7
accepts valid_bind 10.0.0.255
for v in 0.0.0.0 256.1.1.1 1.2.3 1.2.3.4.5 "1.2.3.4 " abc ""; do rejects valid_bind "$v"; done
ok "bind address"
for v in 1 4 9; do accepts valid_slots "$v"; done
for v in 0 10 a "" -1 "4 "; do rejects valid_slots "$v"; done
ok "slot count"
for v in alice _svc a-b agent01; do accepts valid_login "$v"; done
for v in root Alice "" "a b" -x 1abc "a;b" "a\$b"; do rejects valid_login "$v"; done
ok "caller login"
for v in alice@192.0.2.7 lima-autonomouse host.example.com ssh://u@h:22 pool_1; do accepts valid_destination "$v"; done
for v in -oProxyCommand=x "a b" "" "a;b" "a\$(x)" "\`x\`"; do rejects valid_destination "$v"; done
ok "ssh destination"
body="AAAAC3NzaC1lZDI1NTE5AAAAIEexampleexampleexampleexampleexample"
accepts valid_pubkey "ssh-ed25519 $body"
accepts valid_pubkey "ssh-ed25519 $body worker@host"
accepts valid_pubkey "ecdsa-sha2-nistp256 $body"
accepts valid_pubkey_or_blank ""
two_lines="ssh-ed25519 $body${NL}ssh-ed25519 $body"
for v in "" "ssh-ed25519" "$body" "ssh-dss $body" "command=\"x\" ssh-ed25519 $body" "$two_lines"; do rejects valid_pubkey "$v"; done
ok "public key"

echo "pool config"
POOL_BIND=192.0.2.7 POOL_SLOTS=6 POOL_CALLER=alice
render_pool_config >"$TEST_ROOT/pool-config"
[ "$(conf_get "$TEST_ROOT/pool-config" POOL_SLOTS)" = 6 ] || fail "conf_get did not read POOL_SLOTS back"
# systemd's EnvironmentFile takes comments and bare KEY=value lines; this checks nothing else is in it.
if grep -vE '^(#.*|[A-Z_]+=[^[:space:]]*)$' "$TEST_ROOT/pool-config"; then fail "pool config has a line systemd would not read as KEY=value"; fi
ok "the config holds only comments and KEY=value lines"
python3 -I - "$SCRIPT_DIR/pool/browsermaze-pool" "$TEST_ROOT/pool-config" <<'PYEOF' || fail "the pool program did not read the config"
import importlib.machinery, importlib.util, pathlib, sys, types
sys.dont_write_bytecode = True
sys.modules["websockets"] = types.ModuleType("websockets")  # the pool program imports it at the top; this test never connects
loader = importlib.machinery.SourceFileLoader("browsermaze_pool", sys.argv[1])
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("browsermaze_pool", loader))
loader.exec_module(module)
module.CONFIG_PATH = pathlib.Path(sys.argv[2])
module.load_config()
assert module.BIND_ADDRESS == "192.0.2.7", module.BIND_ADDRESS
assert module.SLOT_COUNT == 6, module.SLOT_COUNT
PYEOF
ok "the pool program reads POOL_BIND and POOL_SLOTS"
POOL_CALLER=alice render_sudoers | grep -qxF 'alice ALL=(root) NOPASSWD: /usr/local/lib/browsermaze/browsermaze-pool' || fail "sudoers rule"
[ "$(POOL_CALLER=alice render_sudoers | grep -vc '^#')" = 1 ] || fail "sudoers file holds more than the one rule"
ok "sudoers holds the one rule, naming the pool program's own path"

unset CHROME BROWSERMAZE_ROLE BROWSERMAZE_CONFIG BROWSERMAZE_POOL_PROGRAM  # the tests set what they need

echo "arguments"
# as_os OS command...: run the command with `uname -s` answering OS, to test the other OS's branch.
# The command may be a function of this file; a child bash gets uname through the environment.
as_os() {
  local FAKE_OS="$1"; shift
  (
    export FAKE_OS  # the function below runs in child processes too
    # shellcheck disable=SC2329  # called by chrome_path, setup.sh and browsermaze
    uname() { if [ "${1:-}" = -s ]; then echo "$FAKE_OS"; else command uname "$@"; fi; }
    export -f uname
    "$@"
  )
}
status=0; bash "$SCRIPT_DIR/setup.sh" --help >"$out" 2>&1 || status=$?
exit_is 0 "--help"; says "usage: setup.sh" "--help"; says "--role ROLE" "--help"; says "BROWSERMAZE_ROLE" "--help"
status=0; bash "$SCRIPT_DIR/setup.sh" --nonsense >"$out" 2>&1 || status=$?
exit_is 2 "an unknown flag"
status=0; bash "$SCRIPT_DIR/setup.sh" --pool >"$out" 2>&1 || status=$?
exit_is 2 "a flag without a value"; says "--pool needs a value" "a flag without a value"
ok "--help, an unknown flag, a flag without a value"

echo "role"
status=0; bash "$SCRIPT_DIR/setup.sh" --role >"$out" 2>&1 || status=$?
exit_is 2 "--role without a value"; says "--role needs a value" "--role without a value"
status=0; bash "$SCRIPT_DIR/setup.sh" --role nonsense >"$out" 2>&1 || status=$?
exit_is 2 "a bad role"; says "must be pool or login" "a bad role"
status=0; BROWSERMAZE_ROLE=nonsense bash "$SCRIPT_DIR/setup.sh" >"$out" 2>&1 || status=$?
exit_is 2 "a bad role in the environment"; says "must be pool or login" "a bad role in the environment"
ok "a missing or unknown role exits 2"
status=0; as_os Darwin bash "$SCRIPT_DIR/setup.sh" --role pool >"$out" 2>&1 || status=$?
exit_is 2 "the pool role on macOS (flag)"; says "--role pool needs Linux" "the pool role on macOS (flag)"
status=0; BROWSERMAZE_ROLE=pool as_os Darwin bash "$SCRIPT_DIR/setup.sh" >"$out" 2>&1 || status=$?
exit_is 2 "the pool role on macOS (environment)"; says "--role pool needs Linux" "the pool role on macOS (environment)"
ok "the pool role on macOS exits 2"
# On Linux the default is the pool role, so login-only flags are wrong there; --role login makes
# them right and the pool-only flags wrong. Each exits 2 before anything is installed.
status=0; as_os Linux bash "$SCRIPT_DIR/setup.sh" --pool x >"$out" 2>&1 || status=$?
exit_is 2 "a login flag on the default Linux role"; says "are for the login role" "a login flag on the default Linux role"
status=0; as_os Linux bash "$SCRIPT_DIR/setup.sh" --role pool --ssh-key x >"$out" 2>&1 || status=$?
exit_is 2 "a login flag on the pool role"; says "are for the login role" "a login flag on the pool role"
status=0; as_os Linux bash "$SCRIPT_DIR/setup.sh" --role login --bind 127.0.0.1 >"$out" 2>&1 || status=$?
exit_is 2 "a pool flag on the login role"; says "are for the pool role" "a pool flag on the login role"
status=0; as_os Darwin bash "$SCRIPT_DIR/setup.sh" --bind 127.0.0.1 >"$out" 2>&1 || status=$?
exit_is 2 "a pool flag on the default macOS role"; says "are for the pool role" "a pool flag on the default macOS role"
ok "the wrong-role checks follow the role, not the OS"

echo "browsermaze command"
# browsermaze runs with only $bm/tools on its PATH, so no real Chrome, gum, ssh or curl on this
# machine takes part. gum, ssh and curl are stubs that let `login` get as far as launching Chrome.
bm="$TEST_ROOT/bm"; mkdir -p "$bm/tools" "$bm/home"
for t in env bash cat dirname sed tail seq sleep; do ln -s "$(command -v "$t")" "$bm/tools/$t"; done
cat >"$bm/tools/gum" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  style) printf '%s\n' "${@: -1}" ;;
  spin) while [ "$1" != -- ]; do shift; done; shift; exec "$@" ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' >"$bm/tools/ssh"
printf '#!/bin/sh\nexit 22\n' >"$bm/tools/curl"
chmod +x "$bm/tools/gum" "$bm/tools/ssh" "$bm/tools/curl"
echo 'POOL_SSH=stub-pool' >"$bm/config"
run_bm() {  # OS args...: browsermaze, as seen on that OS
  local os="$1"; shift
  HOME="$bm/home" BROWSERMAZE_CONFIG="$bm/config" PATH="$bm/tools" as_os "$os" "$bm/tools/bash" "$SCRIPT_DIR/browsermaze" "$@" >"$out" 2>&1 || status=$?
}
status=0; run_bm Linux version
exit_is 0 "browsermaze version"; says "browsermaze $VERSION" "browsermaze version"
status=0; run_bm Linux --version
exit_is 0 "browsermaze --version"; says "browsermaze $VERSION" "browsermaze --version"
status=0; run_bm Linux
exit_is 2 "browsermaze with no subcommand"; says "usage: browsermaze" "browsermaze with no subcommand"
status=0; run_bm Linux help
exit_is 0 "browsermaze help"; says "login" "browsermaze help"
status=0; run_bm Linux login extra
exit_is 2 "browsermaze login with an argument"
ok "version works without a pool; no subcommand or a stray argument exits 2"
status=0; BROWSERMAZE_POOL_PROGRAM="$bm/absent" run_bm Linux lease
exit_is 1 "a pool subcommand on a machine without the pool"; says "this machine is not a pool" "a pool subcommand without the pool"
ok "a pool subcommand on a machine without the pool says so and exits 1"
{ echo '#!/bin/sh'; echo "echo \"\$*\" >'$bm/pool.args'"; echo "exit \"\${STUB_POOL_RC:-0}\""; } >"$bm/pool-program"
chmod +x "$bm/pool-program"
for args in "lease" "release 3" "record start 2" "record stop 2" "status" "logins" "golden import" "golden start" "golden stop"; do
  rm -f "$bm/pool.args"; status=0
  # shellcheck disable=SC2086  # the words of $args are separate arguments
  BROWSERMAZE_POOL_PROGRAM="$bm/pool-program" run_bm Linux $args
  exit_is 0 "browsermaze $args"
  [ "$(cat "$bm/pool.args")" = "$args" ] || fail "browsermaze $args passed on '$(cat "$bm/pool.args" 2>/dev/null)'"
done
status=0; STUB_POOL_RC=7 BROWSERMAZE_POOL_PROGRAM="$bm/pool-program" run_bm Linux lease
exit_is 7 "the pool program's exit status"
ok "every pool subcommand reaches the pool program with its arguments, and its exit status comes back"

echo "chrome lookup"
chrome_dir() {  # name...: a new directory holding a stub program for each name
  local d n; d="$(mktemp -d "$TEST_ROOT/chrome.XXXXXX")"
  for n in "$@"; do printf '#!/bin/sh\n' >"$d/$n"; chmod +x "$d/$n"; done
  echo "$d"
}
empty="$(chrome_dir)"
first_of() {  # OS dir: chrome_path with CHROME unset and PATH only dir
  PATH="$2" as_os "$1" chrome_path
}
want="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ "$(first_of Darwin "$empty")" = "$want" ] || fail "macOS does not keep the /Applications path"
[ "$(CHROME=/opt/c as_os Darwin chrome_path)" = /opt/c ] || fail "CHROME did not win on macOS"
[ "$(CHROME=/opt/c as_os Linux chrome_path)" = /opt/c ] || fail "CHROME did not win on Linux"
if first_of Linux "$empty" >/dev/null; then fail "Linux found a Chrome on an empty PATH"; fi
names=(google-chrome google-chrome-stable chromium chromium-browser)
for i in 0 1 2 3; do  # with the names from i on present, the one at i wins
  d="$(chrome_dir "${names[@]:$i}")"
  [ "$(first_of Linux "$d")" = "$d/${names[$i]}" ] || fail "Linux picked $(first_of Linux "$d"), wanted ${names[$i]}"
done
ok "setup.sh: CHROME, else the /Applications path on macOS, else the first of ${names[*]} on Linux"

# browsermaze login, as far as it launches Chrome: the stub Chrome writes its own path to a file
# and exits, so the run ends with "Chrome exited before it opened".
stub_chrome() {  # dir name: a Chrome stub that records which one ran
  { echo '#!/bin/sh'; echo "echo \"\$0\" >'$bm/launched'"; } >"$1/$2"; chmod +x "$1/$2"
}
login_with() {  # dir OS: browsermaze login with dir first on PATH and CHROME as the caller set it
  rm -f "$bm/launched"
  HOME="$bm/home" BROWSERMAZE_CONFIG="$bm/config" PATH="$1:$bm/tools" as_os "$2" "$bm/tools/bash" "$SCRIPT_DIR/browsermaze" login >"$out" 2>&1 || status=$?
}
for i in 0 1 2 3; do
  d="$(mktemp -d "$TEST_ROOT/chrome.XXXXXX")"
  for n in "${names[@]:$i}"; do stub_chrome "$d" "$n"; done
  status=0; login_with "$d" Linux
  exit_is 1 "browsermaze login with a stub ${names[$i]}"; says "Chrome exited before it opened" "browsermaze login with a stub ${names[$i]}"
  [ "$(cat "$bm/launched")" = "$d/${names[$i]}" ] || fail "browsermaze launched $(cat "$bm/launched"), wanted ${names[$i]}"
done
status=0; login_with "$empty" Linux
exit_is 1 "browsermaze login with no Chrome on Linux"; says "Chrome not found. Install Chrome" "browsermaze login with no Chrome on Linux"
d="$(mktemp -d "$TEST_ROOT/chrome.XXXXXX")"; stub_chrome "$d" google-chrome; stub_chrome "$d" mine
status=0; CHROME="$d/mine" login_with "$d" Linux
[ "$(cat "$bm/launched")" = "$d/mine" ] || fail "CHROME did not win over google-chrome on PATH"
status=0; CHROME="$d/absent" login_with "$d" Linux
exit_is 1 "CHROME naming a missing file"; says "Chrome not found at $d/absent" "CHROME naming a missing file"
ok "browsermaze: CHROME, else the first of ${names[*]} on Linux; a miss says what to do"

echo "login role"
home="$TEST_ROOT/home"; stubs="$TEST_ROOT/stubs"; mkdir -p "$home/.local/bin" "$stubs"
config="$home/.config/browsermaze/config"
# gum is already in place at the pinned version, so no download runs.
{ echo '#!/bin/sh'; echo "[ \"\$1\" = --version ] && echo 'gum version v$GUM_VERSION'"; } >"$home/.local/bin/gum"
{ echo '#!/bin/sh'; echo "echo \"\$*\" >'$TEST_ROOT/ssh.args'"; echo "exit \"\${STUB_SSH_RC:-0}\""; } >"$stubs/ssh"
echo '#!/bin/sh' >"$TEST_ROOT/chrome"
chmod +x "$home/.local/bin/gum" "$stubs/ssh" "$TEST_ROOT/chrome"
: >"$TEST_ROOT/key"
run_setup() {
  HOME="$home" CHROME="$TEST_ROOT/chrome" PATH="$stubs:$home/.local/bin:$PATH" no_tty bash "$SCRIPT_DIR/setup.sh" "$@"
}
run_login() { run_setup --role login "$@"; }

status=0; run_login --pool lima-test --ssh-key "$TEST_ROOT/key" >"$out" 2>&1 || status=$?
cat "$out"
exit_is 0 "setup with a good pool"
[ "$(readlink "$home/.local/bin/browsermaze")" = "$SCRIPT_DIR/browsermaze" ] || fail "command not linked"
[ "$("$home/.local/bin/browsermaze" version)" = "browsermaze $VERSION" ] || fail "the installed command does not print the version"
grep -qxF 'POOL_SSH=lima-test' "$config" || fail "config lacks POOL_SSH"
grep -qxF "POOL_SSH_KEY=$TEST_ROOT/key" "$config" || fail "config lacks POOL_SSH_KEY"
says "(login)" "the run does not name the login role"
says "[ok]   browsermaze $VERSION" "the checklist does not name the installed version"
says "[ok]   ssh to lima-test runs browsermaze" "the pool check did not pass"
grep -qxF -- "-i $TEST_ROOT/key -n -o BatchMode=yes -o ConnectTimeout=5 lima-test browsermaze status" "$TEST_ROOT/ssh.args" \
  || fail "ssh was called as: $(cat "$TEST_ROOT/ssh.args")"
says "All green" "no All green line"
ok "first run installs the command and writes the config"

status=0; run_login >"$out" 2>&1 || status=$?
exit_is 0 "second run"
says "POOL_SSH=lima-test (remembered" "the second run did not remember the pool"
[ "$(grep -c 'unchanged$' "$out")" -ge 3 ] || fail "the second run changed something"
ok "second run remembers the pool and changes nothing"

status=0; POOL_SSH=from-env run_login >"$out" 2>&1 || status=$?
grep -qxF 'POOL_SSH=from-env' "$config" || fail "the environment variable did not reach the config"
status=0; POOL_SSH=from-env run_login --pool from-flag >"$out" 2>&1 || status=$?
grep -qxF 'POOL_SSH=from-flag' "$config" || fail "the flag did not win over the environment variable"
status=0; BROWSERMAZE_ROLE=nonsense run_setup --role login --pool from-flag >"$out" 2>&1 || status=$?
exit_is 0 "the role flag over the environment variable"; says "(login)" "the role flag over the environment variable"
status=0; BROWSERMAZE_ROLE=login run_setup --pool from-env-role >"$out" 2>&1 || status=$?
exit_is 0 "BROWSERMAZE_ROLE=login"; grep -qxF 'POOL_SSH=from-env-role' "$config" || fail "BROWSERMAZE_ROLE=login did not select the login role"
ok "environment variable, and the flag over it"

status=0; STUB_SSH_RC=255 run_login --pool lima-test >"$out" 2>&1 || status=$?
exit_is 1 "an unreachable pool"
says "[FAIL] ssh to lima-test runs browsermaze" "the unreachable pool was not named"
says "fix: run: ssh lima-test browsermaze status" "the unreachable pool has no fix line"
ok "an unreachable pool fails with a fix line"

status=0; HOME="$TEST_ROOT/empty-home" PATH="$stubs:$PATH" no_tty bash "$SCRIPT_DIR/setup.sh" --role login >"$out" 2>&1 || status=$?
exit_is 2 "no pool and no terminal"; says "--pool" "no pool and no terminal"
[ ! -e "$TEST_ROOT/empty-home/.local/bin/gum" ] || fail "gum was downloaded before the arguments were checked"
status=0; run_login --pool -oProxyCommand=x >"$out" 2>&1 || status=$?
exit_is 2 "a destination that looks like an option"
status=0; run_login --pool x --bind 127.0.0.1 >"$out" 2>&1 || status=$?
exit_is 2 "a pool flag on the login role"; says "are for the pool role" "a pool flag on the login role"
ok "bad arguments exit 2 before anything is installed"

if [ "$(uname -s)" = Darwin ]; then
  # The default role on macOS is login: no --role flag.
  status=0; run_setup --pool mac-default >"$out" 2>&1 || status=$?
  exit_is 0 "macOS without --role"; says "(login)" "macOS without --role"
  grep -qxF 'POOL_SSH=mac-default' "$config" || fail "macOS without --role did not write the config"
  ok "macOS without --role is the login role"
fi

# The login role on Linux, run on this machine with `uname -s` answering Linux. The steps are the
# same as on macOS (link, config, checks); only the Chrome lookup differs. Chrome is found on PATH.
lhome="$TEST_ROOT/linux-home"; mkdir -p "$lhome/.local/bin"
cp "$home/.local/bin/gum" "$lhome/.local/bin/gum"
lchrome="$(chrome_dir)"; stub_chrome "$lchrome" chromium
linux_login() {  # setup.sh args: the login role as Linux, CHROME unset, Chrome only if lchrome holds one
  unset CHROME
  HOME="$lhome" PATH="$stubs:$lhome/.local/bin:$lchrome:$PATH" as_os Linux no_tty bash "$SCRIPT_DIR/setup.sh" --role login "$@"
}
status=0; linux_login --pool lima-test >"$out" 2>&1 || status=$?
cat "$out"
exit_is 0 "the login role on Linux"; says "(login)" "the login role on Linux"
says "[ok]   Google Chrome" "the login role on Linux did not find the Chrome on PATH"
[ "$(readlink "$lhome/.local/bin/browsermaze")" = "$SCRIPT_DIR/browsermaze" ] || fail "Linux: command not linked"
grep -qxF 'POOL_SSH=lima-test' "$lhome/.config/browsermaze/config" || fail "Linux: config lacks POOL_SSH"
says "All green" "Linux: no All green line"
rm "$lchrome/chromium"
if ! command -v google-chrome google-chrome-stable chromium chromium-browser >/dev/null 2>&1; then
  status=0; linux_login >"$out" 2>&1 || status=$?
  exit_is 1 "the login role on Linux without Chrome"; says "[FAIL] Google Chrome" "Linux without Chrome"
  says "fix: install Chrome" "Linux without Chrome has no fix line"
else
  echo "  skip the no-Chrome case (this machine has a Chrome on PATH)"
fi
ok "the login role on Linux: link, config, Chrome found on PATH, and a missing Chrome fails with a fix line"

echo "old name"
# The pool program's old name survives only where it explains the upgrade: setup.sh removes the
# 0.3.x command and sudo rule, and CHANGELOG.md says why.
old='browser[p]ool'
others="$(cd "$SCRIPT_DIR" && grep -rIl "$old" . --exclude-dir=.git | grep -v -e '^\./setup\.sh$' -e '^\./CHANGELOG\.md$' || true)"
[ -z "$others" ] || fail "the old pool program name is still in: $others"
ok "the old pool program name appears only in setup.sh and CHANGELOG.md, where it explains the upgrade"
echo "PASS"
