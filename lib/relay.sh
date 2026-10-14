#!/usr/bin/env bash
# Bridge the Windows Bitwarden Desktop SSH agent into WSL2.
#
# A single persistent socat listener owns the Unix socket; each client
# connection forks one short-lived npiperelay.exe that relays bytes to the
# Windows OpenSSH-agent named pipe. The private key never enters WSL: only
# signing requests cross the pipe.
#
# Managed by the systemd --user unit bwSshBridge.service.
#
# Deliberately NO "-p" (poll-until-free) on npiperelay: Bitwarden exposes a
# single pipe instance, and while -p polls it never reads stdin, so -ei can
# never fire on disconnect and Windows processes leak one-per-operation.
set -euo pipefail

SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/agent.sock}"
PIPE="//./pipe/openssh-ssh-agent"

log() { printf '[bwSshBridge] %s\n' "$*" >&2; }

find_npiperelay() {
  if [[ -n "${NPIPERELAY:-}" && -x "${NPIPERELAY}" ]]; then
    printf '%s\n' "${NPIPERELAY}"
    return 0
  fi
  local candidates=(
    "${HOME}/.local/bin/npiperelay.exe"
    /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/albertony.npiperelay_*/npiperelay.exe
    /mnt/c/ProgramData/chocolatey/bin/npiperelay.exe
    /mnt/c/ProgramData/chocolatey/lib/npiperelay/tools/npiperelay.exe
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

command -v socat >/dev/null 2>&1 || {
  log "socat is not installed. Run: sudo apt-get install -y socat"
  exit 1
}

NPIPERELAY="$(find_npiperelay)" || {
  log "npiperelay.exe not found."
  log "Install it with: winget install albertony.npiperelay"
  log "…or set NPIPERELAY to its path and run again."
  exit 1
}

mkdir -p -- "$(dirname -- "${SOCK}")"
if [[ -S "${SOCK}" ]]; then
  rm -f -- "${SOCK}"
fi

log "relay ${SOCK} <-> ${PIPE} via ${NPIPERELAY}"
exec socat "UNIX-LISTEN:${SOCK},fork,mode=600" \
  "EXEC:${NPIPERELAY} -ei -s ${PIPE},nofork"
