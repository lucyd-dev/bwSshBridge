# Windows checklist (the parts a script can't do)

`./bwssh install` runs `assets/windowsSetup.ps1`, which installs `npiperelay`,
disables the Windows OpenSSH agent service (auto-elevating via UAC), and checks
the pipe. These steps still need a human:

1. **Install Bitwarden Desktop — standalone build.**
   Download from <https://bitwarden.com/download/> (`.exe`).
   Do **not** use the Microsoft Store build: it runs sandboxed (Appx) and cannot
   serve the SSH agent — the pipe opens but never answers.

2. **Enable the SSH agent.**
   Bitwarden Desktop → **Settings → Enable SSH agent**.

3. **Choose the authorization behaviour.**
   Settings → **Ask for authorization when using SSH agent**:
   - `Always` — a prompt for every use (most secure, most noisy).
   - `Remember until vault is locked` — prompt once per key until lock (daily
     sane).
   - `Never` — silent (least friction; any process as your Windows user can use
     the keys without prompting).

4. **Disable the Windows OpenSSH Authentication Agent service** so Bitwarden can
   own the pipe. `bwssh install` does this (UAC). To do it manually in an
   **elevated** PowerShell:
   ```powershell
   Set-Service -Name ssh-agent -StartupType Disabled
   Stop-Service -Name ssh-agent
   ```

5. **Unlock the vault** — the agent only answers while Bitwarden is unlocked.

6. **Verify** from Windows PowerShell:
   ```powershell
   Get-ChildItem \\.\pipe\ | Where-Object Name -like '*ssh*'
   ssh-add.exe -l
   ```
   And from WSL: `ssh-add -l` (should list your keys).

## What `assets/windowsSetup.ps1` does

- Detects the Bitwarden build (warns if Store-only) and `npiperelay`.
- Installs `npiperelay` via `winget` (or downloads + SHA-256 verifies the
  release binary as a fallback).
- Disables/stops the OpenSSH agent service (auto-elevating if needed).
- Reports whether the SSH pipe is present.

`assets/windowsCheck.ps1` (via `bwssh status`) re-runs all checks.
