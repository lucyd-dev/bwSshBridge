# Design: SSH in WSL2 via the Bitwarden Desktop agent

## Intent

Use `ssh` in WSL2 without a private key ever residing permanently on the WSL
filesystem. Keys live in a Bitwarden vault (EU cloud or self-hosted) and are
used through the Bitwarden Desktop app's SSH agent. Everything is driven by a
single CLI, `bwssh`.

## Goals

- Private key never on WSL disk; ideally never in WSL memory.
- `ssh` / `scp` / `rsync` / `git` work transparently once set up, for any host.
- One idempotent installer for the WSL side; one script for Windows prereqs.
- Optional CLI tooling to generate/store SSH keys and manage per-host pins
  without leaking key material.
- Reusable across machines/WSL reinstalls, with no secrets committed.

## Non-goals

- Changing the private key on the remote server (that is normal key
  administration).
- Automating Bitwarden Desktop's GUI toggles (not possible).

## Anti-goals

- Private key material in shell history, argv, temp files, or logs.
- A solution that silently falls back to an on-disk key.
- Fragile per-shell `socat` spawning (races, orphaned processes).

## Architecture

Bitwarden Desktop (standalone build) registers as the Windows OpenSSH agent on
the named pipe `\\.\pipe\openssh-ssh-agent`. A systemd `--user` service runs one
persistent `socat` listener on a Unix socket; `socat` forks one short-lived
`npiperelay.exe` per client connection to relay bytes to the pipe.
`SSH_AUTH_SOCK` points shells at that socket.

```
Windows                                    WSL2
Bitwarden Desktop (standalone)             ┌─ systemd --user: bwSshBridge.service
  └─ \\.\pipe\openssh-ssh-agent  ◀─────────┼─ socat (one listener)
       (single pipe instance)              └─ npiperelay.exe (forked per connection)
                                                    ▲
                                                    └─ ~/.ssh/agent.sock  ◀── ssh / scp / rsync / git
```

### Why the relay is shaped this way

- **systemd, not `.bashrc`:** one owner of the listener; no races between
  shells; restarts on failure; no shell-startup hangs.
- **No `npiperelay -p`:** Bitwarden exposes a single pipe instance; `-p` polls
  without draining stdin, so `-ei` never fires on disconnect and Windows
  processes leak one-per-operation. Fail fast and retry instead.

## Security model

- Trust boundary: the private key and signing live on the Windows side in
  Bitwarden Desktop; WSL sees only an ssh-agent protocol socket.
- Authorization: Bitwarden's "Ask for authorization when using SSH agent"
  setting (Always / Remember until vault is locked / Never) governs prompts.
  "Never" lets any process running as the Windows user use keys silently.
- Least exposure locally: no private key file; global `PubkeyAuthentication
  unbound` and `SSH_AUTH_SOCK` mean no key path is referenced.
- CLI tooling (key lifecycle): `bw` ⇄ `python3` piping; key creation in
  `/dev/shm` (tmpfs) with `shred` on exit; `bw create item` output (which
  contains the decrypted key) is discarded.
- Vault session: `bwssh login` caches the Bitwarden CLI session token in tmpfs
  only (`$XDG_RUNTIME_DIR`, mode 600), so repeated commands don't re-prompt. It
  is cleared by `bwssh lock`/`bwssh uninstall`/reboot and never written to disk;
  `BWSSH_NO_SESSION_CACHE=1` opts out (commands then prompt each time).

## Constraints discovered in the environment

- Ubuntu WSL2 with systemd enabled (`/etc/wsl.conf [boot] systemd=true`).
- The Microsoft Store (Appx) Bitwarden build cannot serve the pipe.
- Windows OpenSSH Authentication Agent service must be **Disabled**.
- `winget` available; `socat`/`npiperelay` absent by default; `jq` absent (use
  `python3`); `bw` absent until installed.

## Key decisions & gotchas

1. **`PubkeyAuthentication unbound` is required.** OpenSSH 9.x negotiates
   `publickey-hostbound-v00@openssh.com`; the Bitwarden agent answers listing
   (`ssh-add -l`) but returns `agent refused operation` for the host-bound
   signature. Bitwarden 2026.9.0 (v2 agent) still does. Disabling it client-side
   (`unbound`) fixes auth. Same class of bug as gpg-agent/Secretive.
2. **A pinned `IdentityFile` must be the public key, at mode 600.** A `.pub`
   `IdentityFile` is what selects a specific agent key (the private-path variant
   let ssh fall back to offering arbitrary agent keys). OpenSSH runs its
   private-key permission check on that path, so `0644` →
   `UNPROTECTED PRIVATE KEY FILE`; `chmod 600` fixes it.
3. **`ssh-add -T` is the minimal offline check** that the bridge can sign
   (listing alone is not enough).
4. **`Include ~/.ssh/...` works** in the user ssh config, which lets per-host
   entries live in a separate, portable file.

### Risk assessment: `PubkeyAuthentication unbound`

Host-bound signatures bind the client's auth signature to the destination
server's host key. Per OpenSSH's `agent-restrict` document, this matters for
**agent forwarding** (a compromised hop abusing a forwarded agent) and for
**destination-constrained keys** (`ssh-add -h`); it is explicitly *not* required
for "first-hop" connections where the agent runs locally. Direct SSH is already
replay-safe because the signature covers a unique per-connection session id, and
MITM is handled by host-key verification. Therefore, for local (non-forwarded)
agent use, `unbound` removes no meaningful protection. Rule: **never enable
`ForwardAgent yes`** with this setup. Re-test after Bitwarden updates add
host-bound support.

## Per-host config persistence

Global settings (the `Host *` block) are repo-owned and regenerated by
`bwssh install`. Per-host entries are user-owned, kept in
`~/.ssh/bwSshBridgeHosts.conf`, `Include`d by the global block, and mirrored into
Windows' own `%USERPROFILE%\.ssh\` so they survive a WSL reinstall, are
copyable, and are usable by Windows-native `ssh` and VS Code Remote-SSH. On
install the Windows copy wins if present; otherwise the shipped default is
seeded and mirrored out. `bwssh add-host` manages the file when adding a server
key.

The mirror consists of three things:

1. `bwSshBridgeHosts.conf` — the per-host entries, copied verbatim.
2. `<key>.pub` — the **public** half of every key referenced by an
   `IdentityFile` in a `Host` entry (public only). One key can back many hosts
   and is mirrored once; alias-only entries have no pin.
   `bwsh_sync_hosts_to_windows` copies these; `run_remove_host` deletes a pin
   only once no remaining host references it.
3. A marker-wrapped block at the top of `%USERPROFILE%\.ssh\config` containing a
   global `Host *` (with `PubkeyAuthentication unbound` only when the installed
   Windows OpenSSH supports it) plus `Include <absolute Windows path>`. It is
   prepended and idempotent; everything outside the `# >>> bwSshBridge` markers is
   preserved. If `Include` is unsupported, the host entries are inlined instead.

### Shared keys

SSH's normal model is one key per person/machine added to many servers, so the
CLI makes shared keys the default path:

- `bwssh default-key <vault-item>` validates that exactly one type-5 item has
  that name (case-insensitively) and stores the item's canonical name in
  `~/.config/bwSshBridge/default-key` (plain text; never key material).
  `bwssh default-key` prints it; `--clear` removes it.
- `bwssh add-host ...` with no key flag uses the default and logs
  `using default key "<name>"`. If no default is set it refuses rather
  than guessing.
- `--key <vault-item>` pins that shared key for the host without changing the
  default. The name is canonicalised so the pin basename matches the vault item.
- `--new-key` creates a per-host key named after the alias (the isolated mode).
- `--alias-only` pins no key.

`add-host` fetches or refreshes the pinned public key from the vault every time,
so a stale local pin cannot silently win. `remove-host` is reference-aware: it
collects the pins of the block being removed, then deletes a pin locally and
from the Windows mirror only when no remaining `Host` block references it and it
is not the current default.
`--delete-key` deletes vault items only when the pin is unreferenced, the
item's `keyFingerprint` (or, failing that, its public key) matches the pin, and
the key is not the current default; alias name alone is never sufficient. The
default key is never removed by `remove-host` (clear the default before removing
the last host if removal is intended). Unlock happens before the hosts file is
edited, so an aborted session leaves the host in place.

The trade-off is deliberate: a shared key lets any server that trusts it reach
every other server that trusts it. `--new-key` is the isolation boundary for
hosts that need one.

`bwssh add-host` refuses a new alias that already exists locally when
`--new-key` is given; for the shared/default modes re-adding an existing alias is
idempotent. New-key mode also refuses a Bitwarden SSH-key item named after the
alias, so a leftover vault item can't silently produce a duplicate. Because
`bw list items` only reads the CLI's local cache, vault-touching commands run
`bw sync` first, so items added in the desktop app or on another device are
visible (best-effort: a sync failure, e.g. offline, is ignored).

Restore is symmetric: on install, a missing WSL `bwSshBridgeHosts.conf` is
imported from the Windows mirror, and any missing local pin is restored (mode
600). Existing local files are never overwritten.

### Windows mirror performance

Spawning Windows processes from WSL is slow, so the mirror avoids doing it
repeatedly: `%USERPROFILE%` is resolved **once per process**
(`bwsh_win_home_init`, memoized in the main shell so per-command subshells reuse
it), and client-capability detection calls the Windows `ssh.exe` **directly**
(reachable from WSL at ~0.09s vs ~2.7s through `powershell.exe`) with `-F NUL`
to skip config parsing. Capability results are memoized per process and can be
overridden with `BWSSH_WIN_UNBOUND`/`BWSSH_WIN_INCLUDE`. A typical `add-host` or
`remove-host` dropped from multiple seconds to well under one (Bitwarden CLI
startup still dominates when the vault is touched).

Per-host blocks are OS-neutral: they no longer carry
`PubkeyAuthentication unbound`, and pinned keys are referenced as
`IdentityFile ~/.ssh/<key>.pub` (never an absolute WSL path), so the same
entry resolves on Windows where `~` is `%USERPROFILE%`. Each side's prepended
global `Host *` block supplies `unbound`, and first-match semantics make that
win. `bwsh_normalize_hosts_file` migrates older entries on install and on every
mirror sync (idempotent): it rewrites absolute `IdentityFile` paths to the tilde
form and strips redundant per-host `PubkeyAuthentication unbound` lines.

### Verification (Windows OpenSSH 9.5p2, WSL OpenSSH 9.6p1)

- `PubkeyAuthentication unbound` **is** accepted by the Windows client. Probe:
  `ssh -o PubkeyAuthentication=unbound -G host` exits 0, while an invalid value
  like `bogus` exits 255 (`unsupported option`). The installer therefore uses an
  empirical probe (`bwsh_win_unbound_supported`) rather than a version check.
- `Include` **is** supported (client-side since OpenSSH 7.3). Probed with an
  absolute Windows path, including a quoted path containing spaces; the
  fallback (inline the entries) is only used if a version probe says otherwise.
- `~/.ssh/<key>.pub` in a per-host block expands against `%USERPROFILE%` on
  Windows, so the mirrored public keys resolve on both sides.
- The Windows client does **not** apply the Unix private-key permission check to
  a `.pub` `IdentityFile`: a world-readable mirrored `.pub` connects without
  `UNPROTECTED PRIVATE KEY FILE`, so no Windows ACL work is required for the
  mirror.

### Uninstall

`bwssh uninstall` strips the marker block from `%USERPROFILE%\.ssh\config`
(`bwsh_strip_windows_ssh_config`), restoring the user's file to its original
content except for the markers. The mirrored `bwSshBridgeHosts.conf` and
`<key>.pub` files are deliberately **left in place** — they are the portable
copies needed to restore a fresh WSL, mirroring how the WSL hosts file is
retained.

## Decisions (builder may adjust)

- Socket path `~/.ssh/agent.sock` (override with `BW_SSH_SOCK`).
- Installer edits `~/.bashrc` + `~/.profile` via idempotent marker blocks that
  source `~/.config/bwSshBridge/env.sh`.
- `~/.ssh/config` gets a marker-wrapped global block prepended; the Windows
  `%USERPROFILE%\.ssh\config` gets an equivalent marker-wrapped block prepended
  (see "Per-host config persistence").
- `bwssh install` auto-runs the Windows prereqs (skippable with `--no-windows`)
  and auto-elevates via UAC to disable the OpenSSH agent service.
- `BW_SERVER` defaults to `https://vault.bitwarden.eu`.
