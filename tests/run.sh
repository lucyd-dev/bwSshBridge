#!/usr/bin/env bash
# Dependency-free test suite for bwssh.  Run: bash tests/run.sh
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { printf 'ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq()            { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
assert_status()        { [ "$2" -eq "$3" ] && ok "$1" || bad "$1 (status $2, want $3)"; }
assert_contains()      { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')" ;; esac; }
assert_not_contains()  { case "$2" in *"$3"*) bad "$1 (unexpected '$3')" ;; *) ok "$1" ;; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export BWSSH_WIN_HOME="$TMP/winhome"
# Force deterministic Windows-ssh capability detection (real probing is exercised
# by hand; here we pin the supported branch so tests do not depend on Windows).
export BWSSH_WIN_UNBOUND=1
export BWSSH_WIN_INCLUDE=1
# Isolate the (tmpfs) session cache from the real user's runtime dir.
export XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$HOME" "$BWSSH_WIN_HOME" "$XDG_RUNTIME_DIR"
bwssh="$ROOT/bwssh"

# --- syntax -----------------------------------------------------------------
for f in "$ROOT/bwssh" "$ROOT"/lib/*.sh "$ROOT"/assets/*.bash; do
  if bash -n "$f" 2>/dev/null; then ok "syntax: ${f#"$ROOT"/}"; else bad "syntax: ${f#"$ROOT"/}"; fi
done

# --- embedSshKey.py ---------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  js="$(printf '%s' '{"type":1,"name":"t","login":{"username":"u"},"notes":null,"reprompt":0}' \
    | BW_SSH_NAME=K BW_SSH_FP=SHA256:x BW_SSH_PRIV=PRIV BW_SSH_PUB=PUB \
      python3 "$ROOT/lib/embedSshKey.py")"
  assert_contains     "embedSshKey sets type 5" "$js" '"type": 5'
  assert_contains     "embedSshKey keeps privateKey" "$js" '"privateKey": "PRIV"'
  assert_contains     "embedSshKey keeps keyFingerprint" "$js" '"keyFingerprint": "SHA256:x"'
  assert_not_contains "embedSshKey drops login" "$js" '"login"'
else
  printf 'skip - python3 not found\n'
fi

# --- ssh config snippet -----------------------------------------------------
if command -v ssh >/dev/null 2>&1; then
  cfg="$TMP/sshconfig"
  cat "$ROOT/config/ssh-config.snippet" > "$cfg"
  g="$(ssh -F "$cfg" -G somehost 2>/dev/null)"
  assert_contains "snippet sets PubkeyAuthentication unbound" "$g" 'pubkeyauthentication unbound'
fi

# --- host management round trip --------------------------------------------
out="$("$bwssh" add-host testsrv host.example.com tester 2222 --alias-only 2>&1)"; rc=$?
assert_status "add-host --alias-only exits 0" "$rc" 0
hosts="$HOME/.ssh/bwSshBridgeHosts.conf"
assert_contains "hosts file created" "$(cat "$hosts" 2>/dev/null)" 'Host testsrv'
assert_contains "host block has HostName" "$(cat "$hosts")" 'HostName host.example.com'
assert_contains "host block has Port" "$(cat "$hosts")" 'Port 2222'
assert_not_contains "alias-only has no IdentityFile" "$(cat "$hosts")" 'IdentityFile'

out="$("$bwssh" add-host testsrv other.example.com x 22 --alias-only 2>&1)"; rc=$?
assert_status "re-adding alias (--alias-only) is idempotent" "$rc" 0

out="$("$bwssh" add-host testsrv other.example.com x 22 2>&1)"; rc=$?
assert_status "duplicate alias with key creation is rejected" "$rc" 1
assert_contains "duplicate error mentions the alias" "$out" 'testsrv'

assert_contains "list-hosts shows alias" "$("$bwssh" list-hosts 2>&1)" 'testsrv'

"$bwssh" remove-host testsrv >/dev/null 2>&1; rc=$?
assert_status "remove-host exits 0" "$rc" 0
assert_not_contains "alias removed from hosts file" "$(cat "$hosts")" 'Host testsrv'

# --- Windows mirror: hosts conf, key pins, ssh config block -----------------
mkdir -p "$BWSSH_WIN_HOME/.ssh"
printf 'Host 10.10.10.24\n    User lucyd\n' > "$BWSSH_WIN_HOME/.ssh/config"
win_dir="$BWSSH_WIN_HOME/.ssh"
win_hosts="$win_dir/bwSshBridgeHosts.conf"
win_config="$win_dir/config"

"$bwssh" add-host winsrv win.example.com tester 22 --alias-only >/dev/null 2>&1
printf 'ssh-ed25519 AAAAwinsrv winsrv\n' > "$HOME/.ssh/winsrv.pub"
chmod 600 "$HOME/.ssh/winsrv.pub"
"$bwssh" sync-hosts --push >/dev/null 2>&1; rc=$?
assert_status "sync-hosts --push exits 0" "$rc" 0
assert_contains "windows hosts mirror written" "$(cat "$win_hosts" 2>/dev/null)" 'Host winsrv'
assert_eq "windows key pin mirrored" "$(cat "$win_dir/winsrv.pub" 2>/dev/null)" 'ssh-ed25519 AAAAwinsrv winsrv'
assert_contains "windows config wrapped by markers" "$(cat "$win_config")" '# >>> bwSshBridge >>>'
assert_contains "windows config includes mirror" "$(cat "$win_config")" "$win_hosts"
assert_contains "windows config sets unbound" "$(cat "$win_config")" 'PubkeyAuthentication unbound'
assert_contains "windows config preserves user entries" "$(cat "$win_config")" 'User lucyd'
assert_not_contains "host block has no per-host unbound" "$(cat "$win_hosts")" 'PubkeyAuthentication unbound'

# idempotency: a second push must not duplicate the marker block or an alias
"$bwssh" sync-hosts --push >/dev/null 2>&1
assert_eq "windows config block not duplicated" "$(grep -c '^# >>> bwSshBridge >>>' "$win_config")" '1'
assert_eq "host alias not duplicated" "$(grep -c '^Host winsrv$' "$win_hosts")" '1'

# restore round trip: drop the WSL file and key pin, import both back from Windows
rm -f "$HOME/.ssh/bwSshBridgeHosts.conf" "$HOME/.ssh/winsrv.pub"
"$bwssh" sync-hosts >/dev/null 2>&1; rc=$?
assert_status "sync-hosts import exits 0" "$rc" 0
assert_contains "restore re-imports hosts" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf" 2>/dev/null)" 'Host winsrv'
assert_contains "restore re-imports key pin" "$(cat "$HOME/.ssh/winsrv.pub" 2>/dev/null)" 'ssh-ed25519 AAAAwinsrv'
assert_eq "restored key pin is mode 600" "$(stat -c '%a' "$HOME/.ssh/winsrv.pub" 2>/dev/null)" '600'

# Include fallback: when Include is unsupported the host entries are inlined
BWSSH_WIN_INCLUDE=0 "$bwssh" sync-hosts --push >/dev/null 2>&1
assert_not_contains "fallback omits Include" "$(cat "$win_config")" 'Include '
assert_contains "fallback inlines host entries" "$(cat "$win_config")" 'Host winsrv'

# remove-host deletes the Windows key pin too
"$bwssh" remove-host winsrv >/dev/null 2>&1; rc=$?
assert_status "remove-host exits 0 (mirror)" "$rc" 0
[ ! -f "$win_dir/winsrv.pub" ] && ok "windows key pin removed" || bad "windows key pin removed"

# --- IdentityFile is normalized to ~ for portability ------------------------
printf '\nHost normhost\n    HostName n.example.com\n    User u\n    Port 22\n    IdentityFile %s/.ssh/normhost.pub\n    IdentitiesOnly yes\n    PubkeyAuthentication unbound\n' "$HOME" >> "$HOME/.ssh/bwSshBridgeHosts.conf"
printf 'ssh-ed25519 AAAAnorm normhost\n' > "$HOME/.ssh/normhost.pub"
chmod 600 "$HOME/.ssh/normhost.pub"
"$bwssh" sync-hosts --push >/dev/null 2>&1
wsl_hosts="$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")"
assert_contains     "WSL file uses tilde IdentityFile" "$wsl_hosts" 'IdentityFile ~/.ssh/normhost.pub'
assert_not_contains "WSL file drops absolute IdentityFile" "$wsl_hosts" "$HOME/.ssh/normhost.pub"
assert_contains     "mirror uses tilde IdentityFile" "$(cat "$win_hosts")" 'IdentityFile ~/.ssh/normhost.pub'
assert_not_contains "per-host unbound stripped on normalize" "$wsl_hosts" 'PubkeyAuthentication unbound'

# --- remove-host --delete-key also deletes the vault item -----------------------
stub3="$TMP/bin-del"; mkdir -p "$stub3"
cat > "$stub3/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "list items")  echo '[{"id":"ITEMID-123","name":"delsrv","type":5},{"id":"ITEMID-456","name":"delsrv","type":5},{"id":"OTHER","name":"delsrv","type":1}]'; exit 0 ;;
  "delete item") printf '%s\n' "$3" >> "$BWSSH_TEST_DELETED"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub3/bw"
printf '\nHost delsrv\n    HostName d.example.com\n    User u\n    IdentityFile ~/.ssh/delsrv.pub\n    IdentitiesOnly yes\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
printf 'ssh-ed25519 AAAAdel delsrv\n' > "$HOME/.ssh/delsrv.pub"
export BWSSH_TEST_DELETED="$TMP/deleted"; : > "$BWSSH_TEST_DELETED"
BW_SESSION=stub PATH="$stub3:$PATH" "$bwssh" remove-host delsrv --delete-key >/dev/null 2>&1; rc=$?
assert_status "remove-host --delete-key exits 0" "$rc" 0
deleted="$(cat "$BWSSH_TEST_DELETED")"
assert_contains     "the vault item id is deleted" "$deleted" 'ITEMID-123'
assert_contains     "duplicate-named item is deleted too" "$deleted" 'ITEMID-456'
assert_not_contains "only SSH-key items are deleted" "$deleted" 'OTHER'
assert_not_contains "delsrv removed from hosts" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")" 'Host delsrv'
unset BWSSH_TEST_DELETED

# --- add-host refuses an alias that already exists in Bitwarden -------------
stub4="$TMP/bin-dup"; mkdir -p "$stub4"
cat > "$stub4/bw" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BWSSH_TEST_BWLOG" 2>/dev/null
case "$1 $2" in
  "list items") echo '[{"id":"X","name":"dupsrv","type":5}]'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub4/bw"
export BWSSH_TEST_BWLOG="$TMP/bwlog"; : > "$BWSSH_TEST_BWLOG"
out="$(BW_SESSION=stub PATH="$stub4:$PATH" "$bwssh" add-host dupsrv h.example.com u 22 2>&1)"; rc=$?
assert_status "add-host fails on duplicate vault item" "$rc" 1
assert_contains "duplicate message says it exists" "$out" 'already exists'
assert_contains "duplicate message mentions the alias" "$out" 'dupsrv'
assert_contains "duplicate message suggests --use-key" "$out" '--use-key'
assert_contains "vault is synced before the lookup" "$(cat "$BWSSH_TEST_BWLOG")" 'sync'
assert_not_contains "duplicate host not added locally" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")" 'Host dupsrv'
unset BWSSH_TEST_BWLOG

# --- add-host --use-key reuses an existing vault key named like the alias -------
stub5="$TMP/bin-pin"; mkdir -p "$stub5"
cat > "$stub5/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "list items") echo '[{"id":"P1","name":"pinsrv","type":5}]'; exit 0 ;;
  "get item")   echo '{"sshKey":{"publicKey":"ssh-ed25519 AAAApin pinsrv"}}'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub5/bw"
BW_SESSION=stub PATH="$stub5:$PATH" "$bwssh" add-host pinsrv p.example.com u 22 --use-key >/dev/null 2>&1; rc=$?
assert_status "add-host --use-key exits 0" "$rc" 0
assert_eq "pinned pubkey written" "$(cat "$HOME/.ssh/pinsrv.pub" 2>/dev/null)" 'ssh-ed25519 AAAApin pinsrv'
assert_contains "pin block has IdentityFile" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")" 'IdentityFile ~/.ssh/pinsrv.pub'

# --use-key with no matching vault key fails
stub6="$TMP/bin-pinmiss"; mkdir -p "$stub6"
cat > "$stub6/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "list items") echo '[]'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub6/bw"
out="$(BW_SESSION=stub PATH="$stub6:$PATH" "$bwssh" add-host nosrv n.example.com u 22 --use-key 2>&1)"; rc=$?
assert_status "add-host --use-key fails without a vault key" "$rc" 1
assert_contains "missing key message" "$out" 'no vault key named'

# --- remove-host keeps sibling aliases on a shared Host line ----------------
printf '\nHost keepme dropme\n    HostName shared.example.com\n    User u\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
"$bwssh" remove-host dropme >/dev/null 2>&1; rc=$?
assert_status "remove-host with a sibling alias exits 0" "$rc" 0
h="$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")"
assert_contains     "sibling alias is kept" "$h" 'Host keepme'
assert_not_contains "removed alias is gone" "$h" 'dropme'
"$bwssh" remove-host keepme >/dev/null 2>&1
assert_not_contains "last alias drops its block" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")" 'shared.example.com'

# --- list-hosts shows target and pin state ----------------------------------
out="$("$bwssh" list-hosts 2>&1)"
assert_contains "list-hosts shows alias" "$out" 'pinsrv'
assert_contains "list-hosts shows target" "$out" 'p.example.com'
assert_contains "list-hosts shows the pinned key" "$out" 'pinsrv.pub'

# --- sync-hosts tolerates a missing Windows home ---------------------------
"$bwssh" sync-hosts --push >/dev/null 2>&1; rc=$?
assert_status "sync-hosts --push tolerant when no Windows home" "$rc" 0

# --- bwssh login survives an already-configured server ----------------------
# `bw config server` exits 1 ("Logout required...") when already logged in;
# login must not abort on it, or the printed session is lost.
stub="$TMP/bin"; mkdir -p "$stub"
cat > "$stub/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "config server") echo "Logout required before server config update." >&2; exit 1 ;;
  "status") echo '{"status":"locked"}'; exit 0 ;;
  "unlock --raw") echo "STUBSESSION"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub/bw"
sess_file="$XDG_RUNTIME_DIR/bwSshBridge/session"
out="$(PATH="$stub:$PATH" "$bwssh" login </dev/null 2>/dev/null)"; rc=$?
assert_status "login survives a failing server config" "$rc" 0
assert_eq "login prints no token" "$out" ''
assert_eq "login caches the session" "$(cat "$sess_file" 2>/dev/null)" 'STUBSESSION'
"$bwssh" lock >/dev/null 2>&1
[ ! -f "$sess_file" ] && ok "lock clears the session cache" || bad "lock clears the session cache"

# a cached session is reused while the vault is unlocked (no re-unlock)...
mkdir -p "$(dirname "$sess_file")"; printf 'CACHED\n' > "$sess_file"; chmod 600 "$sess_file"
stub7="$TMP/bin-sess"; mkdir -p "$stub7"
cat > "$stub7/bw" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BWSSH_TEST_BWLOG"
case "$1 $2" in
  "status ")      echo '{"status":"unlocked"}'; exit 0 ;;
  "unlock --raw") echo 'NEWSESSION'; exit 0 ;;
  "list items")   echo '[{"id":"ID7","name":"sesssrv","type":5}]'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub7/bw"
export BWSSH_TEST_BWLOG="$TMP/bwlog2"; : > "$BWSSH_TEST_BWLOG"
env -u BW_SESSION PATH="$stub7:$PATH" "$bwssh" remove-host sesssrv --delete-key >/dev/null 2>&1; rc=$?
assert_status "cached session is reused (exit 0)" "$rc" 0
assert_contains "cached session used for the delete" "$(cat "$BWSSH_TEST_BWLOG")" 'delete item'
assert_not_contains "no re-unlock while unlocked" "$(cat "$BWSSH_TEST_BWLOG")" 'unlock'

# ...but a stale cache (vault locked) is dropped, not trusted
printf 'STALE\n' > "$sess_file"; chmod 600 "$sess_file"
stub8="$TMP/bin-stale"; mkdir -p "$stub8"
cat > "$stub8/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "status ") echo '{"status":"locked"}'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub8/bw"
env -u BW_SESSION PATH="$stub8:$PATH" "$bwssh" remove-host sesssrv --delete-key </dev/null >/dev/null 2>&1; rc=$?
assert_status "stale session fails cleanly without a TTY" "$rc" 1
[ ! -f "$sess_file" ] && ok "stale session cache dropped" || bad "stale session cache dropped"
unset BWSSH_TEST_BWLOG

# a wrong master password must fail cleanly (no raw crypto stack in stdout)
stub2="$TMP/bin-fail"; mkdir -p "$stub2"
cat > "$stub2/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "config server") exit 0 ;;
  "status") echo '{"status":"locked"}'; exit 0 ;;
  "unlock --raw") echo "ERROR bitwarden_crypto: decryption failed" >&2; exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub2/bw"
out="$(PATH="$stub2:$PATH" "$bwssh" login </dev/null 2>"$TMP/bwfail")"; rc=$?
assert_status "login fails cleanly on wrong password" "$rc" 1
assert_eq "login stdout empty on failure" "$out" ''
assert_not_contains "login hides raw crypto errors" "$(cat "$TMP/bwfail")" 'bitwarden_crypto'
assert_contains "login reports a concise error" "$(cat "$TMP/bwfail")" 'could not unlock'

# --- misc -------------------------------------------------------------------
assert_contains "version prints name" "$("$bwssh" version)" 'bwssh'
"$bwssh" help >/dev/null 2>&1; assert_status "help exits 0" "$?" 0
out="$("$bwssh" nonsense 2>&1)"; rc=$?
assert_status "unknown command fails" "$rc" 1

# --- systemd unit -----------------------------------------------------------
if command -v systemd-analyze >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/bwSshBridgeRelay.sh"
  chmod +x "$HOME/.local/bin/bwSshBridgeRelay.sh"
  tmpl="$(cat "$ROOT/systemd/bwSshBridge.service")"
  printf '%s\n' "${tmpl//__BW_SSH_SOCK__//tmp/bwtest.sock}" > "$TMP/bw.service"
  if systemd-analyze verify "$TMP/bw.service" >/dev/null 2>&1; then
    ok "systemd unit verifies"
  else
    bad "systemd unit verify"
  fi
else
  printf 'skip - systemd-analyze not found\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
