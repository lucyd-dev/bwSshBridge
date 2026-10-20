# bwSshBridge — SSH in WSL2 through the Bitwarden Desktop agent

The `bwssh` CLI bridges the Windows OpenSSH-agent pipe into a Unix socket in
WSL2, so `ssh`/`scp`/`rsync`/`git` authenticate with keys that live only in your
Bitwarden vault. The private key never touches the WSL disk or memory.

One command installs and configures everything, on both WSL and Windows.

> **Not affiliated with Bitwarden.** This is an independent community bridge.
> "Bitwarden" and "bw" are trademarks of their respective owners, referenced
> only to describe what this tool connects to.

## Requirements

- WSL2 with **systemd enabled** (`/etc/wsl.conf` → `[boot]` `systemd=true`).
- **Bitwarden Desktop, standalone build** on Windows (the Store build cannot
  serve the SSH agent). `sudo`, and `powershell.exe`/`cmd.exe` from WSL.
- **Node 18+** only for the optional `bw` CLI (key creation); skip with
  `bwssh install --no-cli`. An API key is optional — login can be interactive.

## Quick start

```bash
git clone https://github.com/lucyd-dev/bwSshBridge ~/bwSshBridge && cd ~/bwSshBridge
./bwssh install
```

Then in **Bitwarden Desktop**: enable **Settings → SSH agent**, and pick an
**"Ask for authorization"** preference (`Remember until vault is locked` is a
good default). Open a new shell:

```bash
ssh-add -l        # lists the keys in your vault
ssh myserver      # your alias from `bwssh add-host` (below) — no -i, no key file
```

The alias is simpler to remember than `user@host`.

## Keys and hosts

bwssh is built around shared keys: one vault key can back any number of hosts.
Set a default once:

```bash
bwssh default-key sharedkey     # must name an existing SSH key in your vault
```

Then add hosts without repeating the key:

```bash
bwssh add-host myserver host.example.com alice 2222
# using default key "sharedkey"
```

This pins the key in `~/.ssh/bwSshBridgeHosts.conf` and prints the one-time
`ssh-copy-id` to authorize it on the server. Then just `ssh myserver`. It syncs
your vault first; re-adding an existing alias is a no-op. Variants:

- `--key <vault-item>` — use a specific shared key for this host (does not
  change the default).
- `--new-key` — create a fresh vault key just for this host, named after the
  alias.
- `--alias-only` — alias only, no key pin, no vault access.

With no default set and neither `--key` nor `--new-key`, `add-host` refuses and
tells you what to pass. Manage the default with `bwssh default-key` (prints it),
`bwssh default-key <vault-item>`, or `bwssh default-key --clear`.

Pins are referenced by key name (`IdentityFile ~/.ssh/sharedkey.pub`), so every
host using a key shares the same pin.

`bwssh remove-host <alias>` removes the alias and, unless it is the default,
the pinned public key once no other host references it, locally and from the
Windows mirror. It **does not delete the key from Bitwarden** unless you pass
`--delete-key`. With
`--delete-key`, the vault item is deleted only when the removed host was the
last one using it, the item's fingerprint matches the pin, and the key is not
the current default. **The default key is never deleted by `remove-host`.** To
remove it, clear the default first (`bwssh default-key --clear`) and then remove
the host, or delete the item in Bitwarden.

### Unlocking Bitwarden

Commands that read or write your vault (`add-host` unless `--alias-only`,
`default-key <vault-item>`, `remove-host --delete-key`) need it unlocked.
Instead of typing your master password every time, unlock once:

```bash
bwssh login        # asks for the master password once
bwssh add-host ... # reuses the session
bwssh lock         # forget the session (also cleared on reboot)
```

`bwssh login` caches the session token in memory only (`$XDG_RUNTIME_DIR`, mode
600 — never on disk) and `bwssh lock` clears it. Set `BWSSH_NO_SESSION_CACHE=1`
to disable caching (commands then prompt each time). Commands that never touch
the vault (`--alias-only`, plain `remove-host`, `sync-hosts`, `default-key`
without an item) never prompt.

## Commands

| Command | Purpose |
| --- | --- |
| `install [--no-cli] [--no-windows] [--copy]` | install bridge + Windows prereqs + CLI + ssh config; `--no-cli` skips the `bw` CLI, `--no-windows` skips Windows prereqs, `--copy` copies the repo instead of symlinking |
| `add-host <alias> <host> [user] [port] [--key <vault-item> \| --new-key \| --alias-only]` | add/pin a host; uses the default key if set, `--key` picks a shared key, `--new-key` creates a per-host key, `--alias-only` pins no key |
| `default-key [<vault-item>] [--clear]` | show, set or clear the default shared key used by `add-host` |
| `remove-host <alias> [--delete-key]` | remove the host and any pin no other host uses; `--delete-key` also deletes its vault key when it is the last user |
| `list-hosts` | list pinned hosts |
| `sync-hosts [--push]` | import the Windows mirror; `--push` mirrors WSL → Windows |
| `status [--windows]` / `doctor` | diagnose; `--windows` runs Windows checks |
| `uninstall` | remove the WSL-side bridge |
| `windows` | (re)run the Windows prerequisites |
| `setup-cli [--force]` | install the `bw` CLI and store API keys; `--force` replaces them |
| `login` | unlock and cache the session |
| `lock` | clear the cached session |

Set `BWSSH_VERBOSE=1` to see every mirrored file and config block (off by default).

## Windows ssh and VS Code

Host entries and every public key they pin are mirrored to `%USERPROFILE%\.ssh\`, and
`bwssh install` prepends a marker-wrapped `Host *` + `Include` block to
`%USERPROFILE%\.ssh\config` (your other entries are preserved). So Windows-native
`ssh <alias>` and **VS Code Remote-SSH** use the same aliases and keys as WSL.
Only public keys are ever copied; `bwssh uninstall` removes the config block but
leaves the mirror in place.

## Security

- The private key never leaves Bitwarden; WSL sees only an ssh-agent socket.
- Per-host entries are OS-neutral; the global `Host *` block sets
  `PubkeyAuthentication unbound` (required by Bitwarden's agent) on both sides.
  This only drops replay-hardening that matters for **agent forwarding**, so
  **do not use `ForwardAgent yes`**. See `docs/design.md`.
- Bitwarden's **"Ask for authorization"** setting governs prompts; "Never" lets
  any process as your Windows user use keys silently.
- The **vault session** cached by `bwssh login` lives only in tmpfs (RAM), mode
  600, and is cleared by `bwssh lock` or reboot — never written to disk
  (`BWSSH_NO_SESSION_CACHE=1` disables it).
- A **shared key** trades blast radius for simplicity: a server that trusts it
  can reach every other server that trusts it. Use `--new-key` for hosts that
  should be isolated (for example a hypervisor's root account).

## Troubleshooting

- `Could not open a connection to your authentication agent` → service down.
- `agent refused operation` → the `unbound` / global block is missing.
- `Permission denied (publickey)` → vault locked, or key not on the server.

See `docs/runbook.md` for more.

## Development

```bash
bash tests/run.sh     # dependency-free; runs in CI
```

## License

This project is licensed under the MIT License - see the [LICENSE.md](https://github.com/lucyd-dev/bwSshBridge/blob/main/LICENSE) file for details.

`Lucyd made with 💜 since 2026`
