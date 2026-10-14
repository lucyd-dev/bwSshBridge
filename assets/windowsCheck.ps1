# Bitwarden SSH agent bridge - Windows diagnostics.
# Run via WSL:  bwssh status   (or)
#               powershell.exe -NoProfile -Command - < assets/windowsCheck.ps1
Write-Host '[*] Bitwarden SSH agent bridge - Windows checks'

$standalone = @(
  @(
    "$env:LOCALAPPDATA\Programs\Bitwarden\Bitwarden.exe",
    "$env:ProgramFiles\Bitwarden\Bitwarden.exe"
  ) | Where-Object { Test-Path $_ }
)
if ($standalone.Count -gt 0) { Write-Host "[ok] standalone Bitwarden: $($standalone[0])" }
else { Write-Host '[!!] standalone Bitwarden not found (Store build cannot serve the pipe)' }

$svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if ($svc) { Write-Host "[ok] OpenSSH agent service: $($svc.Status) / $($svc.StartType)" }
else { Write-Host '[ok] OpenSSH agent service not installed' }

$np = (Get-Command npiperelay.exe -ErrorAction SilentlyContinue).Source
if (-not $np) {
  $c = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\albertony.npiperelay_*\npiperelay.exe","$env:LOCALAPPDATA\npiperelay\npiperelay.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { $np = $c.FullName }
}
if ($np) { Write-Host "[ok] npiperelay: $np" } else { Write-Host '[!!] npiperelay not found' }

$pipe = Get-ChildItem -Path '\\.\pipe\' -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like '*ssh*' } | Select-Object -ExpandProperty Name
if ($pipe) { Write-Host "[ok] ssh pipe(s): $($pipe -join ', ')" }
else { Write-Host '[!!] no ssh pipe (enable SSH agent in Bitwarden Desktop)' }

if (Get-Command ssh-add.exe -ErrorAction SilentlyContinue) {
  Write-Host '[*] windows ssh-add -l:'
  & ssh-add.exe -l
}
