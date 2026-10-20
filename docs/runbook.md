# Runbook

## Install

```bash
git clone https://github.com/lucyd-dev/bwSshBridge ~/bwSshBridge
cd ~/bwSshBridge
./bwssh install                 # WSL + Windows + CLI + ssh config
./bwssh install --no-windows    # WSL only
./bwssh install --no-cli        # skip the bw CLI / API-key step
```

Then, in Bitwarden Desktop (Windows): **Settings → Enable SSH agent** (see
`docs/windowsChecklist.md`).

Verify:

```bash
bwssh status                   # local checks (add --windows for Windows checks)
ssh-add -l                     # lists vault keys when unlocked
ssh -v user@host 2>&1 | grep -E 'Offering|Accepted|agent'
```

## Daily use

Because the config is global (`Host *` + `SSH_AUTH_SOCK`), every host works:

```bash
ssh user@host                   # any host, keys come from Bitwarden
ssh <alias>                     # if you pinned one with `bwssh add-host`
scp file user@host:/path
rsync -a ./ user@host:/path
```

No `-i` and no local key file are needed. Pinning a key with `add-host` also
keeps a host's `MaxAuthTries` budget tidy when the agent holds several keys.

## Keys and hosts

One shared key is the normal setup. Set a default once:

```bash
bwssh setup-cli                     # once
bwssh default-key sharedkey        # an existing SSH key in the vault
bwssh add-host myserver 10.0.0.5 alice 2222
#   using default key "sharedkey"
#   bwssh unlocks the vault for you; then authorize the key on the server:
#   ssh-copy-id -f -i ~/.ssh/sharedkey.pub -p 2222 alice@10.0.0.5
#   ssh myserver
```

With no default set, `add-host` refuses and points at `--key` / `--new-key`;
it never guesses. Other modes:

- `--key <vault-item>` — use that shared key for this host without changing the
  default.
- `--new-key` — create a per-host key named after the alias (isolated mode).
- `--alias-only` — no key pin, no vault access.

`bwssh default-key` prints the default; `bwssh default-key --clear` removes it.

`bwssh list-hosts` / `bwssh remove-host myserver` manage the set. A pin is shared
by every host that references it, so it is only deleted when the last of those
hosts goes, unless it is the default. `remove-host --delete-key` additionally deletes the vault item, but
only when it is unreferenced, its fingerprint matches the pin, and it is not the
current default. The default key is never removed by `remove-host`; clear it
with `bwssh default-key --clear` before removing the host, or delete the item
in Bitwarden.

The set is kept in `~/.ssh/bwSshBridgeHosts.conf` and mirrored, with every
public key it references (`<key>.pub`), into Windows' own
`%USERPROFILE%\.ssh\`. If you replace the Windows copy with an older/fuller
file, import it with `bwssh sync-hosts` (use `bwssh sync-hosts --push` to go the
other way).

Windows-native `ssh` and VS Code Remote-SSH read the same aliases via a
marker-wrapped block (global `Host *` + `Include`) that `bwssh install` prepends
to `%USERPROFILE%\.ssh\config`; your other entries there are left untouched.
`bwssh uninstall` removes that block but keeps the mirrored files.

## Bitwarden CLI tools

```bash
bwssh setup-cli   # install bw + store API keys (EU by default)
bwssh login       # unlock and cache the session (so commands don't re-prompt)
bwssh lock        # clear the cached session
```

The API key is optional. If none is set (or `bw login --apikey` is rejected),
`bwssh login` and `setup-cli` fall back to interactive login — email + master
password, plus 2FA if enabled. `bwssh setup-cli --force` re-enters the API key.

API key: Bitwarden web vault → Account settings → Security → Keys → API key.

## Troubleshooting

| Symptom | Check / fix |
| --- | --- |
| `Could not open a connection to your authentication agent` | `systemctl --user restart bwSshBridge`; `ls -l ~/.ssh/agent.sock` |
| `ssh-add -l` hangs, `agent refused operation` on list | Bitwarden's single pipe is busy or wedged: retry; toggle SSH agent in Bitwarden settings or restart the app |
| `sign_and_send_pubkey: ... agent refused operation` | hostbound issue: ensure `PubkeyAuthentication unbound` applies to the host |
| no keys listed | vault locked → unlock Bitwarden Desktop |
| `Permission denied (publickey)` | key not on the server / wrong item; `ssh-add -l` should list the expected key |
| `UNPROTECTED PRIVATE KEY FILE ... .pub` | `chmod 600` the public key referenced by `IdentityFile` |
| Windows `npiperelay.exe` piling up under `wslhost` | ensure no `-p`; kill orphans, restart the unit |
| Windows side suspect | `bwssh windows` then `bwssh status` |

After `wsl --shutdown`, systemd restarts the unit on next boot; if the Windows
host rebooted, open and unlock Bitwarden Desktop first.

## Uninstall

```bash
./bwssh uninstall
```
The hosts file and the Windows mirror are left in place (your data).

The default-key file (`~/.config/bwSshBridge/default-key`) is removed with the
rest of `~/.config/bwSshBridge`; it contains only a key name, never key material.
