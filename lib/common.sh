# shellcheck shell=bash
# Shared helpers for bwssh.

BWSSH_VERSION="0.1.0"

log()  { printf '[*] %s\n' "$*"; }              # normal progress (stdout)
note() { printf '[*] %s\n' "$*" >&2; }          # progress safe inside "$(...)"
logv() { [[ "${BWSSH_VERBOSE:-0}" == 1 ]] && printf '[*] %s\n' "$*" || true; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

# --- managed blocks in shell/ssh config files ------------------------------

# Remove any block previously written by bwssh (any "# >>> bwSshBridge" marker).
strip_marked() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
path = sys.argv[1]
try:
    lines = open(path).read().splitlines(keepends=True)
except FileNotFoundError:
    lines = []
out, skip = [], False
for line in lines:
    s = line.strip()
    if not skip and s.startswith("# >>> bwSshBridge"):
        skip = True
        continue
    if skip:
        if s == "# <<< bwSshBridge <<<":
            skip = False
        continue
    out.append(line)
open(path, "w").writelines(out)
PY
}

append_marked() {
  local file="$1" content="$2"
  mkdir -p -- "$(dirname -- "$file")"
  touch -- "$file"
  strip_marked "$file"
  {
    printf '\n# >>> bwSshBridge >>>\n'
    printf '%s\n' "$content"
    printf '# <<< bwSshBridge <<<\n'
  } >> "$file"
  log "wrote block in ${file/#$HOME/\~}"
}

prepend_marked() {
  local file="$1" content="$2" quiet="${3:-0}"
  mkdir -p -- "$(dirname -- "$file")"
  touch -- "$file"
  strip_marked "$file"
  {
    printf '# >>> bwSshBridge >>>\n'
    printf '%s\n' "$content"
    printf '# <<< bwSshBridge <<<\n\n'
    cat -- "$file"
  } > "${file}.bwtmp"
  mv -- "${file}.bwtmp" "$file"
  if [[ "$quiet" == 1 ]]; then logv "prepended block in ${file/#$HOME/\~}"
  else log "prepended block in ${file/#$HOME/\~}"; fi
}

# --- Windows mirror --------------------------------------------------------

# %USERPROFILE% is fetched from cmd.exe once per process and both the unix and
# native forms are memoized; each lookup otherwise costs a slow Windows spawn.
bwsh_win_home_init() {
  [[ -n "${BWSSH_WIN_HOME_UNIX:-}" ]] && return 0
  # Override (used by tests) so nothing outside a real WSL session is touched.
  if [[ -n "${BWSSH_WIN_HOME:-}" ]]; then
    BWSSH_WIN_HOME_UNIX="$BWSSH_WIN_HOME"
    BWSSH_WIN_HOME_NATIVE="$BWSSH_WIN_HOME"
    return 0
  fi
  local p
  command -v cmd.exe >/dev/null 2>&1 || return 1
  p="$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')" || return 1
  [[ -n "$p" ]] || return 1
  BWSSH_WIN_HOME_NATIVE="$p"
  BWSSH_WIN_HOME_UNIX="$(wslpath -u "$p" 2>/dev/null)" || return 1
}

bwsh_win_home() {
  bwsh_win_home_init || return 1
  printf '%s\n' "$BWSSH_WIN_HOME_UNIX"
}

bwsh_win_home_native() {
  bwsh_win_home_init || return 1
  printf '%s\n' "$BWSSH_WIN_HOME_NATIVE"
}

bwsh_win_ssh_dir() {
  local wh
  wh="$(bwsh_win_home)" || return 1
  printf '%s\n' "${wh}/.ssh"
}

# Unix path of the mirrored per-host file (Windows' own %USERPROFILE%\.ssh).
bwsh_win_hosts_file() {
  local d
  d="$(bwsh_win_ssh_dir)" || return 1
  printf '%s\n' "${d}/bwSshBridgeHosts.conf"
}

# The Windows-native absolute path to that mirror, for an `Include` directive.
bwsh_win_hosts_file_native() {
  # Test override is a unix path, so mirror it verbatim with forward slashes.
  if [[ -n "${BWSSH_WIN_HOME:-}" ]]; then
    printf '%s\n' "${BWSSH_WIN_HOME}/.ssh/bwSshBridgeHosts.conf"
    return 0
  fi
  local wh
  wh="$(bwsh_win_home_native)" || return 1
  printf '%s\n' "${wh}\\.ssh\\bwSshBridgeHosts.conf"
}

bwsh_win_config_file() {
  local d
  d="$(bwsh_win_ssh_dir)" || return 1
  printf '%s\n' "${d}/config"
}

bwsh_hosts_file() {
  printf '%s\n' "${HOME}/.ssh/bwSshBridgeHosts.conf"
}

# Make the per-host file OS-neutral (read by both WSL and Windows ssh): rewrite
# "IdentityFile $HOME/.ssh/..." to the portable "IdentityFile ~/.ssh/..." and
# drop per-host "PubkeyAuthentication unbound" lines (the global `Host *` block
# now supplies it on each side). Idempotent.
bwsh_normalize_hosts_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  python3 - "$file" <<'PY'
import os, sys
path = sys.argv[1]
prefix = os.environ.get("HOME", "").rstrip("/") + "/.ssh/"
changed = False
out = []
for line in open(path):
    if line.strip() == "PubkeyAuthentication unbound":
        changed = True
        continue
    if prefix != "/.ssh/" and "IdentityFile" in line and prefix in line and "~/.ssh/" not in line:
        line = line.replace(prefix, "~/.ssh/", 1)
        changed = True
    out.append(line)
if changed:
    with open(path, "w") as fh:
        fh.writelines(out)
PY
}

# Print the alias of every `Host <alias> ...` entry (skips wildcard patterns).
bwsh_host_aliases() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '$1=="Host"{for(i=2;i<=NF;i++) if($i !~ /[*?!]/) print $i}' "$file" | sort -u
}

# Copy every pinned public key (~/.ssh/<alias>.pub) next to the mirrored hosts
# file. Only public halves are ever copied; a missing .pub (alias-only entry) is
# skipped. Never touches a private key.
bwsh_mirror_pubs_to_windows() {
  local src="$1" d alias pub
  d="$(bwsh_win_ssh_dir)" || return 0
  mkdir -p -- "$d"
  while IFS= read -r alias; do
    [[ -n "$alias" ]] || continue
    pub="${HOME}/.ssh/${alias}.pub"
    [[ -f "$pub" ]] || continue
    cp -- "$pub" "${d}/${alias}.pub"
    logv "mirrored key pin -> ${d}/${alias}.pub"
  done < <(bwsh_host_aliases "$src")
}

# Restore any pinned public key that is missing locally from the Windows mirror
# (same discovery rule as the mirror). Existing local keys are never overwritten.
bwsh_restore_pubs_from_windows() {
  local src="$1" d alias local_pub win_pub
  d="$(bwsh_win_ssh_dir)" || return 0
  while IFS= read -r alias; do
    [[ -n "$alias" ]] || continue
    local_pub="${HOME}/.ssh/${alias}.pub"
    win_pub="${d}/${alias}.pub"
    [[ -f "$local_pub" ]] && continue
    [[ -f "$win_pub" ]] || continue
    install -m 0600 -- "$win_pub" "$local_pub"
    logv "restored key pin ${alias}.pub from Windows"
  done < <(bwsh_host_aliases "$src")
}

# Remove a pinned public key from the Windows mirror.
bwsh_remove_win_pub() {
  local alias="$1" d
  d="$(bwsh_win_ssh_dir)" || return 0
  rm -f -- "${d}/${alias}.pub"
}

bwsh_sync_hosts_to_windows() {
  local src="$1" dst
  bwsh_normalize_hosts_file "$src"
  if ! dst="$(bwsh_win_hosts_file)"; then
    warn "cannot locate the Windows home; skipping hosts mirror"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$dst")" && cp -- "$src" "$dst"
  logv "mirrored hosts -> $dst"
  bwsh_mirror_pubs_to_windows "$src"
  bwsh_write_windows_ssh_config
}

# --- Windows ssh config block ----------------------------------------------

# Run the Windows OpenSSH client. `ssh.exe` is directly reachable from WSL and
# ~30x faster than going through powershell.exe; only fall back if it is absent.
bwsh_win_ssh() {
  if command -v ssh.exe >/dev/null 2>&1; then
    ssh.exe "$@"
    return $?
  fi
  command -v powershell.exe >/dev/null 2>&1 || return 127
  # Fallback: args are our own fixed flags/hostnames (no spaces), so join is safe.
  powershell.exe -NoProfile -Command "& ssh $*"
}

# Does the installed Windows OpenSSH accept `PubkeyAuthentication unbound`?
# Probe empirically (an invalid value makes ssh fail); `-F NUL` skips reading
# the user config so the probe stays fast. Memoized 0/1 once per process.
bwsh_win_unbound_supported() {
  case "${BWSSH_WIN_UNBOUND:-auto}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if [[ -z "${BWSSH_WIN_UNBOUND_MEMO:-}" ]]; then
    if bwsh_win_ssh -F NUL -o PubkeyAuthentication=unbound -G bwsshprobe >/dev/null 2>&1; then
      BWSSH_WIN_UNBOUND_MEMO=0
    else
      BWSSH_WIN_UNBOUND_MEMO=1
    fi
  fi
  return "$BWSSH_WIN_UNBOUND_MEMO"
}

# Is `Include` in the client ssh_config supported? Added in OpenSSH 7.3 (2016),
# so anything modern supports it; detect by version. Memoized 0/1 per process.
bwsh_win_include_supported() {
  case "${BWSSH_WIN_INCLUDE:-auto}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if [[ -z "${BWSSH_WIN_INCLUDE_MEMO:-}" ]]; then
    local v major minor
    if v="$(bwsh_win_ssh -V 2>&1 | tr -d '\r')" \
       && major="$(printf '%s\n' "$v" | sed -n 's/.*_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1/p')" \
       && minor="$(printf '%s\n' "$v" | sed -n 's/.*_\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\2/p')" \
       && [[ -n "$major" && -n "$minor" ]] \
       && (( major > 7 || (major == 7 && minor >= 3) )); then
      BWSSH_WIN_INCLUDE_MEMO=0
    else
      BWSSH_WIN_INCLUDE_MEMO=1
    fi
  fi
  return "$BWSSH_WIN_INCLUDE_MEMO"
}

# Quote a Windows path for an ssh_config directive when it contains whitespace.
bwsh_win_quote() {
  local p="$1"
  if [[ "$p" == *" "* || "$p" == *$'\t'* ]]; then
    printf '"%s"' "$p"
  else
    printf '%s' "$p"
  fi
}

# Build the marker block for the Windows ssh config: a global `Host *` (with
# `unbound` only when supported) plus an absolute `Include` of the mirror. If
# `Include` is unsupported, the per-host entries are inlined instead.
bwsh_win_config_block() {
  local native dst
  native="$(bwsh_win_hosts_file_native)" || return 1
  printf 'Host *\n'
  if bwsh_win_unbound_supported; then
    printf '    # The Bitwarden agent refuses host-bound signatures; see docs/design.md.\n'
    printf '    PubkeyAuthentication unbound\n'
  fi
  printf '\n'
  if bwsh_win_include_supported; then
    printf 'Include %s\n' "$(bwsh_win_quote "$native")"
  else
    dst="$(bwsh_win_hosts_file)" || return 1
    [[ -f "$dst" ]] && cat -- "$dst"
  fi
}

bwsh_write_windows_ssh_config() {
  local cfg block
  if ! cfg="$(bwsh_win_config_file)"; then
    warn "cannot locate the Windows home; skipping Windows ssh config"
    return 0
  fi
  block="$(bwsh_win_config_block)" || return 0
  mkdir -p -- "$(dirname -- "$cfg")"
  prepend_marked "$cfg" "$block" 1
}

# Remove our marker block from the Windows ssh config, preserving everything
# else the user has.
bwsh_strip_windows_ssh_config() {
  local cfg
  cfg="$(bwsh_win_config_file)" || return 0
  [[ -f "$cfg" ]] || return 0
  strip_marked "$cfg"
  logv "removed bwSshBridge block from Windows ssh config"
}

# --- vault session cache ---------------------------------------------------

# A short-lived BW_SESSION so commands don't re-prompt every time. It is a
# decryption key, so it is only ever kept in tmpfs (RAM), mode 0600, and is
# cleared on reboot, on `bwssh lock`, or by setting BWSSH_NO_SESSION_CACHE=1.
# It is never written to persistent disk.
bwsh_session_file() {
  [[ "${BWSSH_NO_SESSION_CACHE:-0}" == 1 ]] && return 1
  local base
  if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]]; then
    base="${XDG_RUNTIME_DIR}/bwSshBridge"
  elif [[ -d /dev/shm ]]; then
    base="/dev/shm/bwSshBridge-$(id -u)"
  else
    return 1
  fi
  printf '%s\n' "${base}/session"
}

bwsh_session_get() {
  local f s
  f="$(bwsh_session_file)" || return 1
  [[ -f "$f" ]] || return 1
  s="$(cat -- "$f" 2>/dev/null)" || return 1
  [[ -n "$s" ]] || return 1
  printf '%s\n' "$s"
}

bwsh_session_set() {
  local f
  f="$(bwsh_session_file)" || return 0
  mkdir -p -- "$(dirname -- "$f")"
  chmod 700 -- "$(dirname -- "$f")" 2>/dev/null || true
  ( umask 077; printf '%s\n' "$1" > "$f" )
  chmod 600 -- "$f" 2>/dev/null || true
}

bwsh_session_clear() {
  local f
  f="$(bwsh_session_file)" || return 0
  rm -f -- "$f"
}

# --- Bitwarden CLI helpers -------------------------------------------------

require_bw() {
  command -v bw >/dev/null 2>&1 || die "Bitwarden CLI not installed. Run: bwssh setup-cli"
}

bw_status() {
  bw status 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null || true
}

bw_is_logged_in() {
  case "$(bw_status)" in
    unlocked|locked) return 0 ;;
    *) return 1 ;;
  esac
}

# API-key login (non-interactive; needs BW_CLIENTID/BW_CLIENTSECRET).
bw_login_apikey() {
  bw login --apikey >/dev/null 2>&1
}

# Unlock the vault and print the session token to stdout. The password prompt is
# written by Bitwarden to stderr, so when stderr is a terminal we must leave it
# attached (otherwise the prompt is swallowed and it looks like a hang). Session
# tokens are the only thing we accept from stdout, so a failure never leaks an
# error string into BW_SESSION.
bw_unlock_session() {
  local out err
  if [[ -t 2 ]]; then
    if out="$(bw unlock --raw)" && [[ -n "$out" && "$out" != *[[:space:]]* ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    warn "could not unlock the vault (wrong master password?)"
    return 1
  fi
  err="$(mktemp)"
  if out="$(bw unlock --raw 2>"$err")" && [[ -n "$out" && "$out" != *[[:space:]]* ]]; then
    rm -f -- "$err"
    printf '%s\n' "$out"
    return 0
  fi
  warn "could not unlock the vault (wrong master password?)"
  [[ "${BWSSH_VERBOSE:-0}" == 1 ]] && cat -- "$err" >&2
  rm -f -- "$err"
  return 1
}

# Interactive login: email + master password (+ 2FA). Prints the session.
bw_login_interactive() {
  [[ -t 0 ]] || return 1
  note "logging in interactively (email + master password; 2FA if enabled)…"
  bw login --raw
}

# Exact token match for "Host <alias>" in a hosts file (no regex pitfalls).
host_is_pinned() {
  local file="$1" alias="$2"
  [[ -f "$file" ]] || return 1
  awk -v a="$alias" '$1=="Host"{for(i=2;i<=NF;i++) if($i==a) f=1} END{exit f?0:1}' "$file"
}

# Write the public half of an existing vault SSH item to a file (mode 600).
bw_get_pubkey() {
  local item="$1" out="$2"
  bw get item "$item" --session "$BW_SESSION" \
    | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["sshKey"]["publicKey"] + "\n")' \
    > "$out"
  chmod 0600 -- "$out"
}

# Pull the latest vault data from the server. `bw list items` only sees the
# local cache, so items added elsewhere (desktop app, another device) are
# invisible until a sync. Best-effort: ignored if offline.
bw_sync_quiet() {
  bw sync --session "$BW_SESSION" >/dev/null 2>&1 || true
}

# Print the ids of SSH-key vault items (type 5) whose name exactly matches
# <name>. Handles duplicate names, where `bw get item <name>` errors out.
bw_find_item_ids() {
  local name="$1"
  bw list items --search "$name" --session "$BW_SESSION" 2>/dev/null \
    | python3 -c 'import json,sys
name = sys.argv[1].lower()
try:
    items = json.load(sys.stdin)
except Exception:
    items = []
for it in (items if isinstance(items, list) else []):
    if it.get("type") == 5 and it.get("name", "").lower() == name:
        print(it.get("id", ""))' "$name" 2>/dev/null || true
}

# Create a type-5 SSH key item from a temp keypair, without leaking material.
# Args: name comment [pub-out]; prints the fingerprint.
bw_create_ssh_item() {
  local name="$1" comment="$2" pub_out="${3:-}"
  (
    local tmpd fp
    tmpd="$(mktemp -d -p /dev/shm bwsshKey.XXXXXX)"
    chmod 700 "$tmpd"
    # shellcheck disable=SC2064
    trap "cleanup_tmpdir '$tmpd'" EXIT INT TERM

    ssh-keygen -t ed25519 -C "$comment" -N '' -f "$tmpd/id" >/dev/null
    fp="$(ssh-keygen -lf "$tmpd/id.pub" | awk '{print $2}')"
    [[ -n "$pub_out" ]] && install -m 0600 "$tmpd/id.pub" "$pub_out"

    bw get template item \
      | BW_SSH_NAME="$name" BW_SSH_FP="$fp" \
        BW_SSH_PRIV="$(cat "$tmpd/id")" BW_SSH_PUB="$(cat "$tmpd/id.pub")" \
        python3 "$LIB_DIR/embedSshKey.py" \
      | bw encode \
      | bw create item --session "$BW_SESSION" >/dev/null

    printf '%s\n' "$fp"
  )
}

cleanup_tmpdir() {
  local d="$1"
  if command -v shred >/dev/null 2>&1; then
    find "$d" -type f -exec shred -u {} + 2>/dev/null || true
  fi
  rm -rf -- "$d"
}
