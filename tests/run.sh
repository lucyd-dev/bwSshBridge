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

out="$("$bwssh" add-host testsrv other.example.com x 22 --new-key 2>&1)"; rc=$?
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

printf '\nHost winsrv\n    HostName win.example.com\n    User tester\n    IdentityFile ~/.ssh/winsrv.pub\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
printf 'ssh-ed25519 AAAAwinsrv winsrv\n' > "$HOME/.ssh/winsrv.pub"
chmod 600 "$HOME/.ssh/winsrv.pub"
"$bwssh" sync-hosts --push >/dev/null 2>&1; rc=$?
assert_status "sync-hosts --push exits 0" "$rc" 0
assert_contains "windows hosts mirror written" "$(cat "$win_hosts" 2>/dev/null)" 'Host winsrv'
assert_eq "windows key pin mirrored" "$(cat "$win_dir/winsrv.pub" 2>/dev/null)" 'ssh-ed25519 AAAAwinsrv winsrv'

# alias-only entries do not mirror a same-named .pub
printf '\nHost aliasonly\n    HostName a.example.com\n    User u\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
printf 'ssh-ed25519 AAAAalias aliasonly\n' > "$HOME/.ssh/aliasonly.pub"
chmod 600 "$HOME/.ssh/aliasonly.pub"
"$bwssh" sync-hosts --push >/dev/null 2>&1
[ ! -f "$win_dir/aliasonly.pub" ] && ok "alias-only pub is not mirrored" || bad "alias-only pub is not mirrored"
"$bwssh" remove-host aliasonly >/dev/null 2>&1
rm -f "$HOME/.ssh/aliasonly.pub"

# a private key path is never mirrored or removed (only .pub pins are managed)
printf '\nHost privatepin\n    HostName p.example.com\n    User u\n    IdentityFile ~/.ssh/privatekey\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
printf 'PRIVATE\n' > "$HOME/.ssh/privatekey"
chmod 600 "$HOME/.ssh/privatekey"
"$bwssh" sync-hosts --push >/dev/null 2>&1
[ ! -f "$win_dir/privatekey" ] && ok "private key path is not mirrored" || bad "private key path is not mirrored"
"$bwssh" remove-host privatepin >/dev/null 2>&1
[ -f "$HOME/.ssh/privatekey" ] && ok "private key path is not removed" || bad "private key path is not removed"
rm -f "$HOME/.ssh/privatekey"
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

# --- remove-host --delete-key only deletes the matching vault key -----------
stub3="$TMP/bin-del"; mkdir -p "$stub3"
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/delsrv"
chmod 600 "$HOME/.ssh/delsrv.pub"
cat > "$stub3/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "list items")
    fp="$(ssh-keygen -lf "$HOME/.ssh/delsrv.pub" | awk '{print $2}')"
    printf '[{"id":"ITEMID-123","name":"delsrv","type":5,"sshKey":{"keyFingerprint":"%s"}},{"id":"ITEMID-456","name":"delsrv","type":5,"sshKey":{"keyFingerprint":"%s"}},{"id":"ITEMID-WRONG","name":"delsrv","type":5,"sshKey":{"keyFingerprint":"SHA256:wrong"}},{"id":"OTHER","name":"delsrv","type":1}]\n' "$fp" "$fp"
    exit 0 ;;
  "delete item") printf '%s\n' "$3" >> "$BWSSH_TEST_DELETED"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub3/bw"
printf '\nHost delsrv\n    HostName d.example.com\n    User u\n    IdentityFile ~/.ssh/delsrv.pub\n    IdentitiesOnly yes\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
export BWSSH_TEST_DELETED="$TMP/deleted"; : > "$BWSSH_TEST_DELETED"
BW_SESSION=stub PATH="$stub3:$PATH" "$bwssh" remove-host delsrv --delete-key >/dev/null 2>&1; rc=$?
assert_status "remove-host --delete-key exits 0" "$rc" 0
deleted="$(cat "$BWSSH_TEST_DELETED")"
assert_contains     "the matching vault item id is deleted" "$deleted" 'ITEMID-123'
assert_contains     "duplicate-named matching item is deleted too" "$deleted" 'ITEMID-456'
assert_not_contains "wrong-fingerprint item is kept" "$deleted" 'ITEMID-WRONG'
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
out="$(BW_SESSION=stub PATH="$stub4:$PATH" "$bwssh" add-host dupsrv h.example.com u 22 --new-key 2>&1)"; rc=$?
assert_status "add-host fails on duplicate vault item" "$rc" 1
assert_contains "duplicate message says it exists" "$out" 'already exists'
assert_contains "duplicate message mentions the alias" "$out" 'dupsrv'
assert_contains "duplicate message suggests --key" "$out" '--key'
assert_contains "vault is synced before the lookup" "$(cat "$BWSSH_TEST_BWLOG")" 'sync'
assert_not_contains "duplicate host not added locally" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")" 'Host dupsrv'
unset BWSSH_TEST_BWLOG

# --- add-host --key reuses a named vault key, not one named after the alias --
stub5="$TMP/bin-pin"; mkdir -p "$stub5"
cat > "$stub5/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "list items") echo '[{"id":"P1","name":"SharedKey","type":5}]'; exit 0 ;;
  "get item")   echo '{"sshKey":{"publicKey":"ssh-ed25519 AAAAkey sharedkey"}}'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub5/bw"
BW_SESSION=stub PATH="$stub5:$PATH" "$bwssh" add-host pinsrv p.example.com u 22 --key sharedkey >/dev/null 2>&1; rc=$?
assert_status "add-host --key exits 0" "$rc" 0
assert_eq "shared pubkey written" "$(cat "$HOME/.ssh/SharedKey.pub" 2>/dev/null)" 'ssh-ed25519 AAAAkey sharedkey'
assert_contains "pin block uses the canonical key name" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")" 'IdentityFile ~/.ssh/SharedKey.pub'
[ ! -f "$HOME/.ssh/pinsrv.pub" ] && ok "no alias-named pin created" || bad "no alias-named pin created"

# --key with no matching vault key fails
stub6="$TMP/bin-pinmiss"; mkdir -p "$stub6"
cat > "$stub6/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "list items") echo '[]'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub6/bw"
out="$(BW_SESSION=stub PATH="$stub6:$PATH" "$bwssh" add-host nosrv n.example.com u 22 --key missing 2>&1)"; rc=$?
assert_status "add-host --key fails without a vault key" "$rc" 1
assert_contains "missing key message" "$out" 'no vault key named'

# --use-key is gone
out="$(BW_SESSION=stub PATH="$stub6:$PATH" "$bwssh" add-host legacy l.example.com u 22 --use-key 2>&1)"; rc=$?
assert_status "--use-key is rejected" "$rc" 1
assert_contains "rejection points at --key" "$out" '--key'

# a failed vault read must not truncate a shared pin
stub_fail="$TMP/bin-getfail"; mkdir -p "$stub_fail"
cat > "$stub_fail/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "list items") echo '[{"id":"K1","name":"keep","type":5}]'; exit 0 ;;
  "get item")   exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub_fail/bw"
printf 'OLD\n' > "$HOME/.ssh/keep.pub"; chmod 600 "$HOME/.ssh/keep.pub"
printf '\nHost keepref\n    HostName k.example.com\n    User u\n    IdentityFile ~/.ssh/keep.pub\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
out="$(BW_SESSION=stub PATH="$stub_fail:$PATH" "$bwssh" add-host getfail g.example.com u 22 --key keep 2>&1)"; rc=$?
assert_status "failed key read aborts add-host" "$rc" 1
assert_eq "existing pin is not truncated" "$(cat "$HOME/.ssh/keep.pub" 2>/dev/null)" 'OLD'
"$bwssh" remove-host keepref >/dev/null 2>&1
rm -f "$HOME/.ssh/keep.pub"

# --- remove-host keeps sibling aliases on a shared Host line ----------------
printf '\nHost keepme dropme\n    HostName shared.example.com\n    User u\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
"$bwssh" remove-host dropme >/dev/null 2>&1; rc=$?
assert_status "remove-host with a sibling alias exits 0" "$rc" 0
h="$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")"
assert_contains     "sibling alias is kept" "$h" 'Host keepme'
assert_not_contains "removed alias is gone" "$h" 'dropme'
"$bwssh" remove-host keepme >/dev/null 2>&1
assert_not_contains "last alias drops its block" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")" 'shared.example.com'

# --- list-hosts shows target, pin and default state -------------------------
out="$("$bwssh" list-hosts 2>&1)"
assert_contains "list-hosts shows alias" "$out" 'pinsrv'
assert_contains "list-hosts shows target" "$out" 'p.example.com'
assert_contains "list-hosts shows the pinned key" "$out" 'SharedKey.pub'
assert_contains "list-hosts shows the default" "$out" 'Default key: (none)'

# --- default key: required when neither --key nor --new-key is given --------
"$bwssh" default-key --clear >/dev/null 2>&1
out="$("$bwssh" add-host nodefault n.example.com u 22 2>&1)"; rc=$?
assert_status "add-host without a key or default fails" "$rc" 1
assert_contains "error offers --key" "$out" '--key'
assert_contains "error offers --new-key" "$out" '--new-key'
assert_contains "error offers default-key" "$out" 'default-key'

stub9="$TMP/bin-def"; mkdir -p "$stub9"
cat > "$stub9/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "list items") echo '[{"id":"D1","name":"defkey","type":5}]'; exit 0 ;;
  "get item")   echo '{"sshKey":{"publicKey":"ssh-ed25519 AAAAdef defkey"}}'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub9/bw"
BW_SESSION=stub PATH="$stub9:$PATH" "$bwssh" default-key defkey >/dev/null 2>&1; rc=$?
assert_status "default-key sets a default" "$rc" 0
assert_eq "default-key prints the stored name" "$("$bwssh" default-key 2>/dev/null)" 'defkey'
out="$(BW_SESSION=stub PATH="$stub9:$PATH" "$bwssh" add-host defsrv d.example.com u 22 2>&1)"; rc=$?
assert_status "add-host uses the default key" "$rc" 0
assert_contains "add-host announces the default" "$out" 'using default key "defkey"'
assert_contains "default key is pinned by name" "$(cat "$HOME/.ssh/bwSshBridgeHosts.conf")" 'IdentityFile ~/.ssh/defkey.pub'
assert_eq "default pin written" "$(cat "$HOME/.ssh/defkey.pub" 2>/dev/null)" 'ssh-ed25519 AAAAdef defkey'
out="$(BW_SESSION=stub PATH="$stub6:$PATH" "$bwssh" default-key nope 2>&1)"; rc=$?
assert_status "default-key rejects a missing vault key" "$rc" 1
"$bwssh" remove-host defsrv >/dev/null 2>&1
[ -f "$HOME/.ssh/defkey.pub" ] && ok "default pin kept by remove-host" || bad "default pin kept by remove-host"
"$bwssh" default-key --clear >/dev/null 2>&1
rm -f "$HOME/.ssh/defkey.pub" "$win_dir/defkey.pub"
assert_eq "default-key --clear removes it" "$("$bwssh" default-key 2>/dev/null)" 'none'

# --- a pin shared by two hosts survives removing the first ------------------
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/sharedpin"
chmod 600 "$HOME/.ssh/sharedpin.pub"
printf '\nHost share1\n    HostName s1.example.com\n    User u\n    IdentityFile ~/.ssh/sharedpin.pub\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
printf '\nHost share2\n    HostName s2.example.com\n    User u\n    IdentityFile ~/.ssh/sharedpin.pub\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
"$bwssh" sync-hosts --push >/dev/null 2>&1
"$bwssh" remove-host share1 >/dev/null 2>&1; rc=$?
assert_status "removing one host sharing a key exits 0" "$rc" 0
[ -f "$HOME/.ssh/sharedpin.pub" ] && ok "shared local pin kept while referenced" || bad "shared local pin kept while referenced"
[ -f "$win_dir/sharedpin.pub" ] && ok "shared Windows pin kept while referenced" || bad "shared Windows pin kept while referenced"
rm -f "$HOME/.ssh/sharedpin.pub"
"$bwssh" sync-hosts >/dev/null 2>&1
[ -f "$HOME/.ssh/sharedpin.pub" ] && ok "shared pin restored from Windows" || bad "shared pin restored from Windows"
assert_eq "restored shared pin is mode 600" "$(stat -c '%a' "$HOME/.ssh/sharedpin.pub" 2>/dev/null)" '600'
"$bwssh" remove-host share2 >/dev/null 2>&1
[ ! -f "$HOME/.ssh/sharedpin.pub" ] && ok "shared local pin removed with the last host" || bad "shared local pin removed with the last host"
[ ! -f "$win_dir/sharedpin.pub" ] && ok "shared Windows pin removed with the last host" || bad "shared Windows pin removed with the last host"

# --- --delete-key never deletes a shared or default key ---------------------
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/shareddel"
chmod 600 "$HOME/.ssh/shareddel.pub"
printf '\nHost del1\n    HostName d1.example.com\n    User u\n    IdentityFile ~/.ssh/shareddel.pub\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
printf '\nHost del2\n    HostName d2.example.com\n    User u\n    IdentityFile ~/.ssh/shareddel.pub\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
stub10="$TMP/bin-shared-del"; mkdir -p "$stub10"
cat > "$stub10/bw" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BWSSH_TEST_DELETED2"
case "$1 $2" in
  "list items")
    fp="$(ssh-keygen -lf "$HOME/.ssh/shareddel.pub" | awk '{print $2}')"
    printf '[{"id":"SHAREDDEL","name":"shareddel","type":5,"sshKey":{"keyFingerprint":"%s"}}]\n' "$fp"
    exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$stub10/bw"
export BWSSH_TEST_DELETED2="$TMP/deleted2"; : > "$BWSSH_TEST_DELETED2"
BW_SESSION=stub PATH="$stub10:$PATH" "$bwssh" default-key shareddel >/dev/null 2>&1
BW_SESSION=stub PATH="$stub10:$PATH" "$bwssh" remove-host del1 --delete-key >/dev/null 2>&1; rc=$?
assert_status "remove-host --delete-key with a shared pin exits 0" "$rc" 0
assert_eq "shared key not deleted while referenced" "$(grep -c 'delete item' "$BWSSH_TEST_DELETED2")" '0'
[ -f "$HOME/.ssh/shareddel.pub" ] && ok "shared pin kept by --delete-key" || bad "shared pin kept by --delete-key"
BW_SESSION=stub PATH="$stub10:$PATH" "$bwssh" remove-host del2 --delete-key >/dev/null 2>&1; rc=$?
assert_status "remove-host --delete-key on the last user exits 0" "$rc" 0
assert_eq "default key not deleted by --delete-key" "$(grep -c 'delete item' "$BWSSH_TEST_DELETED2")" '0'
[ -f "$HOME/.ssh/shareddel.pub" ] && ok "default pin kept by --delete-key" || bad "default pin kept by --delete-key"
assert_eq "default survives remove-host" "$("$bwssh" default-key 2>/dev/null)" 'shareddel'
"$bwssh" default-key --clear >/dev/null 2>&1
rm -f "$HOME/.ssh/shareddel.pub" "$win_dir/shareddel.pub"
unset BWSSH_TEST_DELETED2

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
  "status"*) echo '{"status":"locked"}'; exit 0 ;;
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
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/sesssrv"
chmod 600 "$HOME/.ssh/sesssrv.pub"
printf '\nHost sesssrv\n    HostName s.example.com\n    User u\n    IdentityFile ~/.ssh/sesssrv.pub\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
stub7="$TMP/bin-sess"; mkdir -p "$stub7"
cat > "$stub7/bw" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BWSSH_TEST_BWLOG"
case "$1 $2" in
  "status"*)      echo '{"status":"unlocked"}'; exit 0 ;;
  "unlock --raw") echo 'NEWSESSION'; exit 0 ;;
  "list items")
    fp="$(ssh-keygen -lf "$HOME/.ssh/sesssrv.pub" | awk '{print $2}')"
    printf '[{"id":"ID7","name":"sesssrv","type":5,"sshKey":{"keyFingerprint":"%s"}}]\n' "$fp"
    exit 0 ;;
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
printf '\nHost sesssrv\n    HostName s.example.com\n    User u\n    IdentityFile ~/.ssh/sesssrv.pub\n' >> "$HOME/.ssh/bwSshBridgeHosts.conf"
stub8="$TMP/bin-stale"; mkdir -p "$stub8"
cat > "$stub8/bw" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "status"*) echo '{"status":"locked"}'; exit 0 ;;
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
  "status"*) echo '{"status":"locked"}'; exit 0 ;;
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
out="$("$bwssh" remove-host '*' 2>&1)"; rc=$?
assert_status "wildcard remove-host is rejected" "$rc" 1
out="$("$bwssh" add-host '*' h.example.com u 22 --alias-only 2>&1)"; rc=$?
assert_status "wildcard add-host is rejected" "$rc" 1

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
